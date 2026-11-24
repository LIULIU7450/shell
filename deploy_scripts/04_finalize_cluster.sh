#!/bin/bash
# 04_finalize_cluster.sh — 集群收尾: 用户/targets/链/FUSE/冒烟验证 (dskna004)
# 前置: 01 (4台) → 02 (dskna004) → 03 (3台存储节点) 全部完成
# 执行 (仅 dskna004):  sudo bash 04_finalize_cluster.sh
# 对应指南 §9–§11.1, §11.2 层2。
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"
require_root
require_role meta
set -euo pipefail

# ---------- 1. 等待 3 个 storage 节点 SERVING ----------
step "1/6 等待 3 个 storage 节点注册 (最多等 60s)"
ok=0
for i in $(seq 1 12); do
    out=$(admin_cli "list-nodes" 2>/dev/null || true)
    n=$(echo "${out}" | grep -c "10001\|10002\|10003" || true)
    if [[ ${n} -ge 3 ]]; then ok=1; echo "${out}"; break; fi
    info "已见 ${n}/3 个 storage 节点, 等待... (${i}/12)"
    sleep 5
done
[[ ${ok} -eq 1 ]] || { echo "${out:-}"; die "storage 节点未全部注册 — 检查各存储节点: systemctl status storage_main"; }

# ---------- 2. root 用户 (token 预置) ----------
step "2/6 创建 root 用户"
if [[ -f "${TOKEN_FILE}" ]]; then
    info "token 文件已存在, 跳过 user-add"
else
    TOKEN=$(openssl rand -hex 16 2>/dev/null || echo "3fs-fdp-$(date +%s)-token")
    admin_cli "user-add --root --admin --token ${TOKEN} 0 root"
    umask 077
    echo -n "${TOKEN}" > "${TOKEN_FILE}"
    info "token 已保存到 ${TOKEN_FILE} (权限 600)"
fi

# ---------- 3. 6 个 storage targets (每盘 1 个, 新 chunk engine) ----------
step "3/6 创建 6 个 storage targets"
# disk-index 0 → /storage/data3 (nvme3n1); disk-index 1 → /storage/data4 (nvme4n1)
# 结构: 链 900100001 = data3@10001/10002/10003; 链 900200001 = data4@10001/10002/10003
while read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    admin_cli_token "${cmd}"
done <<'EOF'
create-target --node-id 10001 --disk-index 0 --target-id 101000100101 --chain-id 900100001  --use-new-chunk-engine
create-target --node-id 10002 --disk-index 0 --target-id 101000200101 --chain-id 900100001  --use-new-chunk-engine
create-target --node-id 10003 --disk-index 0 --target-id 101000300101 --chain-id 900100001  --use-new-chunk-engine
create-target --node-id 10001 --disk-index 1 --target-id 101000100201 --chain-id 900200001  --use-new-chunk-engine
create-target --node-id 10002 --disk-index 1 --target-id 101000200201 --chain-id 900200001  --use-new-chunk-engine
create-target --node-id 10003 --disk-index 1 --target-id 101000300201 --chain-id 900200001  --use-new-chunk-engine
EOF

# ---------- 4. 链与链表 ----------
step "4/6 上传链与链表"
cat > "${OPT_ETC}/generated_chains.csv" <<'EOF'
ChainId,TargetId,TargetId,TargetId
900100001,101000100101,101000200101,101000300101
900200001,101000100201,101000200201,101000300201
EOF
cat > "${OPT_ETC}/generated_chain_table.csv" <<'EOF'
ChainId
900100001
900200001
EOF
admin_cli_token "upload-chains ${OPT_ETC}/generated_chains.csv"
admin_cli_token "upload-chain-table --desc ${CLUSTER_ID} 1 ${OPT_ETC}/generated_chain_table.csv"
admin_cli_token "list-chains"
admin_cli_token "list-chain-tables"
# mkdir 已存在时 admin_cli 会报错, 用 $? 区分 "已存在" 与其他失败
if admin_cli_token "mkdir --perm 0777 test" 2>/tmp/3fs_mkdir_err; then
    info "test/ 目录已创建 (perm 0777)"
else
    if grep -qi "exist" /tmp/3fs_mkdir_err; then
        info "test/ 目录已存在, 跳过"
    else
        warn "mkdir test 失败: $(cat /tmp/3fs_mkdir_err)"
    fi
fi
rm -f /tmp/3fs_mkdir_err

# ---------- 5. FUSE 客户端 (指南 §10) ----------
step "5/6 FUSE 客户端 + 挂载 ${MOUNT_POINT}"
check_exists "${BIN_DIR}/hf3fs_fuse_main" || die "缺少二进制"
install_bin "${BIN_DIR}/hf3fs_fuse_main" "${OPT_BIN}/hf3fs_fuse_main"
check_exists "${TOKEN_FILE}" || die "${TOKEN_FILE} 不存在"
cat > "${OPT_ETC}/hf3fs_fuse_main_launcher.toml" <<EOF
cluster_id = '${CLUSTER_ID}'
mountpoint = '${MOUNT_POINT}'
token_file = '${TOKEN_FILE}'

