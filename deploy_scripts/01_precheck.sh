#!/bin/bash
# 01_precheck.sh — 全节点只读预检 (不修改任何系统状态)
# 在 4 台服务器上各自执行:  sudo bash 01_precheck.sh
# 对应部署指南 §1。任何 FAIL 都必须解决后再执行后续脚本。
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"
require_root
detect_node
FAIL_COUNT=0

step "节点信息"
info "hostname=$(hostname)  角色=${ROLE}  node_id=${NODE_ID:-N/A}  IPoIB=${IPoIB}"

step "内核版本 (必须是 Samsung FDP 内核 7.0.0-rc2)"
KVER=$(uname -r)
if [[ "${KVER}" == *"7.0.0-rc2"* ]]; then
    info "运行内核: ${KVER} — OK (GRUB 锁定已由你方完成, 本脚本不再处理)"
else
    fail "运行内核为 ${KVER}, 不是 7.0.0-rc2 — FDP ioctl 将不可用, 禁止继续部署"
fi

KHDR="/lib/modules/${KVER}/build/include/uapi/linux/fs.h"
if grep -q "FS_IOC_WRITE_STREAM" "${KHDR}" 2>/dev/null; then
    info "内核头文件含 FS_IOC_WRITE_STREAM — OK"
else
    if [[ "${ROLE}" == "storage" ]]; then
        fail "存储节点内核缺少 FS_IOC_WRITE_STREAM (${KHDR})"
    else
        warn "内核头文件未见 FS_IOC_WRITE_STREAM (client 节点仅影响 ioctl 透传验证)"
    fi
fi

step "时间同步 (chrony)"
if chronyc tracking 2>/dev/null | grep -q "Leap status     : Normal"; then
    info "chrony 已同步"
else
    fail "chrony 未同步 (Leap status != Normal), 分布式租约会异常"
fi

step "3FS 二进制 (${SRC})"
if [[ "${ROLE}" == "meta" ]]; then
    NEED=(admin_cli hf3fs_fuse_main meta_main mgmtd_main monitor_collector_main storage_main)
else
    NEED=(admin_cli storage_main)
fi
for b in "${NEED[@]}"; do
    check_exists "${BIN_DIR}/${b}" || fail "缺少二进制 ${BIN_DIR}/${b}"
done
[[ ${FAIL_COUNT} -eq 0 ]] && info "二进制齐全"

if [[ "${ROLE}" == "storage" ]]; then
    step "FDP 设备状态 (nvme3n1 / nvme4n1)"
    for dev in /dev/nvme3n1 /dev/nvme4n1; do
        if [[ ! -e "${dev}" ]]; then
            fail "${dev} 不存在"
            continue
        fi
        out=$(nvme fdp status "${dev}" -o json 2>/dev/null) \
            && pids=$(echo "${out}" | python3 -c "import json,sys; print(' '.join(str(r['pid']) for r in json.load(sys.stdin).get('ruhss',[])))") \
            || { fail "nvme fdp status ${dev} 失败 (盘未开 FDP?)"; continue; }
        info "${dev}: PID 列表 = ${pids:-<空>}"
        # PID 应从 0 连续编号 (stream N → PLID N-1 的映射依赖连续性)
        python3 -c "
pids = sorted(int(x) for x in '${pids}'.split())
assert pids == list(range(len(pids))), 'PID 不连续!'
print('  [INFO] PID 从 0 连续编号 — OK')
" || warn "${dev} PID 列表非连续, stream→PLID 映射需人工核对"
    done

    step "XFS ioctl GET_MAX (data3 / data4)"
    for m in /storage/data3 /storage/data4; do
        if ! mountpoint -q "${m}"; then
            fail "${m} 未挂载"
            continue
        fi
        python3 - "${m}" <<'EOF' || FAIL_COUNT=$((FAIL_COUNT + 1))
import fcntl, os, struct, sys
FS_IOC_WRITE_STREAM = 0xC010662B
OP_GET_MAX = 1
fd = os.open(sys.argv[1], os.O_RDONLY)
ws = struct.pack("IIII", OP_GET_MAX, 0, 0, 0)
try:
    fcntl.ioctl(fd, FS_IOC_WRITE_STREAM, ws)
    op, sid, mx, rsvd = struct.unpack("IIII", ws)
    print(f"  [INFO] {sys.argv[1]}: GET_MAX = {mx}")
    assert mx >= 3, f"GET_MAX={mx} 过小, 无法同时容纳 compaction(2)+LMCache(3..)"
except OSError as e:
    print(f"  [FAIL] {sys.argv[1]}: ioctl 失败 errno={e.errno} {e.strerror}")
    raise SystemExit(1)
finally:
    os.close(fd)
EOF
    done
    info "注: LMCache fdp_stream_number = GET_MAX − 2 (GET_MAX=16 时为 14)"

    step "RDMA HCA"
    n_active=$(ibstat 2>/dev/null | grep -c "State:.*Active" || true)
    if [[ ${n_active} -ge 1 ]]; then
        info "活动 IB 端口数: ${n_active} — OK (跨节点带宽请另行用 ib_write_bw 验证)"
    else
        fail "无活动 IB 端口"
    fi
fi

if [[ "${ROLE}" == "meta" ]]; then
    step "FoundationDB (dskna004)"
    if command -v fdbcli >/dev/null; then
        info "fdbcli: $(fdbcli --version 2>&1 | head -1)"
    else
        fail "fdbcli 不在 PATH"
    fi
    if ldconfig -p 2>/dev/null | grep -q libfdb_c; then
        info "libfdb_c 客户端库存在"
    else
        fail "libfdb_c 不存在 (client/server 版本必须匹配)"
    fi

    step "ClickHouse (已安装, 只探测不启停)"
    if clickhouse-client --password "${CH_PASSWD}" -q "SELECT 1" >/dev/null 2>&1; then
        info "ClickHouse 可连接 (user=default)"
    else
        fail "ClickHouse 不可连接 (确认 clickhouse-server 已由你方启动)"
    fi

    step "到 3 台存储节点的 ssh 可达性 (02 需要推送 fdb.cluster)"
    SSH_USER="${SSH_USER:-root}"
    for ip in "${STORAGE_HOSTS[@]}"; do
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "${SSH_USER}@${ip}" true 2>/dev/null; then
            info "ssh ${SSH_USER}@${ip} — OK"
        else
            fail "ssh ${SSH_USER}@${ip} 不可达 (02 推送会失败; 非 root 登录请: SSH_USER=xxx sudo bash 02_...)"
        fi
    done
fi

summary_exit
