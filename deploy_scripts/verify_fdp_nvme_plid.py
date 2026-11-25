#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""NVMe 命令级佐证：FDP stream_id -> dsmgmt/PLID（tracepoint 抓取）。

``nvme fdp status`` 在该盘（PM1763）上 RUAMW 为静态值、``nvme fdp stats``
不被支持，因此用内核 tracepoint ``nvme:nvme_setup_cmd`` 抓取真正下发到
NVMe 写命令里的 ``dsmgmt``（placement directive）：

    dsmgmt = (stream_id - 1) << 16   ⇒ PLID = stream_id - 1

用法：
    python verify_fdp_nvme_plid.py --stream 12 --size-mb 16
"""

# Future
from __future__ import annotations

# Standard
import argparse
import os
import subprocess
import sys
import time

STORAGE_HOSTS = ["172.16.18.64", "172.16.18.65", "172.16.18.169"]
SSH_USER = "root"
SSH_PASS = "!@345Qwert"
MOUNT_POINT = "/3fs/stage"
BASE = os.path.join(MOUNT_POINT, "lmcache_fdp_verify", "plid")
TRACE = "/sys/kernel/tracing"
TLOG = "/tmp/nvme_trace.log"


def ssh(host: str, cmd: str, timeout: int = 60) -> str:
    full = (
        f"sshpass -p '{SSH_PASS}' ssh -o StrictHostKeyChecking=no "
        f"-o ConnectTimeout=8 {SSH_USER}@{host} \"{cmd}\""
    )
    res = subprocess.run(full, shell=True, capture_output=True, text=True,
                         timeout=timeout)
    return res.stdout if res.returncode == 0 else ""


def read_plid_counts(hosts: list[str]) -> dict[str, dict[int, int]]:
    """统计 trace 日志里 dsmgmt 值的分布（内核按十进制打印 dsmgmt）。"""
    out_all: dict[str, dict[int, int]] = {}
    for host in hosts:
        out = ssh(host, f"grep -o 'dsmgmt=[0-9]*' {TLOG} 2>/dev/null "
                        "| sed 's/dsmgmt=//' | sort -n | uniq -c")
        counts: dict[int, int] = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 2:
                counts[int(parts[1])] = int(parts[0])
        out_all[host] = counts
    return out_all


def diff(before: dict[int, int], after: dict[int, int]) -> dict[int, int]:
    return {k: after[k] - before.get(k, 0) for k in after
            if after[k] - before.get(k, 0) > 0}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--stream", type=int, default=12)
    ap.add_argument("--size-mb", type=int, default=16)
    ap.add_argument("--hosts", default=",".join(STORAGE_HOSTS))
    args = ap.parse_args()
    hosts = [h.strip() for h in args.hosts.split(",") if h.strip()]
    sid = args.stream

    print("=" * 70)
    print(f"FDP NVMe 命令级验证: stream_id={sid} "
          f"(期望 dsmgmt=0x{(sid - 1) << 16:x}, PLID={sid - 1})")
    print("=" * 70)

    # 1) 打开 tracepoint 并流式抓取（先确保没有残留 reader 占着 trace_pipe）
    for host in hosts:
        ssh(host, f'pkill -9 -f "[t]race_pipe"; sleep 1; '
                  f'echo 0 > {TRACE}/tracing_on; echo > {TRACE}/trace; '
                  f'echo 1 > {TRACE}/events/nvme/nvme_setup_cmd/enable; '
                  f'rm -f {TLOG}; echo 1 > {TRACE}/tracing_on')
        ssh(host, f"setsid nohup cat {TRACE}/trace_pipe >{TLOG} 2>&1 </dev/null & "
                  f"echo started")
    time.sleep(3)
    for host in hosts:
        head = ssh(host, f"head -c 120 {TLOG} 2>/dev/null")
        if "busy" in head:
            print(f"   !! {host}: trace_pipe 被占用，重试一次")
            ssh(host, 'pkill -9 -f "[t]race_pipe"; sleep 1')
            ssh(host, f"rm -f {TLOG}; "
                      f"setsid nohup cat {TRACE}/trace_pipe >{TLOG} 2>&1 </dev/null & "
                      f"echo started")
            time.sleep(2)
    before = read_plid_counts(hosts)
    print("[1] trace 已开启，基线 dsmgmt 分布:",
          {h: dict(list(b.items())[:4]) for h, b in before.items()})

    # 2) 通过 LMCache hf3fs 后端（Python 非 MP 写路径）写入指定 stream
    sys.path.insert(0, "/home/smrc/lzh/3fs-main")
    sys.path.insert(0, "/home/smrc/lzh/3fs-main/build/src/lib/py")
    from lmcache.v1.storage_backend.connector.hf3fs_connector import (
        Hf3fsClient,
        Hf3fsClientConfig,
        Hf3fsFile,
    )

    os.makedirs(BASE, exist_ok=True)
    client = Hf3fsClient.get_instance(
        Hf3fsClientConfig(mount_point=MOUNT_POINT, iov_size=104857600,
                          ior_entries=256, io_depth=0, timeout=200, numa_id=-1)
    )
    nbytes = args.size_mb * 1024 * 1024
    payload = bytes([sid % 251]) * nbytes
    path = os.path.join(BASE, f"plid_probe_stream{sid}.bin")
    with Hf3fsFile(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, client) as f:
        written = f.write(payload, nbytes, 0, sid)
    client.close()
    os.sync()
    time.sleep(5)
    print(f"[2] 已写入 {written} 字节，stream_id={sid} -> {path}")

    # 3) 停止 tracepoint
    for host in hosts:
        ssh(host, f'pkill -f "[c]at {TRACE}/trace_pipe"; '
                  f'echo 0 > {TRACE}/events/nvme/nvme_setup_cmd/enable; '
                  f'echo 0 > {TRACE}/tracing_on')
    after = read_plid_counts(hosts)

    print("[3] 各节点 dsmgmt 增量（本轮写入期间，格式 dsmgmt(十进制)->PLID）:")
    expect = (sid - 1) << 16
    ok = False
    for host in hosts:
        d = diff(before.get(host, {}), after.get(host, {}))
        pretty = {f"{v}(PLID {v >> 16})": c for v, c in d.items()}
        print(f"   {host}: {pretty}")
        if d.get(expect, 0) > 0:
            ok = True
    print(f"[4] 期望 dsmgmt={expect} (0x{expect:x}, PLID {sid - 1})，"
          f"命中={'YES' if ok else 'NO'}")
    print("=" * 70)
    print("结果:", "PASS" if ok else "FAIL")
    print("=" * 70)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
