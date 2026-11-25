#!/bin/bash
# common.sh — 3FS FDP 集群部署脚本共享库 (被 01–04 source, 不单独执行)
# 依据: 3fs-main/deploy/README.md (官方 Setup Guide, Step 0–8) + 本 fork 的 FDP 扩展配置
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

# 关键: 3FS 的 RDMA 地址里填的是「TCP 握手端点的以太网 IP」, 不是 IPoIB 地址。
# Listener.cc:33 的 checkNicType() 对 Address::RDMA 只挑选 en*/eth*/bond*/xgbe* 前缀的网卡
# 做 listen (握手/建连走 TCP), 真正的数据面由 IBManager 在 IB 设备上建 QP。
# 因此填 10.10.44.x (IPoIB) 会导致服务实际监听在 172.16.x.x 上, 客户端连 IPoIB 地址必然失败。
# 官方 README 用的也是 192.168.1.x 这类以太网 IP。
MGMTD_ADDR="RDMA://172.16.12.210:8000"  # mgmtd (dskna004) 管理网 IP
MONITOR_ADDR="172.16.12.210:10000"      # monitor_collector (dskna004) 管理网 IP
CH_PASSWD="samsung"                    # ClickHouse default 用户密码
FDB_CLUSTER_FILE="${OPT_ETC}/fdb.cluster"
TOKEN_FILE="${OPT_ETC}/token.txt"

# init-cluster 参数: 链表 ID / chunk 大小 / strip 大小
# 重要约束 (ChainAllocator.h:103): 分配 layout 时要求 **链数 >= stripeSize**,
# 否则 meta 报 "chain table 1 have only N chains" 且所有写请求 EIO。
# 本集群 3 节点 × 2 盘 × 1 target/盘 = 6 targets, RF=3 ⇒ 恰好 2 条链,
# 因此 stripeSize 必须 <= 2; 官方默认 16 只适用于「链数 ≥ 16」的集群。
INIT_CHAIN_TABLE_ID=1
INIT_CHUNK_SIZE=1048576
INIT_STRIP_SIZE=2

# FDP: compaction 写入专用 stream (→ PLID 1); stream 1 空置, LMCache 用 3..GET_MAX
FDP_COMPACTION_STREAM_ID=2

# 3FS 限制最多 4 个 IB 设备 (IBDevice.h kMaxDeviceCnt=4), 超过会在启动时 CRITICAL abort。
# dskna004 有 8 个活动 HCA (mlx5_0..7), 必须过滤到 4 个以内。
# device_filter 按 IB 设备名或其 netdev 名匹配 (IBDevice.cc:389)。
IB_DEVICE_FILTER_META='["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]'   # dskna004 (mlx5_0..3 = ibp12/18/75/84s0 = .210-.213)
IB_DEVICE_FILTER_STORAGE='[]'                                  # 存储节点活动 HCA ≤2, 无需过滤

# 存储数据盘 (仅 nvme3n1/nvme4n1 可用; nvme2n1 属 Lustre zpool, 不使用)
# 两个数组按下标一一对应: STORAGE_DATA_DIRS[i] 即 create-target 的 --disk-index i, 其物理盘为 STORAGE_DEVS[i]。
# 扩到 3 盘时两者都要加(见 3FS_FDP_部署手册_逐步执行版.md 附录 B)。
STORAGE_DATA_DIRS=(/storage/data3/3fs /storage/data4/3fs)
STORAGE_DEVS=(/dev/nvme3n1 /dev/nvme4n1)
STORAGE_HOSTS=(172.16.18.64 172.16.18.65 172.16.18.169)   # dsksa304/305/348 管理网

# ======== SSH 访问 (root + 密码登录; 可用 SSHPASS 环境变量覆盖) ========
SSH_USER="${SSH_USER:-root}"
# root 密码 (含特殊字符 !; 非交互脚本中 ! 无 history expansion, 无需转义)。
SSHPASS="${SSHPASS:-!@345Qwert}"

ssh_exec() {  # $1=ip $2=命令
    sshpass -p "${SSHPASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@$1" "$2"
}

scp_push() {  # $1=本地文件 $2=ip $3=远端路径
    sshpass -p "${SSHPASS}" scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$1" "${SSH_USER}@$2:$3"
}

# 注意: common.sh 内嵌了到存储节点的 root 密码, 部署完成后请将本目录权限收紧
# (chmod 700 目录 / 600 文件), 或改用 ssh-key 登录后清空 SSHPASS 变量。

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

