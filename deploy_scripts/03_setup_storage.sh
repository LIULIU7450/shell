#!/bin/bash
# 03_setup_storage.sh — 存储节点一体化脚本 (dsksa304/305/348)
# 用法:
#   sudo bash 03_setup_storage.sh              # 部署模式: 调优 + admin_cli + storage 安装并启动
#   sudo bash 03_setup_storage.sh verify status|snap|check
#                                              # 运维模式: FDP 分流验证 / WAF 基线与对比
#
# 前置: dskna004 已执行 02_setup_meta.sh (fdb.cluster 已推送、STORAGE 配置已上传)
# 对应官方 deploy/README.md Step 6 (§2 系统调优 / §6 存储服务)
# 安全性: sysctl 在线生效; 只操作 3FS 自有服务; 不触碰 nvme2n1/ZFS/OS 盘; 幂等可重跑。
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"
require_root
detect_node
FAIL_COUNT=0

# ================= 运维模式: verify =================
do_verify() {
    local MODE="${1:-status}"
    local SNAP_DIR="/tmp/3fs_fdp_snap"
    local DEVS=("${STORAGE_DEVS[@]}")

    duw_of() {  # $1=设备 → Data Units Written (单位 512KB)
        nvme smart-log "$1" 2>/dev/null | awk -F: '/Data Units Written/ {gsub(/[ \t]/,"",$2); print $2}'
    }
    getmax_of() {  # $1=挂载点 → XFS GET_MAX (真实值; 0 才表示设备未暴露写流)
        # 注意: python 的 bytes 不可变, fcntl.ioctl(...) 的结果必须用返回值,
        # 读入参 ws 永远是初始值 0 —— 这是最容易误判 "GET_MAX=0" 的坑。
        python3 - "$1" <<'PY'
import fcntl, os, struct, sys
FS_IOC_WRITE_STREAM = 0xC010662B
p = os.path.join(sys.argv[1], ".getmax_probe")
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
try:
    ret = fcntl.ioctl(fd, FS_IOC_WRITE_STREAM, struct.pack("IIII", 1, 0, 0, 0))
    print(struct.unpack("IIII", ret)[2])
finally:
    os.close(fd)
    os.unlink(p)
PY
    }
    streamwrites_of() {  # 内核态实际带 stream 的写命令计数 (FDP 数据面证据)
        dmesg 2>/dev/null | grep -o "write with stream [0-9]*" | awk '{print $4}' | sort -n | uniq -c \
            | awk '{printf "stream %s:%s次 ", $2, $1}'
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
print('  [INFO] nruhsd={} RUAMW: {}'.format(d.get('nruhsd'), ' '.join(f\"{e['pid']}={e['ruamw']}\" for e in d.get('ruhss', []))))
" || fail "nvme fdp status ${d} 失败"
            idx=$(basename "${d}" | sed 's/^nvme\([0-9]*\)n1$/\1/')
            mnt="/storage/data${idx}"
            info "XFS GET_MAX(${mnt}) = $(getmax_of "${mnt}" 2>/dev/null || echo err)  (= 硬件写流数 − 2; 0 才表示设备未暴露、回退默认放置)"
            info "DataUnitsWritten: $(duw_of "${d}")"
        done
        info "内核带 stream 写命令: $(streamwrites_of)"
        info "要证明 stream 真正落到 PLID, 抓 NVMe 命令的 dsmgmt (参见 README Step 9.3):"
        info "  echo 1 > /sys/kernel/tracing/events/nvme/nvme_setup_cmd/enable  → 写数据 → 关闭后 grep dsmgmt"
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
            duw1=$(duw_of "${d}")
            info "DataUnitsWritten: 基线=${duw0:-n/a} → 当前=${duw1} (差值×512KB = NAND 写入增量)"
            if [[ -n "${duw0}" && -n "${duw1}" && "${duw1}" -ge "${duw0}" ]]; then
                info "期间 NAND 写入增量 ≈ $(( (duw1 - duw0) / 2 )) MB"
            fi
        done
        info "内核带 stream 写命令(累计, dmesg): $(streamwrites_of)"
        info "提示: PM1763 的 RUAMW 是静态值 (不随写入变化), 物理放置请以 dmesg 'write with stream N'"
        info "      与 storage 日志 '[FDP_DEBUG] SERVER_WRITE: received streamId=N' 为准"
        ;;
    *)
        die "用法: $0 verify [status|snap|check]" ;;
    esac
    summary_exit
}

[[ "${1:-}" == "verify" ]] && { require_role storage; do_verify "${2:-status}"; exit $?; }
[[ $# -gt 0 ]] && die "用法: $0 [verify status|snap|check]  (无参数 = 部署模式)"

# ================= 部署模式 =================
require_role storage
set -euo pipefail

step "1/4 系统调优 + 数据目录 (README Step 6.1/6.2)"
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

step "2/4 admin_cli (README Step 3)"
mkdir -p "${OPT_BIN}" "${OPT_ETC}" "${LOG_DIR}"
check_exists "${FDB_CLUSTER_FILE}" || die "${FDB_CLUSTER_FILE} 不存在 — 请先在 dskna004 执行 02_setup_meta.sh"
check_exists "${BIN_DIR}/admin_cli" || die "缺少二进制 ${BIN_DIR}/admin_cli"
install_bin "${BIN_DIR}/admin_cli" "${OPT_BIN}/admin_cli"
render_admin_cli_cfg "${OPT_ETC}/admin_cli.toml" "${IB_DEVICE_FILTER_STORAGE}"
"${OPT_BIN}/admin_cli" -cfg "${OPT_ETC}/admin_cli.toml" help >/dev/null || die "admin_cli 自检失败"
info "admin_cli 就绪 (node_id=${NODE_ID}, mgmtd=${MGMTD_ADDR})"

step "3/4 storage 服务安装 (README Step 6.3/6.4)"
check_exists "${BIN_DIR}/storage_main" || die "缺少二进制 ${BIN_DIR}/storage_main"
install_bin "${BIN_DIR}/storage_main" "${OPT_BIN}/storage_main"
render_app_cfg storage "${NODE_ID}" "${OPT_ETC}/storage_main_app.toml"
render_storage_launcher_cfg "${OPT_ETC}/storage_main_launcher.toml" "${IB_DEVICE_FILTER_STORAGE}"
render_storage_cfg "${OPT_ETC}/storage_main.toml"
install_unit storage_main.service
info "配置写入完成 (runtime 配置以 mgmtd 下发的为准, 本地文件仅作参照/重上传用)"

step "4/4 启动 storage_main (STORAGE 配置已由 02 上传到 mgmtd)"
systemctl enable storage_main >/dev/null 2>&1
systemctl restart storage_main
ok=0
for i in $(seq 1 10); do
    sleep 3
    systemctl is-active storage_main >/dev/null || { journalctl -u storage_main -n 40 --no-pager; die "storage_main 启动失败"; }
    if journalctl -u storage_main --no-pager -n 200 2>/dev/null | grep -qE "start|Serving|register"; then ok=1; break; fi
done
info "$(hostname) storage_main (node ${NODE_ID}) 已启动"
grep -q "\[FDP\]" <(journalctl -u storage_main --no-pager -n 400 2>/dev/null) \
    && info "FDP 日志已出现: $(journalctl -u storage_main --no-pager -n 400 | grep '\[FDP\]' | tail -1)" \
    || info "FDP 日志在首次 compaction 后才出现 (正常)"

step "完成"
info "下一步: 3 台存储节点都跑完本脚本后, 回 dskna004 执行: sudo bash 04_finalize_cluster.sh"
info "日常 FDP/WAF 观测 (本机): sudo bash $0 verify status|snap|check"
