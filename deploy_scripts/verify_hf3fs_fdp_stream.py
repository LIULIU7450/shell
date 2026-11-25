#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""LMCache hf3fs 后端 FDP write stream 端到端验证（内核计数法）。

验证目标
--------
1. C++ 原生路径（``lmcache.lmcache_hf3fs`` / NativeConnectorL2Adapter）：
   KV chunk 写入时 ``stream_id`` 经 3FS USRBIO 下发，最终落到存储节点
   XFS 的对应 FDP stream。
2. Python Non-MP 路径（``Hf3fsClient``/``Hf3fsFile``，即 HF3fsConnector
   的实际写路径）：``ior_write.set_write_stream()`` 同样生效。

判定方法
--------
FDP 设备当前 ``nvme fdp status`` 不可用，因此使用 **内核计数**：
存储节点内核在 XFS 写路径打印 ``write with stream <N>``（带 FDP 补丁的
XFS）。本脚本在 3 台存储节点上后台 ``dmesg -w`` 抓取新增日志，按 stream
统计条数，比较各阶段增量与 LMCache 侧计算出的 stream_id 集合。

用法
----
    source /home/smrc/lzh/lmcache_3fs/bin/activate
    python verify_hf3fs_fdp_stream.py --data-mb 16
"""

# Future
from __future__ import annotations

# Standard
import argparse
import hashlib
import os
import pprint
import shutil
import subprocess
import sys
import time
import uuid

# 3FS 相关路径（当前部署）
THREE_FS_SRC = "/home/smrc/lzh/3fs-main"
THREE_FS_BUILD = os.path.join(THREE_FS_SRC, "build")

# 存储节点（内核 FDP 计数所在机器）
STORAGE_HOSTS = ["172.16.18.64", "172.16.18.65", "172.16.18.169"]
SSH_USER = "root"
SSH_PASS = "!@345Qwert"

MOUNT_POINT = "/3fs/stage"
CPP_BASE = os.path.join(MOUNT_POINT, "lmcache_fdp_verify", "cpp")
PY_BASE = os.path.join(MOUNT_POINT, "lmcache_fdp_verify", "python")

# FDP 约定（见 3FS 部署手册 §1.4）：1 空置、2 compaction、3.. 业务
START_FDP_STREAM_ID = 3
FDP_STREAM_NUMBER = 8
MODEL_NAME = "fdp-verify-model"


# ---------------------------------------------------------------------------
# 存储节点内核计数
# ---------------------------------------------------------------------------


def ssh(host: str, cmd: str, timeout: int = 30) -> str:
    """在存储节点执行命令。"""
    full = (
        f"sshpass -p '{SSH_PASS}' ssh -o StrictHostKeyChecking=no "
        f"-o ConnectTimeout=8 {SSH_USER}@{host} \"{cmd}\""
    )
    res = subprocess.run(full, shell=True, capture_output=True, text=True,
                         timeout=timeout)
    return res.stdout if res.returncode == 0 else ""


def start_kernel_watchers() -> None:
    """在每台存储节点起后台 dmesg -w，日志落到 /tmp/fdp_watch.log。

    注意：pkill 必须与启动动作分成两次 ssh，否则 pkill -f 会匹配到自身
    命令行（其中包含 "dmesg -w"）把自己杀掉；匹配模式用 [d]mesg 规避。
    """
    for host in STORAGE_HOSTS:
        ssh(host, 'pkill -f "[d]mesg -w"; echo cleaned')
        ssh(host, "rm -f /tmp/fdp_watch.log; "
                  "setsid nohup dmesg -w >/tmp/fdp_watch.log 2>&1 </dev/null & "
                  "echo started")
    time.sleep(3)
    for host in STORAGE_HOSTS:
        out = ssh(host, "wc -l < /tmp/fdp_watch.log 2>/dev/null || echo missing")
        print(f"   {host}: dmesg follow lines = {out.strip()}")


def stop_kernel_watchers() -> None:
    for host in STORAGE_HOSTS:
        ssh(host, 'pkill -f "[d]mesg -w"; echo stopped')


def read_stream_counts() -> dict[str, dict[int, int]]:
    """读取各存储节点 dmesg_watch 文件中按 stream 的累计计数。

    远端命令避免使用 ``$``（本地 shell 会先做变量展开），用 sed 取 stream 号。
    """
    result: dict[str, dict[int, int]] = {}
    for host in STORAGE_HOSTS:
        out = ssh(
            host,
            "grep -o 'write with stream [0-9]*' /tmp/fdp_watch.log "
            "| sed 's/.*stream //' | sort -n | uniq -c",
        )
        counts: dict[int, int] = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 2:
                counts[int(parts[1])] = int(parts[0])
        result[host] = counts
    return result


def diff_counts(
    before: dict[str, dict[int, int]], after: dict[str, dict[int, int]]
) -> dict[str, dict[int, int]]:
    """按节点计算增量。"""
    delta: dict[str, dict[int, int]] = {}
    for host in STORAGE_HOSTS:
        b = before.get(host, {})
        a = after.get(host, {})
        d = {sid: a[sid] - b.get(sid, 0) for sid in a if a[sid] - b.get(sid, 0) > 0}
        delta[host] = d
    return delta


def merge_delta(delta: dict[str, dict[int, int]]) -> dict[int, int]:
    total: dict[int, int] = {}
    for d in delta.values():
        for sid, cnt in d.items():
            total[sid] = total.get(sid, 0) + cnt
    return total


# ---------------------------------------------------------------------------
# LMCache 侧 stream_id 预测
# ---------------------------------------------------------------------------


def md5_mod(value: str, mod: int) -> int:
    """与 lmcache _fdp_utils.extract_string_mod 完全一致。"""
    return int(hashlib.md5(value.encode("utf-8")).hexdigest()[:8], 16) % mod


def object_key_string(key) -> str:
    return f"{key.model_name}@{key.kv_rank:08x}@{key.chunk_hash.hex()}"


def pick_keys_by_stream(streams: list[int]) -> dict[int, "object_key"]:
    """为每个目标 stream 找一个 ObjectKey（md5%N+start 命中该 stream）。"""
    from lmcache.v1.distributed.api import ObjectKey

    found: dict[int, object] = {}
    wanted = set(streams)
    for chunk_id in range(200000):
        key = ObjectKey(
            chunk_hash=ObjectKey.IntHash2Bytes(chunk_id),
            model_name=MODEL_NAME,
            kv_rank=0,
        )
        sid = md5_mod(object_key_string(key), FDP_STREAM_NUMBER) + START_FDP_STREAM_ID
        if sid in wanted and sid not in found:
            found[sid] = key
        if len(found) == len(wanted):
            break
    if len(found) != len(wanted):
        raise RuntimeError(f"未能为全部 stream 找到 key: {sorted(found)}")
    return found


# ---------------------------------------------------------------------------
# Phase A：C++ 原生 L2 adapter 路径
# ---------------------------------------------------------------------------


def _wait_store(adapter, timeout: float = 60.0) -> dict:
    import select

    fd = adapter.get_store_event_fd()
    deadline = time.time() + timeout
    while time.time() < deadline:
        done = adapter.pop_completed_store_tasks()
        if done:
            return done
        try:
            select.select([fd], [], [], 0.2)
        except (ValueError, OSError):
            break
    return adapter.pop_completed_store_tasks()


def make_memory_obj(nbytes: int, seed: int):
    """构造与 KV chunk 等价的 TensorMemoryObj（数据可复现）。"""
    import torch
    from lmcache.v1.memory_management import (
        MemoryFormat,
        MemoryObjMetadata,
        TensorMemoryObj,
    )

    n_floats = nbytes // 4
    g = torch.Generator().manual_seed(seed)
    t = torch.randint(0, 1 << 30, (n_floats,), generator=g, dtype=torch.int64)
    raw = (t % 1000).to(torch.float32)
    metadata = MemoryObjMetadata(
        shape=torch.Size([n_floats]),
        dtype=torch.float32,
        address=0,
        phy_size=n_floats * 4,
        fmt=MemoryFormat.KV_2LTD,
        ref_count=1,
    )
    return TensorMemoryObj(raw, metadata, parent_allocator=None)


def run_cpp_phase(data_mb: int, streams: list[int]) -> dict:
    """通过 Hf3fsL2Adapter 工厂 + NativeConnectorL2Adapter 写入。"""
    from lmcache.v1.distributed.l2_adapters.hf3fs_l2_adapter import (
        Hf3fsL2AdapterConfig,
        _create_hf3fs_l2_adapter,
    )

    os.makedirs(CPP_BASE, exist_ok=True)
    cfg = Hf3fsL2AdapterConfig(
        mount_point=MOUNT_POINT,
        base_paths=CPP_BASE,
        num_workers=2,
        ior_entries=256,
        io_depth=0,
        numa_id=-1,
        iov_size=209715200,
        enable_key_buffer=False,
        use_fdp=True,
        fdp_stream_number=FDP_STREAM_NUMBER,
        start_fdp_stream_id=START_FDP_STREAM_ID,
        fdp_hint_source="request_id",
    )
    adapter = _create_hf3fs_l2_adapter(cfg)

    keys = pick_keys_by_stream(streams)
    expect_md5: dict[int, str] = {}
    results = []
    for sid in sorted(keys):
        key = keys[sid]
        obj = make_memory_obj(data_mb * 1024 * 1024, seed=sid)
        expect_md5[sid] = hashlib.md5(obj.byte_array.tobytes()).hexdigest()
        task_id = adapter.submit_store_task([key], [obj])
        done = _wait_store(adapter)
        ok = task_id in done
        results.append({"stream_id": sid, "key": object_key_string(key), "ok": ok})
        print(f"  [C++] store key(stream={sid}) task={task_id} completed={ok}")

    os.sync()
    time.sleep(4)

    # 数据完整性：直接从 FUSE 目录读回文件比对 md5
    integrity = []
    files = sorted(os.listdir(CPP_BASE))
    md5_set = set(expect_md5.values())
    for f in files:
        p = os.path.join(CPP_BASE, f)
        if not os.path.isfile(p):
            continue
        with open(p, "rb") as fh:
            got = hashlib.md5(fh.read()).hexdigest()
        integrity.append({"file": f, "size": os.path.getsize(p),
                          "md5_matched": got in md5_set})
    adapter.close()
    return {"stores": results, "integrity": integrity,
            "expected_streams": sorted(keys)}


# ---------------------------------------------------------------------------
# Phase B：Python Non-MP 路径（HF3fsConnector 的写路径）
# ---------------------------------------------------------------------------


def run_python_phase(data_mb: int, streams: list[int]) -> dict:
    """复用 HF3fsConnector.sync_put 的底层 Hf3fsClient/Hf3fsFile 写路径。"""
    sys.path.insert(0, THREE_FS_SRC)
    sys.path.insert(0, os.path.join(THREE_FS_BUILD, "src/lib/py"))

    from lmcache.v1.storage_backend.connector.hf3fs_connector import (
        Hf3fsClient,
        Hf3fsClientConfig,
        Hf3fsFile,
    )

    os.makedirs(PY_BASE, exist_ok=True)
    client = Hf3fsClient.get_instance(
        Hf3fsClientConfig(mount_point=MOUNT_POINT, iov_size=104857600,
                          ior_entries=256, io_depth=0, timeout=200, numa_id=-1)
    )

    results = []
    stream_idx = {sid: i for i, sid in enumerate(sorted(streams))}
    for sid in sorted(streams):
        # 模拟 CacheEngineKey.to_string() 形态的 hint key
        hint = f"{MODEL_NAME}@-1@chunk_{sid}@req-{uuid.uuid4().hex[:8]}"
        # 为了命中目标 stream，按 md5 反查候选字符串
        chosen = None
        for i in range(100000):
            cand = f"{MODEL_NAME}@-1@chunk_{sid}_{i}@req-{stream_idx[sid]}"
            if md5_mod(cand, FDP_STREAM_NUMBER) + START_FDP_STREAM_ID == sid:
                chosen = cand
                break
        hint = chosen or hint
        nbytes = data_mb * 1024 * 1024
        payload = bytes((sid + i) % 251 for i in range(1024)) * (nbytes // 1024)
        path = os.path.join(PY_BASE, f"stream{sid}_{uuid.uuid4().hex[:6]}.bin")
        with Hf3fsFile(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, client) as f:
            written = f.write(payload, nbytes, 0, sid)
        md5_ok = False
        if os.path.exists(path):
            with open(path, "rb") as fh:
                md5_ok = hashlib.md5(fh.read()).hexdigest() == hashlib.md5(payload).hexdigest()
        results.append({"stream_id": sid, "path": path, "bytes": written,
                        "file_size": os.path.getsize(path),
                        "md5_matched": md5_ok})
        print(f"  [py] stream={sid} wrote {written}B size={os.path.getsize(path)} "
              f"md5_ok={md5_ok}")

    client.close()
    os.sync()
    time.sleep(4)
    return {"files": results, "expected_streams": sorted(streams)}


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-mb", type=int, default=16, help="每个 key 的数据量(MB)")
    ap.add_argument("--skip-python", action="store_true")
    args = ap.parse_args()

    streams = list(range(START_FDP_STREAM_ID,
                         START_FDP_STREAM_ID + FDP_STREAM_NUMBER))
    print("=" * 70)
    print("LMCache hf3fs 后端 FDP write stream 验证（内核计数）")
    print(f"mount={MOUNT_POINT} streams={streams} data={args.data_mb}MB/key")
    print("=" * 70)

    for p in (CPP_BASE, PY_BASE):
        shutil.rmtree(p, ignore_errors=True)
        os.makedirs(p, exist_ok=True)

    print("\n[0] 启动存储节点内核日志抓取 ...")
    start_kernel_watchers()

    print("\n[1] Phase A: C++ 原生 hf3fs L2 adapter 写入")
    cpp_res = run_cpp_phase(args.data_mb, streams)
    after_a = read_stream_counts()
    print("\n  Phase A 写入后内核计数快照:")
    pprint.pprint(after_a)

    delta_a = diff_counts({h: {} for h in STORAGE_HOSTS}, after_a)
    total_a = merge_delta(delta_a)
    print("\n  Phase A 各 stream 内核计数增量（3 节点合计）:", total_a)

    py_res = None
    delta_b: dict[int, int] = {}
    if not args.skip_python:
        print("\n[2] Phase B: Python Non-MP Hf3fsClient 写入")
        py_res = run_python_phase(args.data_mb, streams)
        after_b = read_stream_counts()
        delta_b = merge_delta(diff_counts(after_a, after_b))
        print("\n  Phase B 各 stream 内核计数增量（3 节点合计）:", delta_b)

    stop_kernel_watchers()

    def check(name: str, expected: list[int], got: dict[int, int]) -> bool:
        print(f"\n[判定] {name}")
        ok = True
        for sid in expected:
            cnt = got.get(sid, 0)
            flag = "PASS" if cnt > 0 else "FAIL"
            if cnt <= 0:
                ok = False
            print(f"   stream {sid:>3}: 内核写入计数 {cnt:>7}  [{flag}]")
        unexpected = {s: c for s, c in got.items()
                      if s not in expected and s != 2}
        if unexpected:
            print(f"   非预期 stream 计数（排除 2=compaction）: {unexpected}")
        return ok

    a_ok = check("Phase A (C++ native / L2 adapter)", cpp_res["expected_streams"],
                 total_a)
    b_ok = True
    if py_res is not None:
        b_ok = check("Phase B (Python Non-MP HF3fsClient)", py_res["expected_streams"],
                     delta_b)

    print("\n[数据完整性]")
    for it in cpp_res["integrity"]:
        print(f"   C++  {it['file'][:60]:<60} size={it['size']} md5_ok={it['md5_matched']}")
    if py_res:
        for it in py_res["files"]:
            print(f"   py   stream={it['stream_id']} size={it['file_size']} "
                  f"md5_ok={it['md5_matched']}")

    ok = a_ok and b_ok and all(i["md5_matched"] for i in cpp_res["integrity"])
    print("\n" + "=" * 70)
    print("结果:", "PASS" if ok else "FAIL")
    print("=" * 70)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
