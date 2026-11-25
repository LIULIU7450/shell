#!/bin/bash
# 02_setup_meta.sh — dskna004 一体化部署 (meta 节点全部工作, 无中途暂停)
# 执行 (仅 dskna004):  sudo bash 02_setup_meta.sh
#                       sudo bash 02_setup_meta.sh --reset-fdb   # FDB 数据损坏/需重建时
#
# 内容 (对应官方 deploy/README.md Step 1–6):
#   ClickHouse 监控表 → monitor_collector → FoundationDB → 推送 fdb.cluster
#   → admin_cli → mgmtd (init-cluster 1 1048576 16) → meta (set-config META)
#   → 上传 STORAGE 运行配置 (fdp_compaction_stream_id=2) —— 供存储节点启动时拉取
#
# 与旧版的关键差异 (修复点):
#   1. FDB 判定不再用 "status json 可解析" 作为唯一硬闸门:
#      未 configure 的库 (7.3) 上 fdbcli 会阻塞数十秒返回空, 旧逻辑因此误判"损坏"并 FATAL,
#      而把 datadir 里的 coordination-*.fdq 当成损坏证据也是错的 (全新库启动即生成)。
#      现在: 先判 available → 不可用且未配置则直接 configure new → 再等可用。
#   2. init-cluster 幂等标记写入 FDB 本身 (哨兵键), FDB 被清空后会自动重新 init-cluster。
#   3. 所有运行时配置从官方 configs/*.toml 模板派生 (含 [[server.base.groups]] 等服务组定义,
#      手写极简配置会因 groups 为空在 Server::groups().front() 处崩溃)。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"
require_root
require_role meta

RESET_FDB=0
for arg in "$@"; do
    case "${arg}" in
        --reset-fdb) RESET_FDB=1 ;;
        -h|--help)   echo "用法: $0 [--reset-fdb]"; exit 0 ;;
        *)           die "未知参数: ${arg} (可用: --reset-fdb)" ;;
    esac
done

FDB_MARK_KEY="deploy_3fs_init_marker"
FDB_MARK_VAL="${CLUSTER_ID}:${INIT_CHAIN_TABLE_ID}:${INIT_CHUNK_SIZE}:${INIT_STRIP_SIZE}"

# ---------- 1. ClickHouse 监控表 (README Step 1) ----------
step "1/9 ClickHouse 监控表"
clickhouse-client --password "${CH_PASSWD}" -q "SELECT 1" >/dev/null || die "ClickHouse 不可连接 (确认 clickhouse-server 已启动, 密码 ${CH_PASSWD})"
clickhouse-client --password "${CH_PASSWD}" -n < "${SQL_DIR}/3fs-monitor.sql"
tables=$(clickhouse-client --password "${CH_PASSWD}" -q "SHOW TABLES FROM \`3fs\`")
[[ "${tables}" == *"counters"* && "${tables}" == *"distributions"* ]] || die "缺少 counters/distributions 表"
info "counters / distributions 就绪"

# ClickHouse 26.x 的 network_compression_method 默认 ZSTD, 而 3FS 内置 clickhouse-cpp
# 只实现了 LZ4 解压, 会报 "unsupported compression method 144"; monitor 的 INSERT 全部失败。
# 只改 default profile 的网络压缩 (配置 + SYSTEM RELOAD USERS, 不重启 clickhouse-server)。
ch_comp=$(clickhouse-client --password "${CH_PASSWD}" -q \
    "SELECT value FROM system.settings WHERE name='network_compression_method'" 2>/dev/null || echo "")
if [[ "${ch_comp,,}" != "lz4" ]]; then
    mkdir -p /etc/clickhouse-server/users.d
    cat > /etc/clickhouse-server/users.d/zz-3fs-lz4.xml <<'EOF'
<?xml version="1.0"?>
<!-- 3FS monitor_collector 内置 clickhouse-cpp 仅支持 LZ4 压缩;
     ClickHouse 26.x 默认 network_compression_method=ZSTD 会导致 INSERT 报
     "unsupported compression method 144"。仅对 default profile 降为 LZ4
     (改配置 + SYSTEM RELOAD USERS, 不重启 clickhouse-server)。 -->
<clickhouse>
    <profiles>
        <default>
            <network_compression_method>lz4</network_compression_method>
        </default>
    </profiles>