# dskna004: 8 活动 HCA > kMaxDeviceCnt(4), FUSE 启动即初始化 IB (hf3fs_fuse.cpp:44), 必须过滤
[ib_devices]
device_filter = ${IB_DEVICE_FILTER_META}

[mgmtd_client]
mgmtd_server_addresses = ["${MGMTD_ADDR}"]
EOF
cat > "${OPT_ETC}/hf3fs_fuse_main.toml" <<EOF
# fuse runtime config — 上传给 mgmtd (指南 §10)
# 注意: runtime config 无 ib_devices 键 (IB 由 FUSE launcher 初始化, hf3fs_fuse.cpp:44
# 读的是 launcher config), 不可在 runtime config 加 device_filter
[mgmtd]
mgmtd_server_addresses = ["${MGMTD_ADDR}"]

[[common.monitor.reporters]]
type = 'monitor_collector'

[common.monitor.reporters.monitor_collector]
remote_ip = '${MONITOR_ADDR}'
EOF
admin_cli "set-config --type FUSE --file ${OPT_ETC}/hf3fs_fuse_main.toml"
mkdir -p "${MOUNT_POINT}"
install_unit hf3fs_fuse_main.service
systemctl enable hf3fs_fuse_main >/dev/null 2>&1
systemctl restart hf3fs_fuse_main
sleep 5
systemctl is-active hf3fs_fuse_main || { journalctl -u hf3fs_fuse_main -n 30 --no-pager; exit 1; }
mount | grep "${MOUNT_POINT}" || die "未挂载"
info "已挂载: ${MOUNT_POINT}"

# ---------- 6. 冒烟验证 (指南 §11.1 + §11.2 层2) ----------
step "6/6 冒烟验证"
set +e
FAIL_COUNT=0
mkdir -p "${MOUNT_POINT}/test"
f1="${MOUNT_POINT}/test/smoke_$$"
dd if=/dev/urandom of="${f1}" bs=1M count=512 oflag=direct status=none \
    && m1=$(md5sum "${f1}" | awk '{print $1}') \
    && dd if="${f1}" of=/tmp/smoke.copy bs=1M iflag=direct status=none \
    && m2=$(md5sum /tmp/smoke.copy | awk '{print $1}') \
    && rm -f "${f1}" /tmp/smoke.copy
[[ "${m1:-}" == "${m2:-}" && -n "${m1:-}" ]] \
    && info "512MB 读写数据一致 (md5=${m1})" \
    || fail "读写冒烟失败"

python3 - "${MOUNT_POINT}/test" <<'EOF' || FAIL_COUNT=$((FAIL_COUNT + 1))
import fcntl, os, struct, sys
# HF3FS_IOC_WRITE_STREAM = _IOWR('h', 16, Hf3fsFsWriteStream=4*uint32) = 0xC0106810
HF3FS_IOC_WRITE_STREAM = (3 << 30) | (16 << 16) | (0x68 << 8) | 16
OP_GET_MAX = 1
p = os.path.join(sys.argv[1], "fdp_probe")
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
try:
    ws = struct.pack("IIII", OP_GET_MAX, 0, 0, 0)
    fcntl.ioctl(fd, HF3FS_IOC_WRITE_STREAM, ws)
    op, sid, mx, rsvd = struct.unpack("IIII", ws)
    print(f"  [INFO] FUSE ioctl GET_MAX = {mx} (期望 16)")
    assert mx >= 3, "FDP 透传异常"
finally:
    os.close(fd)
    try: os.unlink(p)
    except OSError: pass
EOF

sleep 3
n=$(clickhouse-client --password "${CH_PASSWD}" -q "SELECT count() FROM \`3fs\`.counters" 2>/dev/null || echo 0)
[[ "${n}" -gt 0 ]] && info "ClickHouse counters 行数 = ${n} — 监控链路 OK" \
                   || warn "counters 为空 (稍后复查, 或查 journalctl -u monitor_collector_main)"

echo ""
if [[ ${FAIL_COUNT} -gt 0 ]]; then
    echo "!!!!! 冒烟验证有 ${FAIL_COUNT} 项失败 !!!!!"
    exit 1
fi
echo "===== 集群部署完成 ====="
echo ""
echo "  WAF 实验流程 (3 台存储节点):"
echo "    sudo bash 03_setup_storage.sh verify snap    # 负载前基线"
echo "    ... 跑 LMCache KV offload 负载 ..."
echo "    sudo bash 03_setup_storage.sh verify check   # 负载后 PLID 差值 (PLID1=compaction, PLID2..=数据)"
echo "    WAF = DataUnitsWritten 差值 × 512KB ÷ host 写入量"
