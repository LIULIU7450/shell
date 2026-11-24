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

# 3FS 限制最多 4 个 IB 设备 (IBDevice.h kMaxDeviceCnt=4), 超过会在启动时 CRITICAL abort。
# dskna004 有 8 个活动 HCA (mlx5_0..7, ConnectX-7 200G IPoIB), 必须过滤到 4 个以内。
# device_filter 按 IB 设备名或其 netdev 名匹配 (IBDevice.cc:389)。
IB_DEVICE_FILTER_META='["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]'   # dskna004 (004 上 IPoIB .210-.213)
IB_DEVICE_FILTER_STORAGE=''                                    # 存储节点活动 HCA ≤2, 无需过滤

# 存储数据盘 (仅 nvme3n1/nvme4n1 可用; nvme2n1 不可用, 不使用)
STORAGE_DATA_DIRS=(/storage/data3/3fs /storage/data4/3fs)
STORAGE_HOSTS=(172.16.18.64 172.16.18.65 172.16.18.169)   # dsksa304/305/348 管理网

# ======== SSH 访问 (root + 密码登录; 可用 SSHPASS 环境变量覆盖) ========
SSH_USER="${SSH_USER:-root}"
# root 密码 (含特殊字符 !; 非交互脚本中 ! 无 history expansion, 无需转义)。
# 环境变量 SSHPASS / SSH_USER 可覆盖。
SSHPASS="${SSHPASS:-!@345Qwert}"

# 远程执行: ssh_exec <ip> <命令>
ssh_exec() {
    sshpass -p "${SSHPASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@$1" "$2"
}

# 推送文件: scp_push <本地文件> <ip> <远端路径>
scp_push() {
    sshpass -p "${SSHPASS}" scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$1" "${SSH_USER}@$2:$3"
}

# 注意: common.sh 内嵌了到存储节点的 root 密码, 部署完成后请将本目录权限收紧
# (chmod 600), 或改用 ssh-key 登录后清空 SSHPASS 变量。

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

# 安装二进制到 /opt/3fs/bin: 先 rm 再 cp — 目标二进制可能正在运行,
# 直接 cp 覆盖会报 "Text file busy" (ETXTBSY); unlink+新建对运行中进程安全。
install_bin() {  # $1 = 源 (BIN_DIR 下), $2 = 目标
    rm -f "$2"
    cp "$1" "$2"
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
# ib_devices_filter_block <filter_json> → 输出 [ib_devices] 段 (空 filter 则输出空 filter,
# 保持配置结构一致; 存储节点设备数 ≤4 本不需要, 但统一带上无副作用)
ib_devices_filter_block() {  # $1 = device_filter JSON 数组字符串 (可空)
    cat <<EOF

[ib_devices]
device_filter = $1
EOF
}

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
    ib_devices_filter_block "${IB_DEVICE_FILTER_STORAGE:-[]}" >> "$1"
}

# 安装一个 systemd 单元并 daemon-reload
install_unit() {  # $1 = unit 文件名 (UNIT_DIR 下)
    cp "${UNIT_DIR}/$1" /usr/lib/systemd/system/
    systemctl daemon-reload
}