</clickhouse>
EOF
    chmod 644 /etc/clickhouse-server/users.d/zz-3fs-lz4.xml
    clickhouse-client --password "${CH_PASSWD}" -q "SYSTEM RELOAD USERS" || warn "SYSTEM RELOAD USERS 失败"
    info "已将 ClickHouse 网络压缩改为 LZ4 (原值 '${ch_comp:-unknown}')"
else
    info "ClickHouse 网络压缩已是 LZ4"
fi

# 回读确认（配置写了但未生效是最常见的坑）
ch_after=$(clickhouse-client --password "${CH_PASSWD}" -q \
    "SELECT value FROM system.settings WHERE name='network_compression_method'" 2>/dev/null || echo "")
if [[ "${ch_after,,}" == "lz4" ]]; then
    info "已确认 ClickHouse network_compression_method = lz4"
else
    warn "ClickHouse 网络压缩仍为 '${ch_after:-unknown}' — monitor 写入可能报 method 144"
fi

# ---------- 2. monitor_collector (README Step 2) ----------
step "2/9 monitor_collector"
mkdir -p "${OPT_BIN}" "${OPT_ETC}" "${LOG_DIR}"
check_exists "${BIN_DIR}/monitor_collector_main" || die "缺少二进制 ${BIN_DIR}/monitor_collector_main"
install_bin "${BIN_DIR}/monitor_collector_main" "${OPT_BIN}/monitor_collector_main"
render_monitor_cfg "${OPT_ETC}/monitor_collector_main.toml"
install_unit monitor_collector_main.service
systemctl enable monitor_collector_main >/dev/null 2>&1
systemctl restart monitor_collector_main
sleep 2
systemctl is-active monitor_collector_main >/dev/null || { journalctl -u monitor_collector_main -n 30 --no-pager; die "monitor_collector 启动失败"; }
ss -ltn 2>/dev/null | grep -q ":10000" || warn "monitor_collector 未监听 10000, 请查 journalctl -u monitor_collector_main"
info "monitor_collector 已运行 (监听 10000)"

# ---------- 3. FoundationDB (README 依赖第 1 条, 幂等 + 自愈) ----------
step "3/9 FoundationDB"

