#!/usr/bin/env bash
# =============================================================================
# collect_env_info.sh — 3FS + LMCache FDP write-stream 部署前环境信息收集脚本
#
# 用途: 在目标机器(dskna004 / dsksa304 / dsksa305 / dsksa348)上运行,
#       收集部署 3FS (FDP write stream) + LMCache (hf3fs L2 backend) 所需的
#       全部环境信息, 输出一份文本报告, 发回给部署指南制定者即可。
#
# 安全性: 默认完全只读, 不修改任何磁盘/配置/服务。
#         --allow-write-probe 时才会在 XFS 挂载点上创建并删除一个 4KB 临时文件
#         (用于探测内核 FS_IOC_WRITE_STREAM ioctl 支持, 探测后立即删除)。
#
# 用法:
#   sudo bash collect_env_info.sh                       # 只读收集(推荐先跑这个)
#   sudo bash collect_env_info.sh --allow-write-probe   # 允许 FDP ioctl 写探针
#   sudo bash collect_env_info.sh --peers 172.16.18.64,172.16.18.65,172.16.18.169
#                                                       # 顺带 ping 其他三台机器
#   sudo bash collect_env_info.sh -o /tmp               # 指定报告输出目录
#
# 输出: <输出目录>/<主机名>_envinfo_<时间戳>.txt
# 建议: 4 台机器各跑一次, 把 4 份报告全部发回。
# =============================================================================
set -u

ALLOW_WRITE_PROBE=0
PEERS=""
OUTDIR="$(pwd)"
for arg in "$@"; do
  case "$arg" in
    --allow-write-probe) ALLOW_WRITE_PROBE=1 ;;
    --peers)             : ;; # 值在下一个参数, 下面再取
    -o|--outdir)         : ;;
    *) 
      prev="${PREV:-}"
      case "$prev" in
        --peers) PEERS="$arg" ;;
        -o|--outdir) OUTDIR="$arg" ;;
      esac
      ;;
  esac
  PREV="$arg"
done

TS="$(date +%Y%m%d_%H%M%S)"
REPORT="$OUTDIR/$(hostname 2>/dev/null || echo unknown)_envinfo_$TS.txt"
mkdir -p "$OUTDIR"

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
exec_fd=3
eval "exec $exec_fd>$REPORT" || { echo "无法写报告文件 $REPORT" >&2; exit 1; }

out() { printf '%s\n' "$*" >&$exec_fd; }
say() { printf '%s\n' "$*"; }

section() {
  out ""
  out "############################################################################"
  out "## $*"
  out "############################################################################"
}

# run <标签> <命令...>  —— 执行命令并把输出记入报告; 命令不存在/失败不中断
run() {
  local label="$1"; shift
  out ""
  out "--- $label ---"
  out "\$ $*"
  "$@" >&$exec_fd 2>&1
  local rc=$?
  [ $rc -ne 0 ] && out "[退出码 $rc]"
  return 0
}

# runsh <标签> <shell片段>  —— 需要 shell 语法(管道/重定向)时使用
runsh() {
  local label="$1"; shift
  out ""
  out "--- $label ---"
  out "\$ $*"
  bash -c "$*" >&$exec_fd 2>&1
  return 0
}

have() { command -v "$1" >/dev/null 2>&1; }

# ============================================================================
say "== 环境信息收集开始: 报告将写入 $REPORT =="
if [ "$(id -u)" -ne 0 ]; then
  say "[警告] 当前不是 root。nvme fdp status / dmesg / 部分 ib 命令会失败, 建议用 sudo 运行。"
fi
say "[提示] 只读模式$([ $ALLOW_WRITE_PROBE -eq 1 ] && echo ' + FDP ioctl 写探针已开启' || echo '(无写探针, 可加 --allow-write-probe)')"

