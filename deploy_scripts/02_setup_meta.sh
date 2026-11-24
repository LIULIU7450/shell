#!/bin/bash
# 02_setup_meta.sh — dskna004 一体化部署 (meta 节点全部工作, 无中途暂停)
# 执行 (仅 dskna004):  sudo bash 02_setup_meta.sh
#       ssh 账户/密码在 common.sh 定义 (SSHPASS/SSH_USER 环境变量可覆盖)
#
# 内容 (对应指南 §3–§8):
#   ClickHouse 监控表 → monitor_collector → FoundationDB 初始化 → 推送 fdb.cluster
#   → admin_cli → mgmtd (init-cluster 1 1048576 16) → meta (set-config META)
#   → 上传 STORAGE 运行配置 (fdp_compaction_stream_id=2) —— 供存储节点启动时拉取
# 安全性: 只操作 3FS/FDB 自有服务; 不重启服务器; ClickHouse 只连接不启停; 幂等可重跑。
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "${SCRIPT_DIR}/common.sh"
require_root
require_role meta

# ---------- 1. ClickHouse 监控表 (指南 §3.2) ----------
step "1/9 ClickHouse 监控表"
clickhouse-client --password "${CH_PASSWD}" -q "SELECT 1" >/dev/null
clickhouse-client --password "${CH_PASSWD}" -n < "${SQL_DIR}/3fs-monitor.sql"
tables=$(clickhouse-client --password "${CH_PASSWD}" -q "SHOW TABLES FROM \`3fs\`")
[[ "${tables}" == *"counters"* && "${tables}" == *"distributions"* ]] || die "缺少 counters/distributions 表"
info "counters / distributions 就绪"

# ---------- 2. monitor_collector (指南 §3.3) ----------
step "2/9 monitor_collector"
mkdir -p "${OPT_BIN}" "${OPT_ETC}" "${LOG_DIR}"
check_exists "${BIN_DIR}/monitor_collector_main" || die "缺少二进制"
cp "${BIN_DIR}/monitor_collector_main" "${OPT_BIN}/"
cat > "${OPT_ETC}/monitor_collector_main.toml" <<EOF
# monitor_collector runtime config — 部署脚本生成 (指南 §3.3)
# dskna004 有 8 个活动 HCA > kMaxDeviceCnt(4), 必须 device_filter (IBDevice.h:119)
[common.ib_devices]
device_filter = ${IB_DEVICE_FILTER_META}

[server.monitor_collector.reporter]
type = 'clickhouse'

[server.monitor_collector.reporter.clickhouse]
db = '3fs'
host = '127.0.0.1'
passwd = '${CH_PASSWD}'
port = '9000'
user = 'default'
EOF
install_unit monitor_collector_main.service
systemctl enable monitor_collector_main >/dev/null 2>&1
systemctl restart monitor_collector_main
sleep 2
systemctl is-active monitor_collector_main || { journalctl -u monitor_collector_main -n 30 --no-pager; exit 1; }
info "monitor_collector 已运行 (监听 10000)"

# ---------- 3. FoundationDB (指南 §4, 幂等) ----------
step "3/9 FoundationDB"
if systemctl is-active foundationdb >/dev/null 2>&1 \
   && fdbcli --exec "status minimal" 2>/dev/null | grep -q "healthy"; then
    info "foundationdb 已运行且健康, 跳过初始化"
else
    if [[ -f /etc/foundationdb/foundationdb.conf ]] && grep -q "datadir = /var/lib/foundationdb/data" /etc/foundationdb/foundationdb.conf; then
        info "foundationdb.conf 已存在, 保留不动"
    else
        mkdir -p /var/lib/foundationdb/data /etc/foundationdb /var/log/foundationdb
        cat > /etc/foundationdb/foundationdb.conf <<'EOF'
## foundationdb.conf — 3FS 测试集群 (单节点 ssd), 部署脚本生成
[general]
restart-check-batches = 60
cluster-file = /etc/foundationdb/fdb.cluster

[fdbmonitor]

## Server parameters
[server]
public-address = auto
listen-address = public
datadir = /var/lib/foundationdb/data
logdir = /var/log/foundationdb
EOF
    fi
    systemctl enable foundationdb >/dev/null 2>&1
    systemctl start foundationdb
    sleep 5
    systemctl is-active foundationdb || { journalctl -u foundationdb -n 30 --no-pager; exit 1; }
    fdbcli --exec "configure new single ssd"
    sleep 3
fi
cp /etc/foundationdb/fdb.cluster "${FDB_CLUSTER_FILE}"
info "fdb.cluster: $(cat "${FDB_CLUSTER_FILE}")"

# ---------- 4. 推送 fdb.cluster 到存储节点 (指南 §5) ----------
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

# ---------- 5. admin_cli (指南 §5) ----------
step "5/9 admin_cli"
check_exists "${BIN_DIR}/admin_cli" || die "缺少二进制"
cp "${BIN_DIR}/admin_cli" "${OPT_BIN}/"
cat > "${OPT_ETC}/admin_cli.toml" <<EOF
# admin_cli config — 部署脚本生成 (指南 §5)
cluster_id = '${CLUSTER_ID}'