fdb_status_json() {  # 成功则 FDB_JSON 为可解析 JSON
    local out
    out=$(timeout 25 fdbcli --exec "status json" 2>/dev/null || true)
    FDB_JSON=$(python3 -c '
import sys
s = sys.stdin.read()
i, j = s.find("{"), s.rfind("}")
print(s[i:j+1] if i >= 0 and j > i else "")
' <<<"${out}")
    [[ -n "${FDB_JSON}" ]] || return 1
    python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"${FDB_JSON}" 2>/dev/null
}
fdb_json_field() {  # $1 = python 表达式, d = 解析后的 dict
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(bool($1))" <<<"${FDB_JSON}" 2>/dev/null
}
fdb_available() {
    fdb_status_json || return 1
    [[ "$(fdb_json_field 'd.get("client",{}).get("database_status",{}).get("available") or d.get("cluster",{}).get("database_available")')" == "True" ]]
}
# 7.3 用 cluster.configuration, 7.1/7.2 用 cluster.database_configuration
fdb_configured() {
    fdb_status_json || return 1
    [[ "$(fdb_json_field 'd.get("cluster",{}).get("configuration") or d.get("cluster",{}).get("database_configuration")')" == "True" ]]
}
fdb_wait_available() {  # $1 = 重试次数 (每次 5s)
    local n="${1:-12}" i
    for ((i = 1; i <= n; i++)); do
        fdb_available && return 0
        sleep 5
    done
    return 1
}
fdb_diagnose() {
    local trace
    trace=$(ls -t /var/log/foundationdb/trace.*.xml 2>/dev/null | head -1)
    [[ -n "${trace}" ]] && {
        echo "  ---- FDB 最近 trace 中的恢复状态 ----"
        grep -o 'Type="MasterRecoveryState"[^/]*' "${trace}" | tail -1 | cut -c1-220 || true
        grep -o 'Severity="4[0-9]"[^/]*Type="[^"]*"' "${trace}" | tail -5 | cut -c1-220 || true
    }
    echo "  ---- journalctl ----"
    journalctl -u foundationdb -n 15 --no-pager 2>/dev/null | tail -15 || true
    return 0
}

if [[ ${RESET_FDB} -eq 1 ]]; then
    warn "已指定 --reset-fdb: 将清空 FoundationDB 数据 (只影响 FDB 自身, 3FS 集群需重新 init-cluster)"
    systemctl stop foundationdb || true
    for _ in $(seq 1 15); do pgrep -x fdbserver >/dev/null || break; sleep 1; done
    pgrep -x fdbserver >/dev/null && die "fdbserver 未能停止, 请手工确认"
    bak="/var/lib/foundationdb/data.bak.$(date +%Y%m%d_%H%M%S)"
    [[ -d /var/lib/foundationdb/data ]] && mv /var/lib/foundationdb/data "${bak}" && info "旧数据已备份到 ${bak}"
    mkdir -p /var/lib/foundationdb/data
    chown foundationdb:foundationdb /var/lib/foundationdb/data
    chmod 700 /var/lib/foundationdb/data
    rm -f /etc/foundationdb/fdb.cluster
    printf '3fsfdp:%s@127.0.0.1:4500\n' "$(openssl rand -hex 4)" > /etc/foundationdb/fdb.cluster
    chmod 644 /etc/foundationdb/fdb.cluster
    info "已生成新的 fdb.cluster: $(cat /etc/foundationdb/fdb.cluster)"
    warn "FDB 被重置 ⇒ 3FS 集群状态丢失; 部署完成后如存储节点报 target 冲突, 清空 /storage/data{3,4}/3fs/* 后重跑 03"
fi

mkdir -p /var/lib/foundationdb/data /etc/foundationdb /var/log/foundationdb
if [[ ! -f /etc/foundationdb/foundationdb.conf ]]; then
    cat > /etc/foundationdb/foundationdb.conf <<'EOF'
## foundationdb.conf — 3FS 测试集群 (单节点 ssd), 部署脚本生成
[fdbmonitor]
user = foundationdb
group = foundationdb

[general]
restart-delay = 60
cluster-file = /etc/foundationdb/fdb.cluster

[fdbserver]
command = /usr/sbin/fdbserver
public-address = auto:$ID
listen-address = public
datadir = /var/lib/foundationdb/data/$ID
logdir = /var/log/foundationdb

[fdbserver.4500]

[backup_agent]
command = /usr/lib/foundationdb/backup_agent/backup_agent
logdir = /var/log/foundationdb

[backup_agent.1]
EOF
    info "已写入 /etc/foundationdb/foundationdb.conf"
else
    info "foundationdb.conf 已存在, 保留不动"
fi
[[ -f /etc/foundationdb/fdb.cluster ]] || {
    printf '3fsfdp:%s@127.0.0.1:4500\n' "$(openssl rand -hex 4)" > /etc/foundationdb/fdb.cluster
    warn "缺少 /etc/foundationdb/fdb.cluster, 已新建: $(cat /etc/foundationdb/fdb.cluster)"
}

systemctl enable foundationdb >/dev/null 2>&1 || true
systemctl is-active foundationdb >/dev/null 2>&1 || systemctl start foundationdb
sleep 3
systemctl is-active foundationdb >/dev/null || { fdb_diagnose; die "foundationdb 服务未运行"; }
# fdbmonitor "active" 不代表 fdbserver 活着 (数据损坏时 fdbserver 会无限 crash 循环)
for _ in $(seq 1 10); do pgrep -x fdbserver >/dev/null && break; sleep 1; done
pgrep -x fdbserver >/dev/null || { fdb_diagnose; die "fdbserver 进程不存在 (多为数据目录损坏); 可执行: sudo bash $0 --reset-fdb"; }

# 客户端/服务端版本一致性 (README 依赖: 必须匹配)
srv_ver=$(dpkg-query -W -f='${Version}' foundationdb-server 2>/dev/null || echo unknown)
cli_lib=$(ldconfig -p 2>/dev/null | awk '/libfdb_c\.so /{print $NF; exit}')
info "FDB server=${srv_ver} client_lib=${cli_lib:-未找到}"
[[ -n "${cli_lib}" ]] || die "缺少 libfdb_c.so (apt install foundationdb-clients)"

# 未配置的新库: fdbcli 会阻塞到超时, 必须先 configure 才谈得上 status
if ! fdb_configured; then
    info "FDB 未配置 (新库/数据被清空) — 执行 configure new single ssd"
    timeout 60 fdbcli --exec "configure new single ssd" 2>&1 | tail -3 || true
fi
if ! fdb_wait_available 12; then
    fdb_diagnose
    die "FDB ~60s 内不可用。若为数据目录损坏: sudo bash $0 --reset-fdb 后重跑本脚本"
fi
fdb_available && info "FDB 数据库可用 (configured=$(fdb_configured && echo yes || echo no))" || true

cp /etc/foundationdb/fdb.cluster "${FDB_CLUSTER_FILE}"
info "fdb.cluster: $(cat "${FDB_CLUSTER_FILE}")"

# ---------- 4. 推送 fdb.cluster 到存储节点 (README Step 3) ----------
step "4/9 推送 fdb.cluster → 3 台存储节点"
command -v sshpass >/dev/null || die "缺少 sshpass (apt install sshpass)"
[[ "${SSH_USER}" == "root" ]] && REMOTE_SUDO="" || REMOTE_SUDO="sudo"
for ip in "${STORAGE_HOSTS[@]}"; do
    scp_push "${FDB_CLUSTER_FILE}" "${ip}" "/tmp/fdb.cluster" \
        || die "scp 到 ${ip} 失败 (检查 sshpass/密码/网络)"
    ssh_exec "${ip}" "${REMOTE_SUDO} mkdir -p ${OPT_ETC} && ${REMOTE_SUDO} install -m 644 /tmp/fdb.cluster ${FDB_CLUSTER_FILE} && rm -f /tmp/fdb.cluster" \
        || die "ssh ${ip} 远端安装 fdb.cluster 失败"
    info "${ip} — OK"
done

# ---------- 5. admin_cli (README Step 3) ----------
step "5/9 admin_cli"
check_exists "${BIN_DIR}/admin_cli" || die "缺少二进制 ${BIN_DIR}/admin_cli"
install_bin "${BIN_DIR}/admin_cli" "${OPT_BIN}/admin_cli"
render_admin_cli_cfg "${OPT_ETC}/admin_cli.toml" "${IB_DEVICE_FILTER_META}"
"${OPT_BIN}/admin_cli" -cfg "${OPT_ETC}/admin_cli.toml" help >/dev/null || die "admin_cli 自检失败"
info "admin_cli 就绪 (IB 过滤 ${IB_DEVICE_FILTER_META})"

# ---------- 6. mgmtd + init-cluster (README Step 4) ----------
step "6/9 mgmtd"
check_exists "${BIN_DIR}/mgmtd_main" || die "缺少二进制 ${BIN_DIR}/mgmtd_main"
install_bin "${BIN_DIR}/mgmtd_main" "${OPT_BIN}/mgmtd_main"
render_app_cfg mgmtd 1 "${OPT_ETC}/mgmtd_main_app.toml"
render_mgmtd_launcher_cfg "${OPT_ETC}/mgmtd_main_launcher.toml" "${IB_DEVICE_FILTER_META}"
render_mgmtd_cfg "${OPT_ETC}/mgmtd_main.toml"

# init-cluster 幂等判定: 哨兵键存在且值匹配 → 已初始化
fdb_marker_ok() {
    local out
    out=$(timeout 15 fdbcli --exec "get ${FDB_MARK_KEY}" 2>/dev/null | tr -d '\r' || true)
    [[ "${out}" == *"${FDB_MARK_VAL}"* ]]
}
if fdb_marker_ok; then
    info "FDB 中已有 init-cluster 标记 (${FDB_MARK_VAL}), 跳过 init-cluster"
else
    info "未发现 init-cluster 标记 — 执行 init-cluster ${INIT_CHAIN_TABLE_ID} ${INIT_CHUNK_SIZE} ${INIT_STRIP_SIZE}"
    admin_cli "init-cluster --mgmtd ${OPT_ETC}/mgmtd_main.toml ${INIT_CHAIN_TABLE_ID} ${INIT_CHUNK_SIZE} ${INIT_STRIP_SIZE}" \
        || die "init-cluster 失败 (多因 mgmtd_main.toml 有误; 改该文件需清 FDB 重来)"
    timeout 20 fdbcli --exec "writemode on; set ${FDB_MARK_KEY} ${FDB_MARK_VAL}" >/dev/null 2>&1 \
        || warn "写 init-cluster 哨兵键失败 (不影响运行, 但下次会重跑 init-cluster)"
    info "init-cluster 完成"
fi

install_unit mgmtd_main.service
systemctl enable mgmtd_main >/dev/null 2>&1
systemctl restart mgmtd_main
ok=0
for i in $(seq 1 12); do
    sleep 3
    systemctl is-active mgmtd_main >/dev/null || { journalctl -u mgmtd_main -n 40 --no-pager; die "mgmtd 启动失败"; }
    if out=$(admin_cli "list-nodes" 2>/dev/null) && grep -qE "^[[:space:]]*1[[:space:]]+MGMTD" <<<"${out}"; then ok=1; break; fi
    info "等待 mgmtd (node 1) 注册... (${i}/12)"
done
[[ ${ok} -eq 1 ]] || { echo "${out:-}"; die "mgmtd 未在 list-nodes 中出现"; }
echo "${out}"
info "mgmtd (node 1) 已 SERVING"

# mgmtd 自身运行时配置存在 FDB 里 (init-cluster 上传的那份)。若本次渲染结果与 FDB
# 中已有的不同 (例如 monitor 地址修正/重跑), 用 set-config 覆盖并重启使其生效。
admin_cli "set-config --type MGMTD --file ${OPT_ETC}/mgmtd_main.toml" \
    || warn "上传 MGMTD 配置失败 (不影响当前运行)"
systemctl restart mgmtd_main
for i in $(seq 1 10); do
    sleep 2
    out=$(admin_cli "list-nodes" 2>/dev/null) && grep -qE "^[[:space:]]*1[[:space:]]+MGMTD" <<<"${out}" && break
done
grep -qE "^[[:space:]]*1[[:space:]]+MGMTD" <<<"${out:-}" || die "mgmtd 重启后未恢复 SERVING"
info "mgmtd 配置已同步 (monitor=${MONITOR_ADDR})"

# ---------- 7. meta (README Step 5) ----------
step "7/9 meta"
check_exists "${BIN_DIR}/meta_main" || die "缺少二进制 ${BIN_DIR}/meta_main"
install_bin "${BIN_DIR}/meta_main" "${OPT_BIN}/meta_main"
render_app_cfg meta 100 "${OPT_ETC}/meta_main_app.toml"
render_meta_launcher_cfg "${OPT_ETC}/meta_main_launcher.toml" "${IB_DEVICE_FILTER_META}"
render_meta_cfg "${OPT_ETC}/meta_main.toml"
admin_cli "set-config --type META --file ${OPT_ETC}/meta_main.toml"
install_unit meta_main.service
systemctl enable meta_main >/dev/null 2>&1
systemctl restart meta_main
ok=0
for i in $(seq 1 12); do
    sleep 3
    systemctl is-active meta_main >/dev/null || { journalctl -u meta_main -n 40 --no-pager; die "meta 启动失败"; }
    if out=$(admin_cli "list-nodes" 2>/dev/null) && grep -qE "^[[:space:]]*100[[:space:]]+META" <<<"${out}"; then ok=1; break; fi
    info "等待 meta (node 100) 注册... (${i}/12)"
done
[[ ${ok} -eq 1 ]] || { echo "${out:-}"; die "meta 未在 list-nodes 中出现"; }
info "meta (node 100) 已 SERVING"

# ---------- 8. 上传 STORAGE 运行配置 (README Step 6.5) ----------
step "8/9 上传 STORAGE 运行配置 (fdp_compaction_stream_id=${FDP_COMPACTION_STREAM_ID})"
render_storage_cfg "${OPT_ETC}/storage_main.toml"
admin_cli "set-config --type STORAGE --file ${OPT_ETC}/storage_main.toml" \
    || die "上传 STORAGE 配置失败"
info "已上传 — 存储节点现在可以启动并拉取配置"

# ---------- 9. 完成 ----------
step "9/9 完成"
info "dskna004 侧就绪: ClickHouse表 / monitor_collector / FDB / mgmtd / meta 均已运行"
info "下一步: 在 3 台存储节点 (dsksa304/305/348) 各自执行: sudo bash 03_setup_storage.sh"
