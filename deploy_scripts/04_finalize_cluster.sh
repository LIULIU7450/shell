#!/bin/bash
# 04_finalize_cluster.sh — 集群收尾: 用户/targets/链/FUSE/冒烟验证 (dskna004)
# 前置: 01 (4台) → 02 (dskna004) → 03 (3台存储节点) 全部完成
# 执行 (仅 dskna004):  sudo bash 04_finalize_cluster.sh
# 对应官方 deploy/README.md Step 7–8 + 部署后验证
#
# 与旧版的关键差异 (修复点):
#   1. root 用户的 token 必须由服务端生成: user-add 传 --token 会走 ensureTokenMatchUid(),
#      随机串必然不匹配 (Token 与 uid 是编码绑定的)。改为不带 --token, 从输出表解析后落盘。
#   2. create-target / upload-chains 已存在时不再致命 (幂等重跑)。
#   3. 冒烟测试不再依赖 O_DIRECT (FUSE 视配置可能不支持), 改用普通 dd + md5 比对。
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"
require_root
require_role meta
set -euo pipefail
FAIL_COUNT=0

# ---------- 1. 等待 3 个 storage 节点注册 ----------
step "1/7 等待 3 个 storage 节点注册 (最多 90s)"
ok=0
for i in $(seq 1 18); do
    out=$(admin_cli "list-nodes" 2>/dev/null || true)
    n=0
    for id in 10001 10002 10003; do grep -qE "^[[:space:]]*${id}[[:space:]]+STORAGE" <<<"${out}" && n=$((n + 1)); done
    if [[ ${n} -ge 3 ]]; then ok=1; break; fi
    info "已见 ${n}/3 个 storage 节点, 等待... (${i}/18)"
    sleep 5
done
[[ ${ok} -eq 1 ]] || { echo "${out:-}"; die "storage 节点未全部注册 — 检查各存储节点: systemctl status storage_main"; }
echo "${out}"
info "3 个 storage 节点已注册"

# ---------- 2. root 用户 (token 由服务端生成并落盘) ----------
step "2/7 创建 root 用户 / 复用已有 token"
token_ok=0
if [[ -f "${TOKEN_FILE}" ]] && admin_cli_token "current-user" >/dev/null 2>&1; then
    token_ok=1
    info "token 文件有效, 跳过 user-add"
fi
if [[ ${token_ok} -eq 0 ]]; then
    [[ -f "${TOKEN_FILE}" ]] && warn "token 文件存在但鉴权失败, 重新创建用户"
    out=$(admin_cli "user-add --root --admin 0 root" 2>&1) || {
        echo "${out}"
        die "user-add 失败。若提示 kExists, 说明用户已存在但 token 丢失: 清空 FDB 重新部署 (02 --reset-fdb) 或手工处理"
    }
    echo "${out}"
    # 输出表: "Token              <token>(Expired at N/A)"
    token=$(awk '/^Token/ {print $2}' <<<"${out}" | sed 's/(Expired.*//')
    [[ -n "${token}" ]] || die "无法从 user-add 输出解析 token"
    umask 077
    printf '%s' "${token}" > "${TOKEN_FILE}"
    chmod 600 "${TOKEN_FILE}"
    admin_cli_token "current-user" >/dev/null 2>&1 || die "新 token 鉴权失败"
    info "token 已保存到 ${TOKEN_FILE} (权限 600)"
fi

# ---------- 3. 6 个 storage targets (每盘 1 个, 新 chunk engine) ----------
step "3/7 创建 6 个 storage targets"
# disk-index 0 → /storage/data3 (nvme3n1); disk-index 1 → /storage/data4 (nvme4n1)
# 结构: 链 900100001 = data3@10001/10002/10003; 链 900200001 = data4@10001/10002/10003
while read -r cmd; do
    [[ -z "${cmd}" ]] && continue
    if out=$(admin_cli_token "${cmd}" 2>&1); then
        info "$(echo "${out}" | grep -i succeed | head -1)"
    else
        if grep -qiE "exist|kExists|already" <<<"${out}"; then
            warn "target 已存在, 跳过: ${cmd##*--target-id }"
        else
            echo "${out}"
            die "create-target 失败: ${cmd}"
        fi
    fi
