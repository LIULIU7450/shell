#!/bin/bash
# 03_setup_storage.sh — 存储节点一体化脚本 (dsksa304/305/348)
# 用法:
#   sudo bash 03_setup_storage.sh              # 部署模式: 调优 + admin_cli + storage 安装并启动
#   sudo bash 03_setup_storage.sh verify status|snap|check
#                                             # 运维模式: FDP 分流验证 / WAF 基线与对比
#
# 前置: dskna004 已执行 02_setup_meta.sh (fdb.cluster 已推送、STORAGE 配置已上传)
# 对应指南: §2, §5, §8 (部署) / §11.2 层1/层3, §12 (verify)
# 安全性: sysctl 在线生效; 只操作 3FS 自有服务; 不触碰 nvme2n1/ZFS/OS 盘; 幂等可重跑。
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"
require_root
detect_node
FAIL_COUNT=0

# ================= 运维模式: verify (对应旧 41) =================
do_verify() {
    local MODE="${1:-status}"
    local SNAP_DIR="/tmp/3fs_fdp_snap"
    local DEVS=(/dev/nvme3n1 /dev/nvme4n1)

    duw_of() {  # $1=设备 → Data Units Written (单位 512KB)
        nvme smart-log "$1" 2>/dev/null | awk -F: '/Data Units Written/ {gsub(/[ \t]/,"",$2); print $2}'
    }

    step "[FDP] chunk engine 日志 (compaction stream 解析结果)"
    if journalctl -u storage_main --no-pager 2>/dev/null | grep "\[FDP\]" | tail -5 | grep .; then
        :
    else
        warn "尚无 [FDP] 日志 — compaction 首次触发后才会出现 resolved/fell back 条目"
    fi

    case "${MODE}" in
    status)
        for d in "${DEVS[@]}"; do
            step "${d} 当前状态"
            nvme fdp status "${d}" -o json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
print('  [INFO] RUAMW:', ' '.join(f\"{e['pid']}={e['ruamw']}\" for e in d.get('ruhss', [])))
" || fail "nvme fdp status ${d} 失败"
            info "DataUnitsWritten: $(duw_of "${d}")"
        done
        ;;
    snap)
        mkdir -p "${SNAP_DIR}"
        local ts b
        ts=$(date +%Y%m%d_%H%M%S)
        for d in "${DEVS[@]}"; do
            b=$(basename "${d}")
            nvme fdp status "${d}" -o json > "${SNAP_DIR}/${b}.${ts}.json" 2>/dev/null
            echo "$(duw_of "${d}")" > "${SNAP_DIR}/${b}.${ts}.duw"
            ln -sfn "${SNAP_DIR}/${b}.${ts}.json" "${SNAP_DIR}/${b}.last.json"
            ln -sfn "${SNAP_DIR}/${b}.${ts}.duw" "${SNAP_DIR}/${b}.last.duw"
        done
        info "基线快照已保存 → ${SNAP_DIR}/*.${ts}.{{json,duw}} (last 链接指向最新)"
        ;;
    check)
        for d in "${DEVS[@]}"; do
            b=$(basename "${d}")
            step "${b} 与基线对比"
            if [[ ! -e "${SNAP_DIR}/${b}.last.json" ]]; then
                fail "无基线快照, 先执行: $0 verify snap"
                continue
            fi
            nvme fdp status "${d}" -o json > "${SNAP_DIR}/${b}.now.json" 2>/dev/null
            python3 - "${SNAP_DIR}/${b}.last.json" "${SNAP_DIR}/${b}.now.json" <<'EOF' || FAIL_COUNT=$((FAIL_COUNT + 1))
import json, sys
b = {e["pid"]: e["ruamw"] for e in json.load(open(sys.argv[1])).get("ruhss", [])}
a = {e["pid"]: e["ruamw"] for e in json.load(open(sys.argv[2])).get("ruhss", [])}
delta = {pid: b.get(pid, 0) - a.get(pid, 0) for pid in sorted(set(b) | set(a))}
total = sum(delta.values())
print("  [INFO] RUAMW 下降量 (≈ 各 PLID 写入量, 单位 4KB):")
for pid, dv in delta.items():
    if dv: print(f"    PLID {pid:2d}: {-dv:+,}  {'←←← 主要写入' if dv == max(delta.values()) and dv > 0 else ''}")
