#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""in-process（非 MP）hf3fs 后端 FDP 验证：HF3fsConnector.sync_put 真实路径。

对应 vLLM in-process 接入方式（``--kv-transfer-config {"kv_connector":
"LMCacheConnectorV1"}``）下 LMCache 使用的远程存储插件 ``hf3fs.primary``。

本脚本直接构造 ``HF3fsConnector``（用最小 stub 代替 LocalCPUBackend /
LMCacheMetadata），调用其 ``sync_put()``，从而覆盖：

    LMCacheEngineConfig(use_fdp/...) -> HF3fsConnector.sync_put
      -> CacheEngineKey.to_string() -> MD5%N + start
      -> Hf3fsFile.write(..., stream_id) -> Hf3fsClient._write
      -> ior_write.set_write_stream(stream_id) -> 3FS USRBIO -> XFS/NVMe FDP

然后在 3 台存储节点上用内核 ``write with stream N`` 计数比对。

用法：
    python verify_hf3fs_inprocess_fdp.py --data-mb 16
"""

# Future
from __future__ import annotations

# Standard
import argparse
import asyncio
import hashlib
import os
import shutil
import sys
import types
from concurrent.futures import ThreadPoolExecutor

# Third Party
import torch

# 复用主验证脚本里的内核计数工具
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_hf3fs_fdp_stream import (  # noqa: E402
    STORAGE_HOSTS,
    diff_counts,
    merge_delta,
    read_stream_counts,
    start_kernel_watchers,
    stop_kernel_watchers,
)

THEE_FS_SRC = "/home/smrc/lzh/3fs-main"
THREE_FS_PY = os.path.join(THEE_FS_SRC, "build/src/lib/py")

MOUNT_POINT = "/3fs/stage"
BASE_PATH = os.path.join(MOUNT_POINT, "lmcache_fdp_verify", "inprocess")
MODEL = "fdp-verify-model"
START_STREAM = 3
STREAM_NUM = 8


class _StubMetadata:
    """RemoteConnector 所需 metadata 的最小实现。"""

    use_mla = False
    chunk_size = 256

    def get_shapes(self):
        return [torch.Size([2, 1, 256, 8])]

    def get_dtypes(self):
        return [torch.bfloat16]

    def get_num_groups(self):
        return 1


def _stub_cpu_backend(cfg):
    """最小 local_cpu_backend：只提供 config 与 metadata。"""
    return types.SimpleNamespace(
        config=cfg,
        metadata=_StubMetadata(),
        allocate=lambda *a, **k: None,
    )


def _make_memory_obj(nbytes: int, seed: int):
    """构造 [2,1,N,8] bf16 的 KV 形状内存对象。"""
    from lmcache.v1.memory_management import (
        MemoryFormat,
        MemoryObjMetadata,
        TensorMemoryObj,
    )

    n_tokens = nbytes // (2 * 8 * 2)  # 2*8 个 bf16 元素/token
    g = torch.Generator().manual_seed(seed)
    raw = torch.randint(0, 1 << 20, (2, 1, n_tokens, 8), generator=g,
                        dtype=torch.int32).abs().to(torch.bfloat16)
    meta = MemoryObjMetadata(
        shape=torch.Size([2, 1, n_tokens, 8]),
        dtype=torch.bfloat16,
        address=0,
        phy_size=raw.numel() * 2,
        fmt=MemoryFormat.KV_2LTD,
        ref_count=1,
    )
    return TensorMemoryObj(raw, meta, parent_allocator=None)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-mb", type=int, default=16)
    args = ap.parse_args()
    nbytes = args.data_mb * 1024 * 1024

    sys.path.insert(0, THREE_FS_PY)
    sys.path.insert(0, THEE_FS_SRC)

    from lmcache.utils import CacheEngineKey
    from lmcache.v1.config import LMCacheEngineConfig
    from lmcache.v1.distributed.l2_adapters._fdp_utils import extract_string_mod
    from lmcache.v1.storage_backend.connector.hf3fs_connector import HF3fsConnector

    shutil.rmtree(BASE_PATH, ignore_errors=True)
    os.makedirs(BASE_PATH, exist_ok=True)

    # 与 vLLM in-process 部署一致的配置：FDP 三个参数放顶层（extra_config 内不生效）
    cfg_yaml = """