# ============================================================================
section "1. 系统基本信息"
# ============================================================================
run "hostname / 域名" hostname -f
runsh "uname" "uname -a"
runsh "操作系统" "cat /etc/os-release 2>/dev/null"
runsh "内核版本" "uname -r; echo; ls /boot/vmlinuz-* 2>/dev/null; echo; rpm -qa 2>/dev/null | grep -i kernel | sort; dpkg -l 2>/dev/null | grep -i linux-image"
runsh "内核启动参数" "cat /proc/cmdline"
runsh "内核配置中 stream/fdp 相关项" "grep -i -E 'stream|fdp|fuse' /boot/config-\$(uname -r) 2>/dev/null | head -40"
runsh "glibc 版本(决定能否直接分发预编译二进制)" "ldd --version | head -1"
runsh "uptime" "uptime"
runsh "是否虚拟机/物理机" "systemd-detect-virt 2>/dev/null; dmidecode -s system-manufacturer 2>/dev/null; dmidecode -s system-product-name 2>/dev/null"
runsh "CPU / 架构 / NUMA" "lscpu | head -30"
runsh "内存" "free -h; echo; numactl --hardware 2>/dev/null | head -20"
runsh "时间与时区(集群要求时间同步)" "date; timedatectl 2>/dev/null | head -10; chronyc tracking 2>/dev/null | head -5"

# ============================================================================
section "2. 网络与 RDMA (3FS 全链路走 RDMA/RoCE, 必须收集)"
# ============================================================================
runsh "网卡与 IP" "ip -o addr show"
runsh "路由" "ip route show"
runsh "网卡详情/速率/MTU" "for i in \$(ls /sys/class/net/); do echo \"== \$i ==\"; ethtool \$i 2>/dev/null | grep -E 'Speed|Duplex|Link'; cat /sys/class/net/\$i/mtu 2>/dev/null; done"
runsh "RDMA 设备 (ibv_devinfo)" "ibv_devinfo -v 2>/dev/null || echo '未安装 libibverbs/ibv_devinfo'"
runsh "RDMA 端口状态 (ibstat)" "ibstat 2>/dev/null || echo '未安装 infiniband-diags/ibstat'"
runsh "rdma link" "rdma link show 2>/dev/null"
runsh "RoCE GID 表" "cat /proc/net/rdma/*/gids 2>/dev/null | head -40; show_gids 2>/dev/null | head -40"
runsh "已装 RDMA 相关包" "rpm -qa 2>/dev/null | grep -iE 'ibverbs|rdma|infiniband|roce' | sort; dpkg -l 2>/dev/null | grep -iE 'ibverbs|rdma|infiniband' | awk '{print \$2}'"
runsh "防火墙状态" "systemctl is-active firewalld 2>/dev/null; firewall-cmd --list-all 2>/dev/null; iptables -L -n 2>/dev/null | head -20; ufw status 2>/dev/null"
runsh "SELinux / AppArmor" "getenforce 2>/dev/null; sestatus 2>/dev/null | head -5; aa-status 2>/dev/null | head -5"
runsh "/etc/hosts" "cat /etc/hosts"
runsh "DNS" "cat /etc/resolv.conf 2>/dev/null"

if [ -n "$PEERS" ]; then
  runsh "与其他节点 ICMP 连通性 (ping)" "for p in \$(echo $PEERS | tr ',' ' '); do echo \"== ping \$p ==\"; ping -c 3 -W 2 \$p 2>&1 | tail -2; done"
  runsh "与其他节点 9000B 巨帧 MTU 探测 (RoCE 常用 MTU 9000, -M do 禁止分片)" "for p in \$(echo $PEERS | tr ',' ' '); do echo \"== MTU9000 -> \$p ==\"; ping -M do -s 8972 -c 2 -W 2 \$p 2>&1 | tail -2; done"
  out ""
  out "说明: 真正的 RDMA 连通性/带宽需部署后用 ib_write_bw / rping 实测, 本脚本只做 L3 与 MTU 预检。"
