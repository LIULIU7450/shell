#!/usr/bin/env python3
"""fdp_stream_write.py — 经 3FS FUSE 以指定 FDP write stream 写入数据 (WAF/放置验证用)

用法:
    python3 fdp_stream_write.py <目录> <写入MB> <stream_id> [--keep]

说明:
    * stream_id = 0 表示不携带 placement directive (默认放置);
    * stream_id = N (1..255) 经 HF3FS_IOC_WRITE_STREAM(OP_SET) 打到文件句柄上,
      存储侧写盘时按内核映射落到 PLID N-1;
    * 写入完成后 nvme 侧的 RUAMW 差值可验证物理放置 (见 03_setup_storage.sh verify check)。
"""
import fcntl
import os
import struct
import sys
import time

HF3FS_IOC_WRITE_STREAM = (3 << 30) | (16 << 16) | (0x68 << 8) | 16  # 0xC0106810
OP_GET_MAX, OP_GET, OP_SET = 1, 2, 4


def ioctl(fd, op, sid=0):
    buf = struct.pack("IIII", op, sid, 0, 0)
    out = fcntl.ioctl(fd, HF3FS_IOC_WRITE_STREAM, buf)
    return struct.unpack("IIII", out)


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    directory, size_mb, stream_id = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    keep = "--keep" in sys.argv[4:]

    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, f"fdp_write_{stream_id}_{int(time.time())}.bin")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    try:
        _, _, mx, _ = ioctl(fd, OP_GET_MAX)
        print(f"GET_MAX = {mx}")
        if stream_id:
            ioctl(fd, OP_SET, stream_id)
            _, sid, _, _ = ioctl(fd, OP_GET, 0)
            print(f"SET stream={stream_id} → GET = {sid}")
            assert sid == stream_id, "ioctl SET/GET 不一致"

        block = 4 << 20
        total = size_mb << 20
        written = 0
        t0 = time.time()
        while written < total:
            n = os.write(fd, b"\xa5" * min(block, total - written))
            written += n
        os.fsync(fd)
        dt = time.time() - t0
        print(f"写入 {written >> 20} MB, {dt:.2f}s, {written / dt / (1 << 20):.1f} MB/s → {path}")
    finally:
        os.close(fd)
    if not keep:
        os.unlink(path)
        print("已删除写入文件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