if max(delta.values()) == 0:
    print("  [WARN] 期间无可见写入")
else:
    top = max(delta, key=delta.get)
    share = delta[top] / total * 100 if total else 0
    print(f"  [INFO] 最大写入 PLID={top}, 占比 {share:.1f}%  (stream N → PLID N-1; PLID1=compaction, PLID2..=LMCache)")
EOF
            duw0=$(cat "${SNAP_DIR}/${b}.last.duw" 2>/dev/null)
            info "DataUnitsWritten: 基线=${duw0:-n/a} → 当前=$(duw_of "${d}") (差值×512KB = NAND 写入增量)"
        done
        ;;
    *)
        die "用法: $0 verify [status|snap|check]" ;;
    esac
    summary_exit
}

[[ "${1:-}" == "verify" ]] && { do_verify "${2:-status}"; exit $?; }
[[ $# -gt 0 ]] && die "用法: $0 [verify status|snap|check]  (无参数 = 部署模式)"

# ================= 部署模式 =================
require_role storage
set -euo pipefail

step "1/4 系统调优 + 数据目录 (指南 §2/§8.1)"
cat > /etc/sysctl.d/99-3fs.conf <<'EOF'
# 3FS storage: chunk engine 异步 IO 需要 (deploy/README.md Step 6)
fs.aio-max-nr = 67108864
EOF
sysctl -w fs.aio-max-nr=67108864 >/dev/null
[[ "$(sysctl -n fs.aio-max-nr)" == "67108864" ]] || die "sysctl fs.aio-max-nr 未生效"
info "fs.aio-max-nr = 67108864 (在线生效, 无需重启)"
for d in "${STORAGE_DATA_DIRS[@]}"; do
    mountpoint -q "${d%/3fs}" || die "${d%/3fs} 未挂载"
    info "${d%/3fs} ← $(findmnt -nrno SOURCE "${d%/3fs}")"
    mkdir -p "${d}"
done

step "2/4 admin_cli (指南 §5)"
mkdir -p "${OPT_BIN}" "${OPT_ETC}" "${LOG_DIR}"
check_exists "${FDB_CLUSTER_FILE}" || die "${FDB_CLUSTER_FILE} 不存在 — 请先在 dskna004 执行 02_setup_meta.sh"
check_exists "${BIN_DIR}/admin_cli" || die "缺少二进制 ${BIN_DIR}/admin_cli"
cp "${BIN_DIR}/admin_cli" "${OPT_BIN}/"
cat > "${OPT_ETC}/admin_cli.toml" <<EOF
cluster_id = '${CLUSTER_ID}'

[fdb]
clusterFile = '${FDB_CLUSTER_FILE}'
EOF
info "admin_cli 就绪 (node_id=${NODE_ID})"

step "3/4 storage 服务安装 (指南 §8)"
check_exists "${BIN_DIR}/storage_main" || die "缺少二进制 ${BIN_DIR}/storage_main"
cp "${BIN_DIR}/storage_main" "${OPT_BIN}/"
cat > "${OPT_ETC}/storage_main_app.toml" <<EOF
allow_empty_node_id = false
node_id = ${NODE_ID}
EOF
cat > "${OPT_ETC}/storage_main_launcher.toml" <<EOF
cluster_id = '${CLUSTER_ID}'

[mgmtd_client]
mgmtd_server_addresses = ["${MGMTD_ADDR}"]
EOF
write_storage_main_toml "${OPT_ETC}/storage_main.toml"
install_unit storage_main.service
info "配置写入完成 (runtime 配置以 mgmtd 下发的为准, 本地文件仅作参照/重上传用)"

step "4/4 启动 storage_main (STORAGE 配置已由 02 上传到 mgmtd)"
systemctl enable storage_main >/dev/null 2>&1
systemctl restart storage_main
sleep 5
systemctl is-active storage_main || { journalctl -u storage_main -n 40 --no-pager; exit 1; }
info "$(hostname) storage_main (node ${NODE_ID}) 已启动"

step "完成"
info "下一步: 3 台存储节点都跑完本脚本后, 回 dskna004 执行: sudo bash 04_finalize_cluster.sh"
info "日常 FDP/WAF 观测 (本机): sudo bash $0 verify status|snap|check"