else
  out ""
  out "--- 跨节点连通性: 未指定 --peers, 跳过 (建议: --peers 172.16.12.210,172.16.18.64,172.16.18.65,172.16.18.169) ---"
fi

# ============================================================================
section "3. 块设备 / NVMe / FDP 状态 (核心!)"
# ============================================================================
runsh "块设备总览" "lsblk -o NAME,TYPE,SIZE,ROTA,SERIAL,MODEL,FSTYPE,MOUNTPOINTS"
runsh "已挂载文件系统" "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS"
runsh "分区表 (确认盘上现有数据, 部署时会决定是否格式化)" "for d in \$(ls /dev/nvme*n1 2>/dev/null; ls /dev/sd[a-z] 2>/dev/null); do echo \"== \$d ==\"; parted -s \$d print 2>/dev/null || fdisk -l \$d 2>/dev/null | head -20; done"
runsh "磁盘空间" "df -hT"

if have nvme; then
  runsh "nvme-cli 版本 (fdp 子命令需较新版本)" "nvme version"
  runsh "NVMe 设备列表 (型号/固件/命名空间)" "nvme list"
  # 逐设备收集 FDP 状态
  DEVS="$(ls /dev/nvme*n1 2>/dev/null; ls /dev/nvme[0-9]* 2>/dev/null | grep -v n1 || true)"
  for d in $(lsblk -dpno NAME 2>/dev/null | grep -E '/nvme[0-9]+$'); do
    runsh "FDP 状态: $d (nvme fdp status)" "nvme fdp status $d 2>&1 | head -60"
    runsh "FDP 配置: $d (nvme fdp configs)" "nvme fdp configs $d 2>&1 | head -40"
    runsh "FDP 状态(JSON): $d" "nvme fdp status -b $d 2>/dev/null | head -100"
  done
  for n in $(lsblk -dpno NAME 2>/dev/null | grep -E '/nvme[0-9]+n[0-9]+$'); do
    runsh "FDP 状态(按命名空间): $n" "nvme fdp status $n 2>&1 | head -60"
  done
  runsh "NVMe 控制器标识 (每设备)" "for d in \$(lsblk -dpno NAME | grep -E '/nvme[0-9]+\$'); do echo \"== \$d ==\"; nvme id-ctrl \$d 2>/dev/null | grep -iE 'mn|sn|fr|vwc|npss|fw' | head -15; done"
  runsh "NVMe 格式/扇区大小" "for d in \$(lsblk -dpno NAME | grep nvme); do echo \"== \$d ==\"; cat /sys/block/\${d#/dev/}/queue/logical_block_size 2>/dev/null; cat /sys/block/\${d#/dev/}/queue/physical_block_size 2>/dev/null; done"
  runsh "write stream 能力 (sysfs, 只读; max_write_streams=硬件 FDP 流数)" "for d in \$(lsblk -dpno NAME | grep nvme); do n=\${d#/dev/}; echo \"== \$d ==\"; echo -n 'max_write_streams: '; cat /sys/block/\$n/queue/max_write_streams 2>/dev/null || echo 'n/a(内核无此属性)'; echo -n 'write_stream_granularity: '; cat /sys/block/\$n/queue/write_stream_granularity 2>/dev/null || echo 'n/a'; done"
else
  out ""
  out "--- nvme-cli 未安装! 无法查询 FDP 状态, 请记录 (安装 nvme-cli >= 2.1 才有 fdp 子命令) ---"
fi

runsh "NVMe PCI 拓扑" "lspci | grep -i nvme; echo; lspci -vvv 2>/dev/null | grep -A 20 -i 'nvme' | grep -E 'Non-Volatile|LNKCap|LNKSta' | head -20"
runsh "dmesg 中 NVMe/FDP/stream 相关" "dmesg 2>/dev/null | grep -iE 'nvme|fdp|write.?stream' | tail -40"