chunk_size: 256
local_cpu: False
remote_storage_plugins: ["hf3fs.primary"]
use_fdp: true
fdp_stream_number: 8
start_fdp_stream_id: 3
extra_config:
  remote_storage_plugin.hf3fs.primary.base_path: "%s"
  hf3fs_mount_point: "%s"
  save_chunk_meta: False
""" % (BASE_PATH, MOUNT_POINT)
    cfg_path = "/tmp/_lmcache_inprocess_fdp.yaml"
    with open(cfg_path, "w", encoding="utf-8") as f:
        f.write(cfg_yaml)
    cfg = LMCacheEngineConfig.from_file(cfg_path)
    print(f"config: use_fdp={cfg.use_fdp} number={cfg.fdp_stream_number} "
          f"start={cfg.start_fdp_stream_id}")

    loop = asyncio.new_event_loop()
    connector = HF3fsConnector(
        loop=loop,
        local_cpu_backend=_stub_cpu_backend(cfg),
        mount_point=MOUNT_POINT,
        iov_size=104857600,
        ior_entries=256,
        io_depth=0,
        numa_id=-1,
        io_thread_num=2,
        plugin_name="hf3fs.primary",
        base_paths_str=BASE_PATH,
    )

    # 选 8 个 chunk_hash，使 key.to_string() 的 MD5%8 覆盖 3..10
    keys: dict[int, CacheEngineKey] = {}
    for i in range(200000):
        key = CacheEngineKey(
            model_name=MODEL,
            world_size=1,
            worker_id=0,
            chunk_hash=i,
            dtype=torch.bfloat16,
        )
        sid = (
            extract_string_mod(key.to_string(), STREAM_NUM) + START_STREAM
        )
        if sid not in keys:
            keys[sid] = key
        if len(keys) == STREAM_NUM:
            break
    expected = sorted(keys)

    print("\n[1] 启动存储节点内核日志抓取 ...")
    start_kernel_watchers()
    before = read_stream_counts()

    print(f"\n[2] HF3fsConnector.sync_put 写入 {len(expected)} 个 key "
          f"({args.data_mb}MB each)")
    md5_expect = {}
    for sid in expected:
        key = keys[sid]
        obj = _make_memory_obj(nbytes, seed=sid)
        md5_expect[sid] = hashlib.md5(obj.byte_array.tobytes()).hexdigest()
        connector.sync_put(key, obj)
        print(f"   stream={sid} key={key.to_string()[:48]}... written")

    os.sync()
    import time

    time.sleep(5)
    after = read_stream_counts()
    stop_kernel_watchers()
    delta = merge_delta(diff_counts(before, after))
    print("\n[3] 内核计数增量（3 节点合计）:", delta)

    print("\n[4] 数据完整性")
    ok_file = 0
    for f in sorted(os.listdir(BASE_PATH)):
        p = os.path.join(BASE_PATH, f)
        if not os.path.isfile(p):
            continue
        with open(p, "rb") as fh:
            got = hashlib.md5(fh.read()).hexdigest()
        hit = got in set(md5_expect.values())
        ok_file += int(hit)
        print(f"   {f[:56]:<56} size={os.path.getsize(p)} md5_ok={hit}")

    print("\n[判定]")
    ok = ok_file == len(expected)
    for sid in expected:
        cnt = delta.get(sid, 0)
        flag = "PASS" if cnt > 0 else "FAIL"
        ok = ok and cnt > 0
        print(f"   stream {sid:>3}: 内核写入计数 {cnt:>7}  [{flag}]")

    connector._close()
    loop.close()

    print("\n" + "=" * 70)
    print("结果:", "PASS" if ok else "FAIL")
    print("=" * 70)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
