#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
usrbio_stream_bench.py — 3FS FUSE 挂载上的 USRBIO 定向写工具（在【GPU 客户端】运行）

走的是 LMCache Hf3fsConnector 完全相同的写入路径：
    hf3fs_fuse.io → ioring.set_write_stream(stream_id) → 3FS USRBIO
    → storage 节点 XFS FS_IOC_WRITE_STREAM SET → NVMe FDP DSMgmt → 对应 PLID

用途：
  1. 部署验证  ：--mode fixed --start 3 写 2GB → 到存储节点看 PLID 2 的 RUAMW 下降
  2. WAF 实验  ：--mode zero   （全部默认放置，baseline）
                 --mode md5    （模拟 LMCache 真实分流: start + MD5(key)%n）
                 --mode spread （轮转分流）
                 配合存储节点上的 nvme smart-log / nvme fdp status 采样做前后对比

用法示例（需先装好 hf3fs_fuse 包并挂载 3FS）：
    python3 usrbio_stream_bench.py --dir /3fs/fdp/bench --mode fixed --start 3 --gb 2
    python3 usrbio_stream_bench.py --dir /3fs/fdp/bench --mode zero   --gb 32 --rounds 3
    python3 usrbio_stream_bench.py --dir /3fs/fdp/bench --mode md5 --start 3 --streams 8 \
        --gb 32 --rounds 3 --files 16 --delete-each-round