# ============================================================================
section "4. XFS / FDP ioctl 内核支持探测 (核心!)"
# ============================================================================
out ""
out "说明: 3FS FDP write stream 依赖内核私有 ioctl FS_IOC_WRITE_STREAM (0xC010662B,"
out "      struct fs_write_stream{op,stream_id,...}) 作用于 XFS 文件。"
out "      目标基线: 总部 FDP 内核 7.0.0-rc2+ (含该 ioctl + XFS write stream 实现)。"
out "      本节探测当前内核是否支持该 ioctl, 以及 XFS 文件上 GET_MAX 返回的最大流数。"
out "      只读模式下使用挂载点上已有文件; --allow-write-probe 时才创建临时文件。"

runsh "xfs 挂载点" "findmnt -t xfs -o TARGET,SOURCE,OPTIONS"
runsh "xfsprogs 工具" "which mkfs.xfs xfs_info 2>/dev/null; mkfs.xfs -V 2>/dev/null"
runsh "所有 xfs 挂载点 xfs_info" "for m in \$(findmnt -rn -t xfs -o TARGET); do echo \"== \$m ==\"; xfs_info \$m 2>/dev/null | head -8; done"
runsh "已安装内核是否带 FS_IOC_WRITE_STREAM (关键: 3fs storage 必需)" "echo '当前运行内核:'; k=\$(uname -r); f=/lib/modules/\$k/build/include/uapi/linux/fs.h; if [ -f \"\$f\" ]; then grep -H 'FS_IOC_WRITE_STREAM' \"\$f\" || echo \"\$f 中无该定义\"; else echo \"\$f 不存在(该内核未装 headers/build 树)\"; fi; echo; echo '所有已安装内核:'; found=0; for f in /lib/modules/*/build/include/uapi/linux/fs.h; do [ -f \"\$f\" ] || continue; found=1; grep -q FS_IOC_WRITE_STREAM \"\$f\" && echo \"\$f : 支持\" || echo \"\$f : 不支持\"; done; [ \$found -eq 0 ] && echo '未找到任何 /lib/modules/*/build 内核头文件树'; echo; echo '内核源码树:'; ls -d /usr/src/linux* /usr/src/kernels/* 2>/dev/null"

# ---- 用 python3 做 ioctl 探测 ----
XFS_MOUNTS="$(findmnt -rn -t xfs -o TARGET 2>/dev/null)"
if have python3 && [ -n "$XFS_MOUNTS" ]; then
  for m in $XFS_MOUNTS; do
    runsh "FDP ioctl 探测: $m (GET_MAX=1)" "python3 - '$m' $ALLOW_WRITE_PROBE <<'PYEOF'
import fcntl, os, struct, sys, tempfile

mount = sys.argv[1]
allow_write = sys.argv[2] == '1'
FS_IOC_WRITE_STREAM = 0xC010662B   # _IOWR('f', 43, struct fs_write_stream)
OP_GET_MAX = 1 << 0
OP_GET     = 1 << 1
OP_SET     = 1 << 2