done <<'EOF'
create-target --node-id 10001 --disk-index 0 --target-id 101000100101 --chain-id 900100001  --use-new-chunk-engine
create-target --node-id 10002 --disk-index 0 --target-id 101000200101 --chain-id 900100001  --use-new-chunk-engine
create-target --node-id 10003 --disk-index 0 --target-id 101000300101 --chain-id 900100001  --use-new-chunk-engine
create-target --node-id 10001 --disk-index 1 --target-id 101000100201 --chain-id 900200001  --use-new-chunk-engine
create-target --node-id 10002 --disk-index 1 --target-id 101000200201 --chain-id 900200001  --use-new-chunk-engine
create-target --node-id 10003 --disk-index 1 --target-id 101000300201 --chain-id 900200001  --use-new-chunk-engine
EOF
admin_cli_token "list-targets" || true

# 拓扑一致性: target_paths 项数 vs 已建 target 覆盖的 disk-index 范围
# （扩到 3 盘/9 target 时, 需按 README 附录 B 手工建满, 本脚本只建 2 盘/6 target）
n_paths=${#STORAGE_DATA_DIRS[@]}
max_disk=$(admin_cli_token "list-targets" 2>/dev/null | awk 'NR>1 && $7 ~ /^[0-9]+$/ {print $7}' | sort -n | tail -1)
if [[ -n "${max_disk}" && $((max_disk + 1)) -ne ${n_paths} ]]; then
    warn "target_paths=${n_paths} 项, 但 target 仅覆盖 disk-index 0..${max_disk};"
    warn "3 盘拓扑请参考 README 附录 B 手工补齐 target / 链 / 链表"
fi

# ---------- 4. 链与链表 ----------
step "4/7 上传链与链表"
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
admin_cli_token "upload-chains ${OPT_ETC}/generated_chains.csv" || warn "upload-chains 返回错误 (重复上传时正常)"
admin_cli_token "upload-chain-table --desc ${CLUSTER_ID} 1 ${OPT_ETC}/generated_chain_table.csv" \
    || warn "upload-chain-table 返回错误 (重复上传时正常)"
admin_cli_token "list-chains"
admin_cli_token "list-chain-tables"

# ---------- 5. 等 meta / storage 心跳正常 + 6 个 target SERVING ----------
# 注意: 本版本 NodeStatus 只有 PRIMARY_MGMTD / HEARTBEAT_CONNECTED 等, 没有 SERVING;
# meta/storage 的"健康态"就是 HEARTBEAT_CONNECTED, target/链的 SERVING 另查 list-targets。
step "5/7 等待 meta + 3 storage 心跳正常 + 6 targets SERVING"
ok=0
for i in $(seq 1 18); do
    out=$(admin_cli "list-nodes" 2>/dev/null || true)
    n=0
    for id in 100 10001 10002 10003; do
        grep -qE "^[[:space:]]*${id}[[:space:]]+[A-Z]+[[:space:]]+HEARTBEAT_CONNECTED" <<<"${out}" && n=$((n + 1))
    done
    tl=$(admin_cli_token "list-targets" 2>/dev/null | grep -c "SERVING" || true)
    if [[ ${n} -ge 4 && ${tl} -ge 6 ]]; then ok=1; break; fi
    info "心跳正常节点 ${n}/4, SERVING target ${tl}/6, 等待... (${i}/18)"
    sleep 5
done
echo "${out:-}"
if [[ ${ok} -eq 1 ]]; then
    info "meta + 3 storage 心跳正常, 6 个 target 全部 SERVING"
else
    warn "仍有节点/target 未就绪 — 见 list-nodes 与 list-targets 输出"
fi

# ---------- 6. FUSE 客户端 (README Step 8) ----------
step "6/7 FUSE 客户端 + 挂载 ${MOUNT_POINT}"
check_exists "${BIN_DIR}/hf3fs_fuse_main" || die "缺少二进制 ${BIN_DIR}/hf3fs_fuse_main"
install_bin "${BIN_DIR}/hf3fs_fuse_main" "${OPT_BIN}/hf3fs_fuse_main"
check_exists "${TOKEN_FILE}" || die "${TOKEN_FILE} 不存在"
render_fuse_launcher_cfg "${OPT_ETC}/hf3fs_fuse_main_launcher.toml" "${IB_DEVICE_FILTER_META}"
render_fuse_cfg "${OPT_ETC}/hf3fs_fuse_main.toml"
admin_cli "set-config --type FUSE --file ${OPT_ETC}/hf3fs_fuse_main.toml"
mkdir -p "${MOUNT_POINT}"
install_unit hf3fs_fuse_main.service
systemctl enable hf3fs_fuse_main >/dev/null 2>&1
systemctl restart hf3fs_fuse_main
ok=0
for i in $(seq 1 12); do
    sleep 3
    systemctl is-active hf3fs_fuse_main >/dev/null || { journalctl -u hf3fs_fuse_main -n 40 --no-pager; die "hf3fs_fuse_main 启动失败"; }
    if mountpoint -q "${MOUNT_POINT}"; then ok=1; break; fi
done
[[ ${ok} -eq 1 ]] || { journalctl -u hf3fs_fuse_main -n 40 --no-pager; die "未挂载 ${MOUNT_POINT}"; }
mount | grep "${MOUNT_POINT}"
info "已挂载: ${MOUNT_POINT}"

# ---------- 7. 冒烟验证 ----------
step "7/7 冒烟验证 (读写 / FUSE FDP ioctl / 监控链路)"
set +e
mkdir -p "${MOUNT_POINT}/test"
f1="${MOUNT_POINT}/test/smoke_$$"
if dd if=/dev/urandom of="${f1}" bs=1M count=512 status=none; then
    sync
    m1=$(md5sum "${f1}" | awk '{print $1}')
    if dd if="${f1}" of=/tmp/smoke.copy bs=1M status=none; then
        m2=$(md5sum /tmp/smoke.copy | awk '{print $1}')
        if [[ -n "${m1}" && "${m1}" == "${m2}" ]]; then
            info "512MB 读写数据一致 (md5=${m1})"
        else
            fail "读写 md5 不一致 (${m1} vs ${m2})"
        fi
    else
        fail "读回失败"
    fi
    rm -f "${f1}" /tmp/smoke.copy
else
    fail "写入 ${f1} 失败"
fi

python3 - "${MOUNT_POINT}/test" <<'EOF' || FAIL_COUNT=$((FAIL_COUNT + 1))
import fcntl, os, struct, sys, time
# HF3FS_IOC_WRITE_STREAM = _IOWR('h', 16, Hf3fsFsWriteStream=4*uint32) = 0xC0106810
HF3FS_IOC_WRITE_STREAM = (3 << 30) | (16 << 16) | (0x68 << 8) | 16
OP_GET_MAX, OP_GET, OP_SET = 1, 2, 4
p = os.path.join(sys.argv[1], "fdp_probe")
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
try:
    mx = 0
    for _ in range(5):  # 刚建立的文件句柄偶发返回 0, 短暂重试
        ws = struct.pack("IIII", OP_GET_MAX, 0, 0, 0)
        op, sid, mx, _r = struct.unpack("IIII", fcntl.ioctl(fd, HF3FS_IOC_WRITE_STREAM, ws))
        if mx:
            break
        time.sleep(0.5)
    print(f"  [INFO] FUSE ioctl GET_MAX = {mx}")
    assert mx >= 3, f"FDP ioctl 透传异常 (GET_MAX={mx})"

    # SET 3 → GET 应返回 3, 验证 ioctl 在 FUSE 侧真正落到文件句柄
    fcntl.ioctl(fd, HF3FS_IOC_WRITE_STREAM, struct.pack("IIII", OP_SET, 3, 0, 0))
    _o, sid, _m, _r = struct.unpack("IIII", fcntl.ioctl(fd, HF3FS_IOC_WRITE_STREAM,
                                                        struct.pack("IIII", OP_GET, 0, 0, 0)))
    print(f"  [INFO] FUSE ioctl SET 3 → GET = {sid}")
    assert sid == 3, f"SET/GET stream 不一致 ({sid})"
finally:
    os.close(fd)
    try: os.unlink(p)
    except OSError: pass
EOF

sleep 3
n=$(clickhouse-client --password "${CH_PASSWD}" -q "SELECT count() FROM \`3fs\`.counters" 2>/dev/null || echo 0)
[[ "${n:-0}" -gt 0 ]] && info "ClickHouse counters 行数 = ${n} — 监控链路 OK" \
                      || warn "counters 为空 (稍后复查: journalctl -u monitor_collector_main)"

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