依赖：python3 + 已安装的 hf3fs_fuse 包（hf3fs_py_usrbio 扩展）
"""

import argparse
import hashlib
import multiprocessing.shared_memory as shm_mod
import os
import sys
import time

try:
    from hf3fs_fuse.io import (
        deregister_fd,
        make_iovec,
        make_ioring,
        register_fd,
    )
except ImportError as e:
    print(f"[FAIL] 无法导入 hf3fs_fuse.io: {e}\n"
          "       请先安装 hf3fs_py_usrbio 包（3fs 源码 pip install .）并确认挂载点正确")
    sys.exit(2)


def stream_for(mode, start, streams, key, idx):
    """按策略计算本文件/本轮使用的 stream_id（0 = 默认放置）"""
    if mode == "zero":
        return 0
    if mode == "fixed":
        return start
    if mode == "spread":
        return start + (idx % streams)
    if mode == "md5":
        # 与 lmcache _fdp_utils.extract_string_mod + start 偏移完全同式
        digest = hashlib.md5(key.encode()).hexdigest()
        return start + int(digest[:8], 16) % streams
    raise ValueError(mode)


def usrbio_write_file(path, ior, iov, shm, iov_size, nbytes, stream_id, pattern):
    """经 USRBIO 写一个文件。与 test_lmcache_3fs_fdp.py 的 write_with_stream 同路径。"""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        register_fd(fd)
        ior.set_write_stream(stream_id)
        shm.buf[:iov_size] = pattern * (iov_size // len(pattern) + 1)
        off = 0
        while off < nbytes:
            chunk = min(iov_size, nbytes - off)
            ior.prepare(iov[:chunk], False, fd, off)
            ior.submit().wait(min_results=1)
            off += chunk
        # USRBIO write 的 cqe.result 可能返回 0，按文件大小验证
        if os.path.getsize(path) != nbytes:
            raise OSError(f"short write: {os.path.getsize(path)} != {nbytes}")
        return nbytes
    finally:
        deregister_fd(fd)
        os.close(fd)


def main():
    ap = argparse.ArgumentParser(description="3FS USRBIO FDP stream 写入工具",
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dir", required=True, help="3FS 挂载内的目标目录（自动创建）")
    ap.add_argument("--mode", choices=["zero", "fixed", "spread", "md5"],
                    default="fixed", help="stream 策略（zero=默认放置 baseline）")
    ap.add_argument("--start", type=int, default=3,
                    help="起始 stream_id（规划: 3, 避开 0/1/2 与 XFS 预留 15/16）")
    ap.add_argument("--streams", type=int, default=8, help="分流数（md5/spread 模式）")
    ap.add_argument("--gb", type=float, default=8.0, help="每个文件 GiB")
    ap.add_argument("--files", type=int, default=4, help="每轮并发文件数")
    ap.add_argument("--rounds", type=int, default=1,
                    help="写入轮数（>1 时每轮覆盖/重写，模拟 KV churn）")
    ap.add_argument("--delete-each-round", action="store_true",
                    help="每轮结束后删除全部文件（模拟 KV 淘汰，触发 3fs 回收）")
    ap.add_argument("--iov-size", type=int, default=64 << 20,
                    help="USRBIO iov 共享内存大小（默认 64MB）")
    ap.add_argument("--ior-entries", type=int, default=64)
    ap.add_argument("--keep", action="store_true", help="结束后保留数据文件")
    args = ap.parse_args()

    if args.mode in ("md5", "spread") and args.streams <= 0:
        print("[FAIL] md5/spread 模式需要 --streams >= 1")
        return 2
    if args.start + args.streams - 1 > 255:
        print("[FAIL] stream_id 超出 0-255 上限")
        return 2

    mount = os.path.realpath(args.dir)
    # 3FS 挂载根: 提取 /3fs/<cluster> 前缀（hf3fs_fuse.io 期望挂载根路径）
    print(f"[INFO] 目标目录: {args.dir}")
    os.makedirs(args.dir, exist_ok=True)

    client = f"fdpbench_{os.getpid()}"
    shm = shm_mod.SharedMemory(name=f"{client}_iov", size=args.iov_size, create=True)
    try:
        iov = make_iovec(shm=shm, hf3fs_mount_point=_mount_root(args.dir), numa=-1)
        ior = make_ioring(_mount_root(args.dir), args.ior_entries,
                          for_read=False, timeout=200, numa=-1)
    except Exception as e:
        print(f"[FAIL] USRBIO ioring/iov 创建失败: {e}\n"
              "       检查: 3FS 是否已挂载、hf3fs_fuse 包版本是否带 set_write_stream")
        shm.close()
        shm.unlink()
        return 2

    pattern = b"\xa5\x3c\xf0\x5a"
    per_file = int(args.gb * (1 << 30))
    total_rounds_bytes = 0
    stream_counter = {}
    t0 = time.time()

    try:
        for rnd in range(1, args.rounds + 1):
            rnd_start = time.time()
            rnd_bytes = 0
            for i in range(args.files):
                key = f"bench-r{rnd}-f{i}"
                sid = stream_for(args.mode, args.start, args.streams, key, i)
                stream_counter[sid] = stream_counter.get(sid, 0) + 1
                path = os.path.join(args.dir, f"bench_{rnd:02d}_{i:03d}.bin")
                n = usrbio_write_file(path, ior, iov, shm, args.iov_size,
                                      per_file, sid, pattern)
                rnd_bytes += n
            total_rounds_bytes += rnd_bytes
            dt = time.time() - rnd_start
            print(f"[round {rnd}/{args.rounds}] {args.files} files × {args.gb} GiB, "
                  f"{rnd_bytes/1e9:.1f} GB in {dt:.1f}s ({rnd_bytes/1e6/max(dt,1e-9):.0f} MB/s)")
            if args.delete_each_round:
                for i in range(args.files):
                    try:
                        os.unlink(os.path.join(args.dir, f"bench_{rnd:02d}_{i:03d}.bin"))
                    except OSError:
                        pass
                # 给 3fs 一点时间做后台回收（若想观察 compaction 可加大此值）
                time.sleep(2)
    finally:
        try:
            del ior, iov
        except Exception:
            pass
        shm.close()
        shm.unlink()
        if not args.keep and not args.delete_each_round:
            for f in os.listdir(args.dir):
                if f.startswith("bench_"):
                    try:
                        os.unlink(os.path.join(args.dir, f))
                    except OSError:
                        pass

    total_dt = time.time() - t0
    print("=" * 60)
    print(f"mode={args.mode} start={args.start} streams={args.streams}")
    print(f"stream 使用分布（文件数）: {dict(sorted(stream_counter.items()))}")
    print(f"总写入 {total_rounds_bytes/1e9:.1f} GB, 总耗时 {total_dt:.1f}s, "
          f"平均 {total_rounds_bytes/1e6/max(total_dt,1e-9):.0f} MB/s")
    if args.mode == "zero":
        print("提示: 本轮为默认放置 baseline — 在存储节点记录 nvme smart-log 的")
        print("      data_units_written 增量, 再跑 --mode md5 做同负载对比")
    else:
        print(f"提示: 期望 RUAMW 下降的 PLID = stream_id-1 ∈ "
              f"[{args.start - 1}, {args.start + args.streams - 2}]")
    return 0


def _mount_root(d):
    """从目录路径推断 3FS 挂载根（形如 /3fs/<cluster>）。
    hf3fs_fuse.io 的 make_iovec/make_ioring 需要传 3FS 挂载点根路径。"""
    # 常见布局: /3fs/<cluster_id>/... → 根为 /3fs/<cluster_id>
    parts = os.path.realpath(d).split(os.sep)
    if len(parts) >= 3 and parts[1] == "3fs":
        return os.path.join(os.sep, parts[1], parts[2])
    # 兜底: 让 hf3fs_fuse.extract_mount_point 自己解析
    try:
        from hf3fs_fuse.io import extract_mount_point
        root = extract_mount_point(d)
        if root:
            return root
    except Exception:
        pass
    return os.path.realpath(d)


if __name__ == "__main__":
    sys.exit(main())