probe_path = None
created = False
if allow_write:
    probe_path = os.path.join(mount, '.fdp_probe_tmp')
    fd = os.open(probe_path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
    created = True
else:
    # 只读: 找一个已有文件
    import subprocess
    r = subprocess.run(['find', mount, '-maxdepth', '3', '-type', 'f'],
                       capture_output=True, text=True, timeout=30)
    cand = (r.stdout or '').strip().splitlines()
    if not cand:
        print('只读模式且挂载点上找不到已有文件, 无法探测; 请加 --allow-write-probe 重跑')
        sys.exit(0)
    probe_path = cand[0]
    fd = os.open(probe_path, os.O_RDONLY)

print(f'探测文件: {probe_path} (created={created})')
try:
    ws = struct.pack('IIII', OP_GET_MAX, 0, 0, 0)
    fcntl.ioctl(fd, FS_IOC_WRITE_STREAM, ws)
    op, sid, mx, rsvd = struct.unpack('IIII', ws)
    print(f'GET_MAX 成功: op_flags={op} stream_id={sid} max_streams={mx} rsvd={rsvd}')
    if mx > 0:
        print(f'结论: 内核支持 FS_IOC_WRITE_STREAM; 该 XFS 上用户可用 stream id 范围 = 0..{mx}')
        print('规划建议: 文件名(struct fs_write_stream)布局为 op_flags,stream_id,max_streams,rsvd;')
        print('          XFS 默认已把最高 2 条流保留给 meta(最高)和 log(次高), GET_MAX 已扣除;')
        print('          3fs fdp_compaction_stream_id 建议 2;')
        print(f'          LMCache start_fdp_stream_id >= 3 且 start + fdp_stream_number - 1 <= {mx}')
    else:
        print('结论: 内核支持该 ioctl, 但设备/文件系统侧 max_streams=0 (盘未开 FDP 或非 XFS?)')
except OSError as e:
    meaning = {25: 'ENOTTY: 内核不支持该 ioctl (需要 Samsung FDP write stream 内核)',
               95: 'EOPNOTSUPP: 文件系统/设备不支持',
               38: 'ENOSYS: 功能未实现',
               9: 'EBADF: fd 权限不足(只读 fd) '}.get(e.errno, '')
    print(f'GET_MAX 失败: errno={e.errno} {e.strerror} {meaning}')
finally:
    os.close(fd)
    if created:
        os.unlink(probe_path)
        print('临时探测文件已删除')
PYEOF"
  done
else
  out ""
  out "--- 无法做 ioctl 探测: 需要 python3 且存在 XFS 挂载点 (XFS 挂载点: '$XFS_MOUNTS') ---"
  out "--- 若目标 NVMe 尚未格式化成 XFS, 属正常; 届时格式化后需再探测内核 ioctl 支持 ---"
fi

# ============================================================================
section "5. 存储节点运行环境 (3fs storage 依赖)"
# ============================================================================
runsh "fs.aio-max-nr (3fs 要求调大)" "sysctl fs.aio-max-nr fs.aio-max-nr-default 2>/dev/null; sysctl fs.aio-nr"
runsh "fd / memlock / 进程数限制" "ulimit -n; ulimit -l; ulimit -u; cat /proc/sys/fs/nr_open"
runsh "/dev/shm 大小 (USRBIO iov 共享内存)" "df -h /dev/shm"
runsh "hugepages" "sysctl vm.nr_hugepages vm.nr_hugepages_meminfo 2>/dev/null; grep -i huge /proc/meminfo"
runsh "FoundationDB (3fs 元数据后端, 客户端与服务端版本必须一致)" "which fdbserver fdbcli 2>/dev/null; fdbserver --version 2>/dev/null; fdbcli --version 2>/dev/null; rpm -qa 2>/dev/null | grep -i foundationdb; dpkg -l 2>/dev/null | grep -i foundationdb; ls /etc/foundationdb/ 2>/dev/null"
runsh "已有的 3fs / fdb 进程与服务" "ps aux | grep -E 'storage_main|meta_main|mgmtd_main|hf3fs_fuse|fdbserver' | grep -v grep; systemctl list-unit-files 2>/dev/null | grep -iE '3fs|fdb|foundation'"
runsh "当前监听端口 (确认端口无冲突)" "ss -tlnp 2>/dev/null | head -40"

# ============================================================================
section "6. GPU 客户端运行环境 (LMCache/vLLM, dskna004 重点)"
# ============================================================================
if have nvidia-smi; then
  runsh "GPU 概况" "nvidia-smi"
  runsh "GPU 详细" "nvidia-smi -q 2>/dev/null | grep -E 'Product Name|Driver Version|CUDA Version|FB Memory|Memory Size|VBIOS' | head -20"
else
  out ""
  out "--- 本机无 nvidia-smi (可能是存储节点, 正常; GPU 客户端必填) ---"
fi
runsh "CUDA 工具链" "nvcc --version 2>/dev/null; ls /usr/local/ | grep -i cuda"
runsh "Python 环境" "python3 --version 2>/dev/null; which python3 pip3 pip uv conda 2>/dev/null; conda env list 2>/dev/null"
runsh "已装关键 Python 包 (torch/vllm/lmcache/hf3fs)" "python3 -m pip list 2>/dev/null | grep -iE '^(torch|vllm|lmcache|hf3fs|transformers|numpy) '"
runsh "FUSE 支持 (hf3fs_fuse_main 需要)" "ls -l /dev/fuse 2>/dev/null || echo '/dev/fuse 不存在'; grep fuse /proc/filesystems; which fusermount3 fusermount 2>/dev/null; pkg-config --modversion fuse3 2>/dev/null"
runsh "NVIDIA peer memory / nvidia-fabricmanager" "systemctl is-active nvidia-fabricmanager 2>/dev/null; lsmod 2>/dev/null | grep -E 'nvidia|nv_peer' | head"

# ============================================================================
section "7. 构建工具链 (决定 3fs/LMCache 是现场构建还是分发二进制)"
# ============================================================================
runsh "编译器" "gcc --version 2>/dev/null | head -1; g++ --version 2>/dev/null | head -1; clang-14 --version 2>/dev/null | head -1; clang++-14 --version 2>/dev/null | head -1; clang --version 2>/dev/null | head -1"
runsh "cmake / make / ninja" "cmake --version 2>/dev/null | head -1; make --version 2>/dev/null | head -1; ninja --version 2>/dev/null"
runsh "Rust (3fs chunk_engine 必需)" "rustc --version 2>/dev/null; cargo --version 2>/dev/null || echo 'rust 未安装'"
runsh "3fs 依赖库" "for p in libfuse3-dev libboost-dev libgflags-dev libglog-dev libaio-dev libunwind-dev libssl-dev; do dpkg -l \$p 2>/dev/null | grep ^ii || rpm -q \${p%%-dev*}-devel 2>/dev/null; done; ldconfig -p 2>/dev/null | grep -E 'libfuse3|libaio|libglog|libgflags|libboost_system' | head"
runsh "git / rsync / envsubst (部署脚本需要)" "git --version 2>/dev/null; rsync --version 2>/dev/null | head -1; which envsubst 2>/dev/null"
runsh "docker / container 工具" "docker --version 2>/dev/null; podman --version 2>/dev/null"

# ============================================================================
section "8. 杂项"
# ============================================================================
runsh "OS 盘剩余空间 (部署包/日志存放)" "df -h / /tmp /var 2>/dev/null"
runsh "系统语言/编码" "locale 2>/dev/null | head -3"
runsh "安全策略 (pam limits)" "grep -rE 'aio|max open|nofile|memlock' /etc/security/limits.conf /etc/security/limits.d/ 2>/dev/null | grep -v '^#'"

# ============================================================================
section "9. 部署前置条件快速判定 (根据上面收集结果自动汇总)"
# ============================================================================
KERNEL_FDP="no"
KF="/lib/modules/$(uname -r)/build/include/uapi/linux/fs.h"
if [ -f "$KF" ] && grep -q FS_IOC_WRITE_STREAM "$KF" 2>/dev/null; then
  KERNEL_FDP="yes"
fi
FDP_DEVS=0
for q in /sys/block/nvme*/queue/max_write_streams; do
  [ -e "$q" ] || continue
  [ "$(cat "$q" 2>/dev/null || echo 0)" != "0" ] && FDP_DEVS=$((FDP_DEVS + 1))
done
AIO_MAX=$(sysctl -n fs.aio-max-nr 2>/dev/null || echo 0)
NOFILE=$(ulimit -n 2>/dev/null || echo 0)
SHM_GB=$(df -BG /dev/shm 2>/dev/null | awk 'NR==2{gsub("G","",$2); print $2}')
GPU="no"; have nvidia-smi && GPU="yes"
FUSE="no"; [ -e /dev/fuse ] && FUSE="yes"
RDMA="no"; have ibv_devinfo && ibv_devinfo >/dev/null 2>&1 && RDMA="yes"
FDB="no"; have fdbserver && FDB="yes"

v() { # v <名称> <当前值> <PASS|WARN|INFO> <说明>
  out "[$3] $1 = $2  $4"
}

out "当前内核: $(uname -r)"
v "内核带 FS_IOC_WRITE_STREAM (存储节点必需)" "$KERNEL_FDP" \
  "$([ "$KERNEL_FDP" = yes ] && echo PASS || echo WARN)" \
  "$([ "$KERNEL_FDP" = yes ] && echo '' || echo '→ 若本机是存储节点, 必须切换到 7.0.0-rc2+ 基线内核')"
v "开启 FDP 的 NVMe 数量 (max_write_streams>0)" "$FDP_DEVS" \
  "$([ "$FDP_DEVS" -gt 0 ] && echo PASS || echo INFO)" \
  "$([ "$FDP_DEVS" -gt 0 ] && echo '→ 存储节点应 >=1 (预期每台 3 块 PM1763)' || echo '→ 若本机是存储节点则异常: 检查盘 FDP 使能/内核')"
v "fs.aio-max-nr" "$AIO_MAX" \
  "$([ "$AIO_MAX" -ge 67108864 ] 2>/dev/null && echo PASS || echo WARN)" \
  "$([ "$AIO_MAX" -ge 67108864 ] 2>/dev/null && echo '' || echo '→ 存储节点需 sysctl -w fs.aio-max-nr=67108864')"
v "ulimit -n (当前 shell)" "$NOFILE" \
  "$([ "$NOFILE" -ge 1048576 ] 2>/dev/null && echo PASS || echo WARN)" \
  "$([ "$NOFILE" -ge 1048576 ] 2>/dev/null && echo '' || echo '→ 存储服务建议 >=1048576 (chunk engine 需大量 fd)')"
v "/dev/shm 容量(GB)" "${SHM_GB:-?}" "INFO" "→ 客户端 USRBIO iov 用共享内存, 建议 >= 每线程 400MB 规模"
v "RDMA 设备" "$RDMA" \
  "$([ "$RDMA" = yes ] && echo PASS || echo WARN)" \
  "$([ "$RDMA" = yes ] && echo '' || echo '→ 3FS 全链路依赖 RDMA/RoCE, 所有节点都需要')"
v "FoundationDB" "$FDB" "INFO" "→ 至少 1 台(通常是元数据节点)需要 fdbserver/fdbcli >=7.1"
v "GPU (nvidia-smi)" "$GPU" "INFO" "→ 仅 GPU 客户端需要"
v "FUSE (/dev/fuse)" "$FUSE" "INFO" "→ 3FS 客户端(hf3fs_fuse_main)需要"

out ""
out "角色判定参考:"
out "  - 若 内核FDP=yes 且 开启FDP的NVMe>0  ->  可作 3FS 存储节点"
out "  - 若 GPU=yes 且 FUSE=yes            ->  可作 LMCache/vLLM 客户端"
out "  - 若 FDB=yes 或可安装 FDB           ->  可作 mgmtd/meta 节点(通常与某台存储节点合并)"

# ============================================================================
out ""
out "############################################################################"
out "## 收集完成"
out "############################################################################"
out "报告文件: $REPORT"
out "请将 4 台机器的报告全部发回, 用于生成定制化部署指南。"
# ============================================================================
say ""
say "== 完成! 报告已写入: $REPORT =="
say "   请把该文件发回。若存储盘还未格式化为 XFS, 建议格式化后用 --allow-write-probe 再跑一次。"
