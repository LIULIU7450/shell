#!/bin/bash
# common.sh — 3FS FDP 集群部署脚本共享库 (被各脚本 source, 不单独执行)
# 依据: /home/lzh/max_lab/3fs_fdp_deployment_guide.md
# 注意: 所有脚本只操作 3FS 自有服务/文件, 不重启服务器, 不影响其他进程。

# ======== 路径与集群常量 ========
SRC="/home/smrc/lzh/3fs-main"          # 各服务器上的 3FS 源码树
BIN_DIR="${SRC}/build/bin"
CFG_DIR="${SRC}/configs"
UNIT_DIR="${SRC}/deploy/systemd"
SQL_DIR="${SRC}/deploy/sql"
OPT="/opt/3fs"
OPT_BIN="${OPT}/bin"
OPT_ETC="${OPT}/etc"
LOG_DIR="/var/log/3fs"
MOUNT_POINT="/3fs/stage"

CLUSTER_ID="stage"
MGMTD_ADDR="RDMA://10.10.44.210:8000"  # mgmtd (dskna004) IPoIB 地址
MONITOR_ADDR="10.10.44.210:10000"      # monitor_collector (dskna004)
CH_PASSWD="samsung"                    # ClickHouse default 用户密码
FDB_CLUSTER_FILE="${OPT_ETC}/fdb.cluster"
TOKEN_FILE="${OPT_ETC}/token.txt"

# 存储数据盘 (仅 nvme3n1/nvme4n1 可用; nvme2n1 不可用, 不使用)
STORAGE_DATA_DIRS=(/storage/data3/3fs /storage/data4/3fs)
STORAGE_HOSTS=(172.16.18.64 172.16.18.65 172.16.18.169)   # dsksa304/305/348 管理网

# ======== 节点映射 (按 hostname 自动识别角色) ========
detect_node() {
    local hn
    hn=$(hostname)
    case "${hn}" in
        dskna004)  ROLE="meta";    NODE_ID="";     IPoIB="10.10.44.210"; MGMT_IP="172.16.12.210" ;;
        dsksa304)  ROLE="storage"; NODE_ID="10001"; IPoIB="10.10.44.64";  MGMT_IP="172.16.18.64"  ;;
        dsksa305)  ROLE="storage"; NODE_ID="10002"; IPoIB="10.10.44.65";  MGMT_IP="172.16.18.65"  ;;
        dsksa348)  ROLE="storage"; NODE_ID="10003"; IPoIB="10.10.44.169"; MGMT_IP="172.16.18.169" ;;
        *) echo "ERROR: 未知主机名 '${hn}', 请在 4 台集群服务器上执行"; exit 1 ;;
    esac
}

require_role() {
    detect_node
    if [[ "${ROLE}" != "$1" ]]; then
        echo "ERROR: 本脚本只能在 '$1' 节点执行 (当前节点 $(hostname) 角色 ${ROLE})"
        exit 1
    fi
}

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        echo "ERROR: 请用 root 执行: sudo bash $0"
        exit 1
    fi
}

# ======== 输出辅助 ========
step()  { echo -e "\n### $*"; }
info()  { echo "  [INFO] $*"; }
warn()  { echo "  [WARN] $*"; }
fail()  { echo "  [FAIL] $*"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
die()   { echo "  [FATAL] $*" >&2; exit 1; }
summary_exit() {
    if [[ ${FAIL_COUNT:-0} -gt 0 ]]; then
        echo -e "\n!!!!! 共 ${FAIL_COUNT} 项检查失败, 请先解决问题 !!!!!"
        exit 1
    fi
    echo -e "\n===== 全部通过 ====="
}

check_exists() {
    [[ -e "$1" ]] || { echo "  [FAIL] $1 不存在"; return 1; }
}

# ======== admin_cli 封装 (02 安装后可用) ========
admin_cli() {
    "${OPT_BIN}/admin_cli" -cfg "${OPT_ETC}/admin_cli.toml" \
        --config.mgmtd_client.mgmtd_server_addresses "[\"${MGMTD_ADDR}\"]" "$@"
}

admin_cli_token() {
    admin_cli --config.user_info.token "$(cat "${TOKEN_FILE}")" "$@"
}

# ======== 共享配置生成器 (02 与 03 写出的 storage_main.toml 完全一致) ========
write_storage_main_toml() {  # $1 = 输出路径
    cat > "$1" <<'EOF'
# storage runtime config — 由部署脚本生成 (指南 §8), 上传到 mgmtd 统一管理
[server.mgmtd]
mgmtd_server_addresses = ["RDMA://10.10.44.210:8000"]

[[common.monitor.reporters]]
type = 'monitor_collector'

[common.monitor.reporters.monitor_collector]
remote_ip = "10.10.44.210:10000"

[server.targets]
# FDP: compaction 写入走 stream 2 (→ PLID 1); stream 1 (→ PLID 0) 预留空置;
# LMCache 数据流使用 stream 3..GET_MAX (→ PLID 2..)。
# 非 FDP 设备或超范围 id 自动回退 0 (默认放置)。启动期加载, 改动需 set-config + 重启服务。
fdp_compaction_stream_id = 2
target_paths = ["/storage/data3/3fs","/storage/data4/3fs"]
EOF
}

# 安装一个 systemd 单元并 daemon-reload
install_unit() {  # $1 = unit 文件名 (UNIT_DIR 下)
    cp "${UNIT_DIR}/$1" /usr/lib/systemd/system/
    systemctl daemon-reload
}
