#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fdp_preflight.py — 3FS/LMCache FDP 部署前置验收脚本（在【存储节点】上运行）

目的：在任何 3FS 组件部署之前，验证「内核 XFS write-stream → NVMe FDP」
整条链路是否真正生效，闭环 2026-11-17 envinfo 报告中的异常：

    /sys/block/nvmeXn1/queue/max_write_streams = 16   (NVMe 层正常)
    但 XFS 上 FS_IOC_WRITE_STREAM GET_MAX 返回 max_streams = 0  (异常!)

验证链路（与 3FS chunk engine 的写入路径一致）：
    open(2) → ioctl(FS_IOC_WRITE_STREAM, SET, stream_id) → pwrite(2)
    → XFS i_write_stream → bio bi_write_stream → NVMe FDP DSMgmt
    → `nvme fdp status` 对应 PLID 的 RUAMW 下降

用法（建议 root，nvme fdp status 需要权限；无 root 时 RUAMW 对比跳过）：
    sudo python3 fdp_preflight.py                          # 所有 XFS 挂载点, stream=3, 8GB
    sudo python3 fdp_preflight.py -m /storage/data2 -s 3 -g 2
    sudo python3 fdp_preflight.py --baseline               # 额外做一轮 stream=0 对照
    python3  fdp_preflight.py -g 0                         # 只做 ioctl 探测, 不写入