# 本节点的 IB 设备过滤值 (dskna004 必须过滤, 存储节点空过滤)
ib_filter_for_role() {
    if [[ "${ROLE}" == "meta" ]]; then echo "${IB_DEVICE_FILTER_META}"; else echo "${IB_DEVICE_FILTER_STORAGE}"; fi
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

# 安装一个 systemd 单元并 daemon-reload
install_unit() {  # $1 = unit 文件名 (UNIT_DIR 下)
    cp "${UNIT_DIR}/$1" /usr/lib/systemd/system/
    systemctl daemon-reload
}

# ======== admin_cli 封装 (02 安装后可用) ========
admin_cli() {
    "${OPT_BIN}/admin_cli" -cfg "${OPT_ETC}/admin_cli.toml" \
        --config.mgmtd_client.mgmtd_server_addresses "[\"${MGMTD_ADDR}\"]" "$@"
}

admin_cli_token() {
    admin_cli --config.user_info.token "$(cat "${TOKEN_FILE}")" "$@"
}

# ======== 配置渲染: 以官方 configs/*.toml 为基线, 按 (段, 键, 值) 三元组精确覆盖 ========
# 官方运行时配置里有 [[server.base.groups]] 等服务组定义 (Server.cc 用 groups_.front()),
# 缺失会导致启动时段错误, 因此一律从官方模板派生, 而不是手写极简配置。
# 用法: render_toml <模板> <输出> [段 键 值] ...
#   段 = "" 表示文件根表 (第一个 [section] 之前); 值为 TOML 字面量 (字符串需自带引号)。
render_toml() {
    local tpl="$1" out="$2"; shift 2
    [[ -f "${tpl}" ]] || die "配置模板不存在: ${tpl}"
    python3 - "${tpl}" "${out}" "$@" <<'PY' || die "渲染配置失败: ${out}"
import sys

tpl, out = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
if len(args) % 3 != 0:
    sys.exit("render_toml: 参数必须是 (段, 键, 值) 三元组")

patches = [(args[i], args[i + 1], args[i + 2]) for i in range(0, len(args), 3)]

# 解析成 [ (header 或 None, [行...]) ]
blocks, cur = [(None, [])], None
for line in open(tpl, encoding="utf-8").read().splitlines():
    s = line.strip()
    if s.startswith("[") and s.endswith("]") and not s.startswith("[["):
        cur = (s, [])
        blocks.append(cur)
    elif s.startswith("[[") and s.endswith("]]"):
        cur = (s, [])
        blocks.append(cur)
    else:
        blocks[-1][1].append(line)

def header_of(name):
    return "[]" if name == "" else "[%s]" % name

for section, key, value in patches:
    hdr = header_of(section)
    target = None
    for h, body in blocks:
        if (h or "[]") == hdr:
            target = (h, body)
            break
    if target is None:
        target = (hdr, [])
        blocks.append(target)
        target[1].append("%s = %s" % (key, value))
        continue
    body = target[1]
    hit = False
    for i, line in enumerate(body):
        s = line.lstrip()
        if s.startswith("#"):
            continue
        if s.split("=")[0].strip() == key and "=" in s:
            body[i] = "%s = %s" % (key, value)
            hit = True
            break
    if not hit:
        # 插到该段最后一行有效内容之后 (跳过段尾空行)
        while body and not body[-1].strip():
            body.pop()
        body.append("%s = %s" % (key, value))
        body.append("")

lines = []
for h, body in blocks:
    if h is not None:
        lines.append(h)
    lines.extend(body)
text = "\n".join(lines).rstrip("\n") + "\n"
open(out, "w", encoding="utf-8").write(text)
PY
    # TOML 语法自检 (tomli 可用时)
    python3 - "${out}" <<'PY' 2>/dev/null || true
import sys
try:
    import tomli
except ImportError:
    sys.exit(0)
with open(sys.argv[1], "rb") as f:
    tomli.load(f)
PY
}

# ---- 各服务配置生成器 (全部从官方模板派生) ----

render_monitor_cfg() {  # $1=输出
    render_toml "${CFG_DIR}/monitor_collector_main.toml" "$1" \
        "common"                    "cluster_id"    "'${CLUSTER_ID}'" \
        "common.ib_devices"         "device_filter" "${IB_DEVICE_FILTER_META}" \
        "server.monitor_collector.reporter"            "type"   "'clickhouse'" \
        "server.monitor_collector.reporter.clickhouse" "db"     "'3fs'" \
        "server.monitor_collector.reporter.clickhouse" "host"   "'127.0.0.1'" \
        "server.monitor_collector.reporter.clickhouse" "passwd" "'${CH_PASSWD}'" \
        "server.monitor_collector.reporter.clickhouse" "port"   "'9000'" \
        "server.monitor_collector.reporter.clickhouse" "user"   "'default'"
}

render_admin_cli_cfg() {  # $1=输出 $2=ib 过滤值
    render_toml "${CFG_DIR}/admin_cli.toml" "$1" \
        ""          "cluster_id"    "'${CLUSTER_ID}'" \
        "fdb"       "clusterFile"   "'${FDB_CLUSTER_FILE}'" \
        "ib_devices" "device_filter" "$2"
}

render_mgmtd_cfg() {  # $1=输出 (runtime, 由 init-cluster 上传)
    render_toml "${CFG_DIR}/mgmtd_main.toml" "$1" \
        "common.monitor.reporters.monitor_collector" "remote_ip" "'${MONITOR_ADDR}'"
}

render_mgmtd_launcher_cfg() {  # $1=输出 $2=ib 过滤值
    render_toml "${CFG_DIR}/mgmtd_main_launcher.toml" "$1" \
        ""            "cluster_id"  "'${CLUSTER_ID}'" \
        "fdb"         "clusterFile" "'${FDB_CLUSTER_FILE}'" \
        "kv_engine.fdb" "clusterFile" "'${FDB_CLUSTER_FILE}'" \
        "ib_devices"  "device_filter" "$2"
}

render_meta_cfg() {  # $1=输出 (runtime, set-config --type META 上传)
    render_toml "${CFG_DIR}/meta_main.toml" "$1" \
        "server.mgmtd_client" "mgmtd_server_addresses" "[\"${MGMTD_ADDR}\"]" \
        "server.fdb"          "clusterFile"            "'${FDB_CLUSTER_FILE}'" \
        "server.kv_engine.fdb" "clusterFile"           "'${FDB_CLUSTER_FILE}'" \
        "common.monitor.reporters.monitor_collector" "remote_ip" "'${MONITOR_ADDR}'"
}

render_meta_launcher_cfg() {  # $1=输出 $2=ib 过滤值
    render_toml "${CFG_DIR}/meta_main_launcher.toml" "$1" \
        ""            "cluster_id"  "'${CLUSTER_ID}'" \
        "ib_devices"  "device_filter" "$2" \
        "mgmtd_client" "mgmtd_server_addresses" "[\"${MGMTD_ADDR}\"]"
}

# 存储 runtime 配置: 三台存储节点内容一致 (target_paths 下标 = create-target 的 --disk-index)
# target_paths 由 STORAGE_DATA_DIRS 派生, 增删盘只需改数组, 不要在这里硬编码。
render_storage_cfg() {  # $1=输出
    local paths="" d
    for d in "${STORAGE_DATA_DIRS[@]}"; do
        paths+="\"${d}\","
    done
    paths="[${paths%,}]"

    render_toml "${CFG_DIR}/storage_main.toml" "$1" \
        "server.mgmtd" "mgmtd_server_addresses" "[\"${MGMTD_ADDR}\"]" \
        "common.monitor.reporters.monitor_collector" "remote_ip" "'${MONITOR_ADDR}'" \
        "server.targets" "target_paths" "${paths}" \
        "server.targets" "fdp_compaction_stream_id" "${FDP_COMPACTION_STREAM_ID}"
}
# 兼容旧脚本调用的名字
write_storage_main_toml() { render_storage_cfg "$1"; }

render_storage_launcher_cfg() {  # $1=输出 $2=ib 过滤值
    render_toml "${CFG_DIR}/storage_main_launcher.toml" "$1" \
        ""            "cluster_id"  "'${CLUSTER_ID}'" \
        "ib_devices"  "device_filter" "$2" \
        "mgmtd_client" "mgmtd_server_addresses" "[\"${MGMTD_ADDR}\"]"
}

render_fuse_cfg() {  # $1=输出 (runtime, set-config --type FUSE 上传)
    render_toml "${CFG_DIR}/hf3fs_fuse_main.toml" "$1" \
        "mgmtd" "mgmtd_server_addresses" "[\"${MGMTD_ADDR}\"]" \
        "common.monitor.reporters.monitor_collector" "remote_ip" "'${MONITOR_ADDR}'"
}

render_fuse_launcher_cfg() {  # $1=输出 $2=ib 过滤值
    render_toml "${CFG_DIR}/hf3fs_fuse_main_launcher.toml" "$1" \
        ""           "cluster_id"  "'${CLUSTER_ID}'" \
        ""           "mountpoint"  "'${MOUNT_POINT}'" \
        ""           "token_file"  "'${TOKEN_FILE}'" \
        "ib_devices" "device_filter" "$2" \
        "mgmtd_client" "mgmtd_server_addresses" "[\"${MGMTD_ADDR}\"]"
}

# ---- AppConfig (node_id) ----
render_app_cfg() {  # $1=服务名 (mgmtd|meta|storage) $2=node_id $3=输出
    render_toml "${CFG_DIR}/$1_main_app.toml" "$3" \
        "" "allow_empty_node_id" "false" \
        "" "node_id" "$2"
}