# dskna004: 8 活动 HCA > kMaxDeviceCnt(4), 必须过滤 (admin_cli.cc:106 IBManager::start)
# 存储节点: 设备数 ≤4, 空 filter 即可
[ib_devices]
device_filter = ${IB_DEVICE_FILTER_META:-[]}

[fdb]
clusterFile = '${FDB_CLUSTER_FILE}'
EOF
"${OPT_BIN}/admin_cli" -cfg "${OPT_ETC}/admin_cli.toml" help >/dev/null
info "admin_cli 就绪"

# ---------- 6. mgmtd + init-cluster (指南 §6) ----------
step "6/9 mgmtd"
check_exists "${BIN_DIR}/mgmtd_main" || die "缺少二进制"
cp "${BIN_DIR}/mgmtd_main" "${OPT_BIN}/"
cat > "${OPT_ETC}/mgmtd_main_app.toml" <<'EOF'
allow_empty_node_id = false
node_id = 1
EOF
cat > "${OPT_ETC}/mgmtd_main_launcher.toml" <<EOF
cluster_id = '${CLUSTER_ID}'

# launcher 进程也独立初始化 IB (ServerLauncher.h:41), 8 HCA 必须过滤
[ib_devices]
device_filter = ${IB_DEVICE_FILTER_META}

[fdb]
clusterFile = '${FDB_CLUSTER_FILE}'
EOF
cat > "${OPT_ETC}/mgmtd_main.toml" <<EOF
# mgmtd runtime config — init-cluster 时上传 (指南 §6)
[common.ib_devices]
device_filter = ${IB_DEVICE_FILTER_META}

[[common.monitor.reporters]]
type = 'monitor_collector'

[common.monitor.reporters.monitor_collector]
remote_ip = '${MONITOR_ADDR}'
EOF
MARKER="${OPT_ETC}/.cluster_inited"
if [[ -f "${MARKER}" ]]; then
    info "已初始化过, 跳过 init-cluster (重置集群见指南 §13.2)"
else
    admin_cli "init-cluster --mgmtd ${OPT_ETC}/mgmtd_main.toml 1 1048576 16"
    touch "${MARKER}"
    info "init-cluster 完成 (链表ID=1, chunk=1MB, strip=16)"
fi
install_unit mgmtd_main.service
systemctl enable mgmtd_main >/dev/null 2>&1
systemctl restart mgmtd_main
sleep 5
systemctl is-active mgmtd_main || { journalctl -u mgmtd_main -n 30 --no-pager; exit 1; }
admin_cli "list-nodes"

# ---------- 7. meta (指南 §7) ----------
step "7/9 meta"
check_exists "${BIN_DIR}/meta_main" || die "缺少二进制"
cp "${BIN_DIR}/meta_main" "${OPT_BIN}/"
cat > "${OPT_ETC}/meta_main_app.toml" <<'EOF'
allow_empty_node_id = false
node_id = 100
EOF
cat > "${OPT_ETC}/meta_main_launcher.toml" <<EOF
cluster_id = '${CLUSTER_ID}'

# launcher 进程也独立初始化 IB (ServerLauncher.h:41), 8 HCA 必须过滤
[ib_devices]
device_filter = ${IB_DEVICE_FILTER_META}

[mgmtd_client]
mgmtd_server_addresses = ["${MGMTD_ADDR}"]
EOF
cat > "${OPT_ETC}/meta_main.toml" <<EOF
# meta runtime config — 上传给 mgmtd (指南 §7)
[server.mgmtd_client]
mgmtd_server_addresses = ["${MGMTD_ADDR}"]

[common.ib_devices]
device_filter = ${IB_DEVICE_FILTER_META}

[[common.monitor.reporters]]
type = 'monitor_collector'

[common.monitor.reporters.monitor_collector]
remote_ip = '${MONITOR_ADDR}'

[server.fdb]
clusterFile = '${FDB_CLUSTER_FILE}'
EOF
admin_cli "set-config --type META --file ${OPT_ETC}/meta_main.toml"
install_unit meta_main.service
systemctl enable meta_main >/dev/null 2>&1
systemctl restart meta_main
sleep 5
systemctl is-active meta_main || { journalctl -u meta_main -n 30 --no-pager; exit 1; }
sleep 2
admin_cli "list-nodes" | grep -q "100" || die "list-nodes 未见 meta 节点 100"
info "meta (node 100) 已运行"

# ---------- 8. 上传 STORAGE 配置 (指南 §8) ----------
step "8/9 上传 STORAGE 运行配置 (fdp_compaction_stream_id=2)"
write_storage_main_toml "${OPT_ETC}/storage_main.toml"
admin_cli "set-config --type STORAGE --file ${OPT_ETC}/storage_main.toml"
info "已上传 — 存储节点现在可以启动并拉取配置"

# ---------- 9. 完成 ----------
step "9/9 完成"
info "dskna004 侧就绪: ClickHouse表 / monitor_collector / FDB / mgmtd / meta 均已运行"
info "下一步: 在 3 台存储节点 (dsksa304/305/348) 各自执行: sudo bash 03_setup_storage.sh"