仅依赖 python3 标准库 + nvme-cli（现场均已有, nvme-cli 2.8）。
测试文件自动创建、自动删除（--keep 保留）。不会触碰既有数据。
"""

import argparse
import ctypes
import errno
import fcntl
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import time

# ---------------------------------------------------------------------------
# 内核接口常量 (与 include/uapi/linux/fs.h 保持一致, 内核 7.0.0-rc2 FDP 补丁)
# ---------------------------------------------------------------------------
FS_IOC_WRITE_STREAM = 0xC010662B   # _IOWR('f', 43, struct fs_write_stream)
OP_GET_MAX = 1 << 0                # FS_WRITE_STREAM_OP_GET_MAX
OP_GET = 1 << 1                    # FS_WRITE_STREAM_OP_GET
OP_SET = 1 << 2                    # FS_WRITE_STREAM_OP_SET
WS_STRUCT = struct.Struct("IIII")  # { op_flags, stream_id, max_streams, rsvd }

# 参考: 源码树 /home/lzh/linux (HEAD 440aad66398d) 的 XFS 行为
#   xfs_write_stream_init(): hw_streams=16 且内部 log → meta=16, log=15, rsvd=2
#   xfs_inode_max_write_streams(): 返回 hw_streams - rsvd = 14
REF_SRCVERSION = "6424D595C1CA23140AF553B"   # 本机源码树编译的 xfs.ko
REF_VERMAGIC = "7.0.0-rc2+ SMP preempt mod_unload modversions "
REF_KERNEL_RELEASE = "7.0.0-rc2+"

PASS, WARN, FAIL, INFO = "PASS", "WARN", "FAIL", "INFO"


def say(tag, msg):
    print(f"[{tag:4}] {msg}")
    sys.stdout.flush()


# ---------------------------------------------------------------------------
# 内核指纹
# ---------------------------------------------------------------------------

def kernel_fingerprint():
    print("=" * 72)
    print("1. 内核指纹（用于与 /home/lzh/linux 源码树基线比对）")
    print("=" * 72)
    rel = platform.release()
    say(INFO, f"uname -r            : {rel}")
    try:
        with open("/proc/version") as f:
            say(INFO, f"/proc/version       : {f.read().strip()}")
    except OSError:
        pass

    srcver = None
    try:
        with open("/sys/module/xfs/srcversion") as f:
            srcver = f.read().strip()
        say(INFO, f"xfs srcversion      : {srcver}")
    except OSError:
        say(INFO, "xfs srcversion      : 无法读取（xfs 可能编进内核而非模块）")

    try:
        out = subprocess.run(["modinfo", "xfs"], capture_output=True, text=True, timeout=10)
        for line in out.stdout.splitlines():
            if line.startswith(("version:", "vermagic:", "srcversion:")):
                say(INFO, f"modinfo xfs {line}")
    except (OSError, subprocess.SubprocessError):
        pass

    cfg = f"/boot/config-{rel}"
    if os.path.exists(cfg):
        keys = ("CONFIG_LOCALVERSION=", "CONFIG_LOCALVERSION_AUTO=",
                "CONFIG_MODVERSIONS=", "CONFIG_XFS_FS=")
        with open(cfg) as f:
            for line in f:
                if line.strip().startswith(keys):
                    say(INFO, f"{os.path.basename(cfg)}: {line.strip()}")

    if srcver and srcver == REF_SRCVERSION:
        say(PASS, f"xfs.ko srcversion 与源码树基线一致 ({REF_SRCVERSION})")
    elif srcver:
        say(FAIL, f"xfs.ko srcversion={srcver} ≠ 源码树基线 {REF_SRCVERSION} → "
                  f"现场运行内核与 /home/lzh/linux 源码不是同一份构建，"
                  f"GET_MAX 异常大概率源于此，需按指南 Step 0.4 重编内核")
    else:
        say(WARN, "无法读取 xfs srcversion，无法远程比对，以 GET_MAX 实测结果为准")
    print()


# ---------------------------------------------------------------------------
# 挂载点与设备发现
# ---------------------------------------------------------------------------

def discover_xfs_mounts(selected):
    """从 /proc/mounts 找 XFS 挂载点，返回 [(mount, src_dev, nvme_name)]"""
    found = []
    with open("/proc/mounts") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 3 or parts[2] != "xfs":
                continue
            mount = parts[1].replace("\\040", " ")
            src = parts[0]
            if selected and mount not in selected:
                continue
            m = re.match(r"/dev/(nvme\d+n\d+)$", src)
            if not m:
                say(WARN, f"跳过 {mount}: 源设备 {src} 不是整盘 NVMe 命名空间")
                continue
            found.append((mount, src, m.group(1)))
    return found


def sysfs_int(nvme, attr):
    try:
        with open(f"/sys/block/{nvme}/queue/{attr}") as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return None


def lba_size(nvme):
    return sysfs_int(nvme, "logical_block_size") or 4096


# ---------------------------------------------------------------------------
# nvme fdp status RUAMW 解析
# ---------------------------------------------------------------------------

def fdp_ruamw(dev):
    """解析 `nvme fdp status <dev>` → {plid: ruamw}；失败返回 None"""
    try:
        out = subprocess.run(["nvme", "fdp", "status", dev],
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        say(WARN, f"无法执行 nvme fdp status {dev}: {e}")
        return None
    if out.returncode != 0:
        say(WARN, f"nvme fdp status {dev} 失败: {out.stderr.strip()[:200]}")
        return None
    ruamw = {}
    plid = None
    for line in out.stdout.splitlines():
        m = re.search(r"Placement Identifier\s+(\d+);", line)
        if m:
            plid = int(m.group(1))
            continue
        m = re.search(r"RUAMW\)\s*:\s*(\d+)", line)
        if m and plid is not None:
            ruamw[plid] = int(m.group(1))
            plid = None
    return ruamw or None


# ---------------------------------------------------------------------------
# FS_IOC_WRITE_STREAM ioctl 封装
# ---------------------------------------------------------------------------

def ws_ioctl(fd, op, stream_id=0):
    """返回 (ok, op_flags, stream_id, max_streams, errno)"""
    buf = WS_STRUCT.pack(op, stream_id, 0, 0)
    try:
        fcntl.ioctl(fd, FS_IOC_WRITE_STREAM, buf, True)
    except OSError as e:
        return False, op, stream_id, 0, e.errno
    opf, sid, mx, _ = WS_STRUCT.unpack(buf)
    return True, opf, sid, mx, 0


ERRNO_HINT = {
    errno.ENOTTY: "内核不支持该 ioctl（需要 7.0.0-rc2 FDP write stream 内核）",
    errno.EOPNOTSUPP: "文件系统/设备不支持 write stream",
    errno.EINVAL: "参数被拒绝（GET_MAX=0 时 SET 会被 xfs 的范围检查拒绝）",
    errno.EPERM: "权限不足",
    errno.ENOSYS: "功能未实现",
}


# ---------------------------------------------------------------------------
# 写入路径（与 3fs chunk engine 完全一致: open → ioctl SET fd → pwrite）
# ---------------------------------------------------------------------------

def streamed_write(path, nbytes, stream_id, block=1 << 20):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        if stream_id:
            ok, _, sid, _, err = ws_ioctl(fd, OP_SET, stream_id)
            if not ok:
                return 0, err
        buf = b"\x5a" * block
        off = 0
        while off < nbytes:
            n = os.pwrite(fd, buf, off)
            if n <= 0:
                raise OSError("pwrite returned 0")
            off += n
        os.fsync(fd)
        return off, 0
    finally:
        os.close(fd)


# ---------------------------------------------------------------------------
# 单个挂载点的完整验收
# ---------------------------------------------------------------------------

def probe_mount(mount, nvme, args):
    print("=" * 72)
    print(f"2. 挂载点 {mount}  (设备 /dev/{nvme})")
    print("=" * 72)
    results = {}
    lba = lba_size(nvme)
    hw = sysfs_int(nvme, "max_write_streams")
    say(INFO, f"sysfs max_write_streams = {hw}, logical_block_size = {lba}")
    if hw is None or hw <= 0:
        say(FAIL, "NVMe 层未上报 FDP 流（max_write_streams<=0）— 检查 FDP 是否启用")
        return results

    nbytes = int(args.gb * (1 << 30))
    probe = os.path.join(mount, f".fdp_preflight_{args.stream}.bin")

    ruamw_before = fdp_ruamw(f"/dev/{nvme}")

    # --- ioctl 序列 ---
    fd = os.open(probe, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        ok, _, _, mx, err = ws_ioctl(fd, OP_GET_MAX)
        if ok:
            results["get_max"] = mx
            expect = max(hw - 2, 0)   # 源码行为: hw - XFS_RSVD_WRITE_STREAMS(2)
            if mx == expect:
                say(PASS, f"GET_MAX = {mx}（与源码预期 hw-2 = {expect} 一致）")
            elif mx == hw:
                say(WARN, f"GET_MAX = {mx} = hw（返回未扣除 XFS 预留流，内核为早期版本；"
                          f"注意避开最高两条流）")
            elif mx == 0:
                say(FAIL, f"GET_MAX = 0 — 内核支持该 ioctl 但 XFS 侧异常！"
                          f"与 envinfo 报告异常一致。此状态下 xfs SET 的范围检查"
                          f"会拒绝一切非 0 stream_id，LMCache/3fs FDP 分流将全部静默失效。")
            else:
                say(WARN, f"GET_MAX = {mx}（源码预期 {expect}），内核版本与源码树不完全一致")
        else:
            results["get_max"] = None
            say(FAIL, f"GET_MAX ioctl 失败 errno={err} ({ERRNO_HINT.get(err, '')}) "
                      f"→ 运行内核无 FS_IOC_WRITE_STREAM 支持，必须重编内核")
            if nbytes:
                os.close(fd)
                _cleanup(probe, args)
                return results

        ok, _, sid, _, _ = ws_ioctl(fd, OP_GET)
        say(INFO, f"GET（SET 前）stream_id = {sid}")

        if nbytes or True:  # SET 探测始终执行（探测内核范围检查行为）
            ok, _, sid, mx2, err = ws_ioctl(fd, OP_SET, args.stream)
            if ok:
                results["set"] = True
                say(PASS, f"SET(stream_id={args.stream}) 成功")
                ok, _, sid, _, _ = ws_ioctl(fd, OP_GET)
                if sid == args.stream:
                    say(PASS, f"GET 回读 = {sid}（设置已生效）")
                    results["get_echo"] = True
                else:
                    say(FAIL, f"GET 回读 = {sid} ≠ {args.stream}")
                    results["get_echo"] = False
            else:
                results["set"] = False
                say(FAIL, f"SET(stream_id={args.stream}) 失败 errno={err} "
                          f"({ERRNO_HINT.get(err, '')}) → 打标被拒绝，"
                          f"FDP 分流无法生效，必须修内核")
    finally:
        os.close(fd)

    # --- 写入 + RUAMW 对比 ---
    if nbytes and results.get("set") and ruamw_before:
        say(INFO, f"写入 {args.gb} GiB（pwrite + fsync，经 SET 的 fd 走 stream {args.stream}）…")
        try:
            written, werr = streamed_write(probe, nbytes, args.stream)
        except OSError as e:
            written, werr = 0, e.errno
        if werr:
            say(FAIL, f"写入失败 errno={werr}")
        else:
            say(INFO, f"已写 {written} 字节，fsync 完成，等待 3s 落盘…")
            time.sleep(3)
            ruamw_after = fdp_ruamw(f"/dev/{nvme}")
            if ruamw_after:
                target_plid = args.stream - 1   # kernel: plids[stream_id-1]
                verdict_ruamw(ruamw_before, ruamw_after, target_plid,
                              written, lba, hw, results)
            else:
                say(WARN, "写入后 RUAMW 采样失败，无法做物理路由判定")
    elif nbytes and not results.get("set"):
        say(INFO, "SET 已失败，跳过写入（写入只会落到默认放置区，无验证意义）")

    _cleanup(probe, args)
    return results


def _cleanup(probe, args):
    if not args.keep:
        try:
            os.unlink(probe)
        except OSError:
            pass


def verdict_ruamw(before, after, target_plid, written, lba, hw, results):
    print(f"    {'PLID':>6} {'before':>12} {'after':>12} {'Δ':>10}")
    total_other = 0
    rsvd = {hw - 1, hw - 2} if hw else set()   # XFS meta/log 占最高两条
    for plid in sorted(before):
        delta = before.get(plid, 0) - after.get(plid, 0)
        if delta == 0:
            continue
        mark = "  ← 目标" if plid == target_plid else (
               "  (XFS meta/log 预留)" if plid in rsvd else "")
        print(f"    {plid:>6} {before[plid]:>12} {after.get(plid, '-'):>12} {delta:>10}{mark}")
        if plid != target_plid and plid not in rsvd:
            total_other += delta

    expect_lbas = written // lba
    d_target = before.get(target_plid, 0) - after.get(target_plid, 0)
    if d_target >= expect_lbas * 0.9:
        say(PASS, f"目标 PLID {target_plid} RUAMW 下降 {d_target} ≈ 写入 {expect_lbas} LBA"
                  f"（{lba}B）→ stream {target_plid + 1} 真正路由到 FDP 对应介质区")
        results["ruamw"] = True
    else:
        say(FAIL, f"目标 PLID {target_plid} RUAMW 仅下降 {d_target}，"
                  f"期望 ~{expect_lbas} → 写入未路由到目标流（stream 打标在内核中被丢弃）")
        results["ruamw"] = False
    if total_other > expect_lbas * 0.1:
        say(WARN, f"其他非预留 PLID 合计下降 {total_other}，存在串流/默认放置写入，"
                  f"记录数据供分析")
    print()


# ---------------------------------------------------------------------------
# 对照组：stream=0（默认放置）写一小块，看默认 RUAMW 分布
# ---------------------------------------------------------------------------

def probe_baseline(mount, nvme, args):
    print("=" * 72)
    print(f"3. 对照组 {mount}: stream=0（默认放置）写 {args.baseline_gb} GiB")
    print("=" * 72)
    nbytes = int(args.baseline_gb * (1 << 30))
    if nbytes == 0:
        return
    lba = lba_size(nvme)
    probe = os.path.join(mount, ".fdp_preflight_0.bin")
    before = fdp_ruamw(f"/dev/{nvme}")
    if not before:
        say(WARN, "RUAMW 采样失败，跳过对照组")
        return
    written, err = streamed_write(probe, nbytes, 0)
    time.sleep(3)
    after = fdp_ruamw(f"/dev/{nvme}")
    if after and not err:
        deltas = {p: before.get(p, 0) - after.get(p, 0) for p in before}
        hot = sorted((d, p) for p, d in deltas.items() if d > 0)
        print(f"    默认放置写入分布（PLID: ΔLBA）: "
              f"{ {p: d for d, p in hot} }")
        say(INFO, f"记录该分布作为部署后 WAF 实验的 baseline 参照")
    _cleanup(probe, args)
    print()


# ---------------------------------------------------------------------------
# 总判定
# ---------------------------------------------------------------------------

def summarize(all_results, hw_streams, args):
    print("=" * 72)
    print("4. 总判定")
    print("=" * 72)
    ok_get_max = all(r.get("get_max") not in (None, 0) for r in all_results.values())
    ok_set = all(r.get("set") for r in all_results.values())
    ok_ruamw = all(r.get("ruamw") for r in all_results.values()) and \
        any(r.get("ruamw") for r in all_results.values())

    if not all_results:
        say(FAIL, "没有可测的 XFS 挂载点")
        return 2
    if ok_get_max and ok_set and ok_ruamw:
        say(PASS, "全链路验证通过：GET_MAX 正常、SET 生效、数据真实路由到目标 PLID")
        say(INFO, "→ 按指南继续 Step 1（获取代码）后续部署。"
                  "3fs fdp_compaction_stream_id=2、LMCache start_fdp_stream_id=3/fdp_stream_number=8 的规划可用")
        return 0
    if not ok_get_max and ok_set and ok_ruamw:
        say(WARN, "GET_MAX 异常(0) 但 SET+RUAMW 实测有效：LMCache USRBIO 分流可用，"
                  "但 3fs compaction 依赖 GET_MAX 做范围检查会静默回退 0 → "
                  "compaction 分流失效。仍建议按指南 Step 0.4 修内核")
        return 1
    say(FAIL, "FDP write stream 链路不可用 → 2026-11-17 envinfo 的 GET_MAX=0 异常属实，"
              "当前运行内核与 /home/lzh/linux 源码行为不一致")
    say(INFO, "→ 执行指南 Step 0.4：用现场 /home/lzh/linux（核对 git HEAD=440aad66398d "
              "后重编内核/模块）并重新引导，然后重跑本脚本确认 GET_MAX=hw-2")
    return 2


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-m", "--mounts", default="",
                    help="逗号分隔的 XFS 挂载点，默认自动发现全部")
    ap.add_argument("-s", "--stream", type=int, default=3,
                    help="验收用的 stream_id（默认 3，对应 PLID 2，避开 0/1/2 号规划位）")
    ap.add_argument("-g", "--gb", type=float, default=8,
                    help="每个挂载点写入 GiB 数（默认 8；0 = 只做 ioctl 探测）")
    ap.add_argument("--baseline", action="store_true",
                    help="额外做一轮 stream=0 对照写入")
    ap.add_argument("--baseline-gb", type=float, default=1,
                    help="对照组写入 GiB 数（默认 1）")
    ap.add_argument("--keep", action="store_true", help="保留测试文件")
    args = ap.parse_args()

    if os.geteuid() != 0:
        say(WARN, "非 root 运行：RUAMW 对比大概率失败（nvme fdp status 需要 root）")

    kernel_fingerprint()

    selected = set(filter(None, args.mounts.split(",")))
    mounts = discover_xfs_mounts(selected)
    if not mounts:
        say(FAIL, "未找到（符合条件的）XFS 挂载点")
        return 2
    say(INFO, "待测挂载点: " + ", ".join(f"{m}({n})" for m, _, n in mounts))
    print()

    all_results = {}
    hw = None
    for mount, dev, nvme in mounts:
        hw = sysfs_int(nvme, "max_write_streams") or hw
        res = probe_mount(mount, nvme, args)
        all_results[mount] = res
        if args.baseline and args.gb > 0:
            probe_baseline(mount, nvme, args)

    return summarize(all_results, hw, args)


if __name__ == "__main__":
    sys.exit(main())
