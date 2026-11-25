# 3FS + XFS FDP 集群部署手册（逐步执行版）

> 适用项目：`/home/smrc/lzh/3fs-main`（deepseek 3FS + XFS FDP write stream 扩展）
> 适用环境：dskna004（管理/meta）+ dsksa304 / dsksa305 / dsksa348（存储）
> 版本：v1.0（2026-11-24，全部命令在本环境实测通过）
>
> **本文档自包含**：不需要 `deploy_scripts/` 下的任何脚本，所有命令与配置都在文中给出。
> 每一步都按"目的 → 命令 → 预期输出 → 失败怎么办"组织，可照着敲完。
>
> 风格参考：`3fs-main/deploy/README.md`（官方 8 步流程）与 `../3fs_fdp_deployment_guide.md`（FDP 背景），
> 但本文档修正了两份材料中已被实测证伪的内容（见 §1.2、§1.3、§1.4 的 ★ 标记）。

---

## 目录

- [0. 怎么用这份文档](#0-怎么用这份文档)
- [1. 架构与关键概念](#1-架构与关键概念)
- [2. 部署前准备](#2-部署前准备)
- [3. 阶段 A：四台节点预检](#3-阶段-a四台节点预检)
- [4. 阶段 B：管理节点部署（dskna004）](#4-阶段-b管理节点部署dskna004)
- [5. 阶段 C：存储节点部署（3 台）](#5-阶段-c存储节点部署3-台)
- [6. 阶段 D：集群收尾（dskna004）](#6-阶段-d集群收尾dskna004)
- [7. 阶段 E：验证](#7-阶段-e验证)
- [8. 故障速查表](#8-故障速查表)
- [附录 A：把 FDP_COMPACTION_STREAM_ID 改为 0](#附录-a把-fdp_compaction_stream_id-改为-0)
- [附录 B：三盘拓扑（9 target / 3 链 / RF=3）](#附录-b三盘拓扑9-target--3-链--rf3)
- [附录 C：配置与参数速查](#附录-c配置与参数速查)

---

## 0. 怎么用这份文档

### 0.1 阅读顺序

| 阶段 | 在哪台机器 | 对应章节 | 官方 README 步骤 |
|---|---|---|---|
| 预检 | 4 台全部 | §3 | 前置条件 |
| 管理面 | 仅 dskna004 | §4 | Step 1–5 |
| 存储面 | 3 台存储 | §5 | Step 6 |
| 收尾 | 仅 dskna004 | §6 | Step 7–8 |
| 验证 | 全部 | §7 | 部署后验证 |

顺序不可交换：存储节点必须先拿到 mgmtd 下发的 STORAGE 运行时配置才能启动；FUSE 必须等链/target 就绪。

### 0.2 约定

- 所有命令默认以 `root` 执行（`sudo -i` 后操作）。
- `【dskna004】` / `【存储节点】` 标注该命令在哪台机器执行；未标注的在同一台机器继续执行。
- 代码块内 `$VAR` 依赖 §2.4 定义的环境变量，请在同一 shell 会话里操作，或先 `source /root/3fs-deploy/env.sh`。
- 破坏性操作单独标注 **⚠ 危险**。

---

## 1. 架构与关键概念

### 1.1 组件与端口

| 组件 | 部署位置 | 监听 | 作用 |
|---|---|---|---|
| FoundationDB | dskna004 | 4500（本地） | 元数据 KV 存储 |
| ClickHouse | dskna004 | 9000（本地） | 监控数据落库（表 `3fs.counters` / `3fs.distributions`） |
| monitor_collector | dskna004 | **172.16.12.210:10000** | 收集各节点监控并写 ClickHouse |
| mgmtd | dskna004（node_id=1） | **RDMA://172.16.12.210:8000** | 集群管理、配置下发、路由表 |
| meta | dskna004（node_id=100） | 动态 | 文件/目录元数据 |
| storage | dsksa304/305/348（10001/10002/10003） | 动态 | chunk 存储，**FDP 在这里生效** |
| FUSE client | dskna004 | `/3fs/stage` | 文件系统挂载点 |

### 1.2 ★ 地址方案：RDMA 地址填以太网管理 IP，不是 IPoIB

3FS 的 `RDMA://host:port` 中，**host 是 TCP 握手端点**（`Listener.cc` 的 `checkNicType()` 对 RDMA 只挑
`en*/eth*/bond*/xgbe*` 网卡去监听），数据面才走 InfiniBand。若填 IPoIB 地址（10.10.44.x），
服务会绑定在 IB 网卡的 IP 上但报 `Connection refused`，表现为：

```
admin_cli list-nodes
6004: MgmtdClient::RoutingInfoNotReady
```

正确取值（本环境）：

| 用途 | 值 |
|---|---|
| `mgmtd_server_addresses` | `["RDMA://172.16.12.210:8000"]` |
| `monitor_collector.remote_ip` | `172.16.12.210:10000` |

IB 只在数据面参与，靠 `[ib_devices] device_filter` 控制（dskna004 有 8 个活动 HCA，3FS 上限 4，
必须显式过滤；存储节点活动 HCA ≤ 2，用空列表即可）。

### 1.3 ★ 链 / target / 链表 / stripe 的关系（最容易踩坑）

```
chain（链）      = 3 个 target 组成一个 3 副本复制组（HEAD→MIDDLE→TAIL）
target           = 某台存储节点上某块盘的一个存储单元，必须属于且仅属于一条链
chain table（链表）= 一组链的集合，ID=1，带版本号
layout.stripeSize = 一个文件被切分到几条链上（跨链条带宽度）
```

**硬约束**（`src/meta/components/ChainAllocator.h:103`）：

```c
if (chainCnt < layout.stripeSize || chainCnt == 0) {
    // Failed to allocate ... chain table 1 have only N chains.
}
```

即 **链表里的链数必须 ≥ stripeSize**，否则所有写请求返回 `EIO`。而链数又受物理条件限制：

```
链数 = (每节点 target 数)            # RF=3 时，每链每节点各 1 个 target
每节点 target 数 = 盘数 × 每盘 target 数
```

本集群两种合法组合：

| 拓扑 | 每节点 target | 链数 | 必须的 stripe |
|---|---|---|---|
| 2 盘 × 1 target（当前部署） | 2 | 2 | **2** |
| 3 盘 × 1 target（附录 B） | 3 | 3 | **3** |

`init-cluster` 的 stripe 参数一旦写入 FDB **不可修改**，改拓扑必须清 FDB 重建（§附录 B）。

### 1.4 ★ FDP write stream 编号约定

| stream id | 用途 | 落盘 PLID |
|---|---|---|
| 0 | 不携带 placement（默认放置） | — |
| 1 | **保留空置** | PLID 0 |
| 2 | 3FS chunk engine 的 compaction 复制（`fdp_compaction_stream_id`） | PLID 1 |
| 3..N | 上层业务（LMCache KV offload 等） | PLID 2.. |

内核接口：`FS_IOC_WRITE_STREAM`（`_IOWR('f', 43, struct fs_write_stream)`，值 `0xC010662B`），
`Hf3fsFsWriteStream` 结构 16 字节；FUSE 侧另有 `HF3FS_IOC_WRITE_STREAM`（`_IOWR('h',16,...)`，值 `0xC0106810`）。

**能力探测**：`GET_MAX` 返回设备向 XFS 暴露的硬件写流数量（本环境 **14** = 硬件 16 − XFS 保留 2），
`0` 才表示设备未启用 FDP（此时 3FS 自动回退默认放置，不报错）。

---

## 2. 部署前准备

### 2.1 软硬件清单

| 项 | 要求 | 本环境实测 |
|---|---|---|
| 内核 | 带 FDP 补丁（`FS_IOC_WRITE_STREAM`） | `7.0.0-rc2` |
| CPU/内存 | 每节点 ≥ 16 核 / 64GB | — |
| RDMA | 至少 1 个 Active IB 端口 | dskna004 8 个，存储 1–2 个 |
| 系统盘 | ext4 `/` | `/dev/nvme0n1p2` |
| 数据盘（存储） | XFS，每盘 15.36TB | `nvme3n1→/storage/data3`、`nvme4n1→/storage/data4` |
| FoundationDB | 7.3.63（server 与 `libfdb_c` 必须同版本） | 一致 |
| ClickHouse | 22.x+（26.x 需按 §4.1 改压缩方式） | 26.10 |
| 3FS 二进制 | `build/bin/` 下 6 个可执行文件 | 4 台均齐全 |

> **⚠ 本环境盘位提醒**：`nvme2n1` 属于 Lustre 的 ZFS 池 `ost00pool`（9.97TB 数据），
> `nvme1n1` 亦为 `zfs_member`。**它们不能用于 3FS**。当前 3FS 只用 `nvme3n1`、`nvme4n1`。

### 2.2 目录规划

| 路径 | 用途 |
|---|---|
| `/opt/3fs/bin` | 二进制 |
| `/opt/3fs/etc` | 所有配置（`*_launcher.toml`、`*_main.toml`、`fdb.cluster`、`token.txt`） |
| `/var/log/3fs` | 日志 |
| `/storage/data3/3fs`、`/storage/data4/3fs` | 存储 target 根目录（下标 = `--disk-index`） |
| `/3fs/stage` | FUSE 挂载点 |
| `/root/3fs-deploy` | 本文档的临时工作目录（含 `env.sh`、`tomlset.py`） |

### 2.3 关键参数决策表（部署前定好，中途不要改）

| 参数 | 本环境取值 | 说明 |
|---|---|---|
| `CLUSTER_ID` | `stage` | 所有配置里的 `cluster_id` |
| `INIT_CHAIN_TABLE_ID` | `1` | 链表 ID |
| `INIT_CHUNK_SIZE` | `1048576` | 1MB |
| `INIT_STRIP_SIZE` | **`2`** | 必须 ≤ 链数（§1.3） |
| `FDP_COMPACTION_STREAM_ID` | **`2`** | compaction 分流；改 0 见附录 A |
| `STORAGE_DATA_DIRS` | `/storage/data3/3fs`,`/storage/data4/3fs` | 顺序即 `disk-index` |
| `TARGETS` | 6 个（3 节点 × 2 盘） | §6.2 |
| `CHAINS` | 2 条 | §6.3 |

### 2.4 建立工作目录与环境变量（**4 台节点都执行一次**）

```bash
mkdir -p /root/3fs-deploy
cat > /root/3fs-deploy/env.sh <<'EOF'
# ===== 3FS 部署环境变量（每台机器一致；节点相关项在各节单独设置）=====
export SRC=/home/smrc/lzh/3fs-main
export BIN=$SRC/build/bin
export CFG=$SRC/configs
export UNIT=$SRC/deploy/systemd
export SQL=$SRC/deploy/sql
export OPT=/opt/3fs
export ETCDIR=$OPT/etc
export LOGDIR=/var/log/3fs

export CLUSTER_ID=stage
export MOUNT_POINT=/3fs/stage
export FDB_CLUSTER_FILE=$ETCDIR/fdb.cluster
export TOKEN_FILE=$ETCDIR/token.txt

export MGMTD_ADDR=RDMA://172.16.12.210:8000
export MONITOR_ADDR=172.16.12.210:10000
export CH_PASSWD=samsung

export INIT_CHAIN_TABLE_ID=1
export INIT_CHUNK_SIZE=1048576
export INIT_STRIP_SIZE=2
export FDP_COMPACTION_STREAM_ID=2

export STORAGE_DATA_DIRS="/storage/data3/3fs /storage/data4/3fs"
export STORAGE_HOSTS="172.16.18.64 172.16.18.65 172.16.18.169"

# dskna004 的 4 个 IB 设备过滤；存储节点用 []
export IB_FILTER_META='["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]'
export IB_FILTER_STORAGE='[]'
EOF
chmod 600 /root/3fs-deploy/env.sh
source /root/3fs-deploy/env.sh

mkdir -p "$OPT/bin" "$ETCDIR" "$LOGDIR"
echo "已就绪: $OPT"
```

**预期**：输出 `已就绪: /opt/3fs`。

### 2.5 在 4 台机器上都放一个配置覆盖工具（本文档唯一的辅助工具）

官方 `configs/*.toml` 有 300–500 行，直接改写容易漏项（尤其 `[[server.base.groups]]` 服务组，
缺失会段错误）。正确做法是**以官方模板为基线，只精确覆盖少数键值**。把下面 40 行 Python 存好：

```bash
cat > /root/3fs-deploy/tomlset.py <<'PY'
#!/usr/bin/env python3
"""tomlset.py <模板> <输出> [段 键 值] ...   —— 段感知的 TOML 键值覆盖

段为空字符串表示文件根表；值为 TOML 字面量（字符串要自带引号）。
只替换已存在的键；键不存在则追加到该段末尾。注释行不参与匹配。
"""
import sys

tpl, out = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
if len(args) % 3:
    sys.exit("参数必须是 (段, 键, 值) 三元组")

blocks, cur = [(None, [])], None
for line in open(tpl, encoding="utf-8").read().splitlines():
    s = line.strip()
    if s.startswith("[[") and s.endswith("]]"):
        cur = (s, []); blocks.append(cur)
    elif s.startswith("[") and s.endswith("]"):
        cur = (s, []); blocks.append(cur)
    else:
        blocks[-1][1].append(line)

for i in range(0, len(args), 3):
    section, key, value = args[i], args[i + 1], args[i + 2]
    hdr = "[]" if section == "" else "[%s]" % section
    body = next((b for h, b in blocks if (h or "[]") == hdr), None)
    if body is None:
        blocks.append((hdr, ["%s = %s" % (key, value), ""]))
        continue
    for j, line in enumerate(body):
        s = line.lstrip()
        if s.startswith("#") or "=" not in s:
            continue
        if s.split("=")[0].strip() == key:
            body[j] = "%s = %s" % (key, value)
            break
    else:
        while body and not body[-1].strip():
            body.pop()
        body.extend(["%s = %s" % (key, value), ""])

lines = []
for h, body in blocks:
    if h is not None:
        lines.append(h)
    lines.extend(body)
open(out, "w", encoding="utf-8").write("\n".join(lines).rstrip("\n") + "\n")
PY
chmod +x /root/3fs-deploy/tomlset.py
```

**预期**：无输出即成功。后续所有配置生成都用它，等价于手工编辑但不会漏行。

---

## 3. 阶段 A：四台节点预检

> **目的**：确认内核 FDP 能力、FDP 设备、二进制、时间同步、服务间可达性。
> **在哪执行**：dskna004、dsksa304、dsksa305、dsksa348 **各一次**。

### 3.1 内核与 ioctl

```bash
source /root/3fs-deploy/env.sh

uname -r                                    # 期望 7.0.0-rc2
grep -rn "FS_IOC_WRITE_STREAM" /usr/src/linux-headers-$(uname -r)/include/uapi/linux/fs.h
```

**预期**：内核版本正确，头文件里能找到 `FS_IOC_WRITE_STREAM`。
**失败**：内核不对 —— 换内核属高危操作，本环境已锁定，**不要在本手册中改 GRUB**。

### 3.2 时间同步

```bash
chronyc tracking | grep -E "Leap status|System time"
```

**预期**：`Leap status     : Normal`。时间漂移会导致租约/心跳异常。

### 3.3 3FS 二进制

```bash
ls -l $BIN/{admin_cli,storage_main,mgmtd_main,meta_main,hf3fs_fuse_main,monitor_collector_main} 2>&1
```

**预期**：4 台都齐全（存储节点只需 `admin_cli` + `storage_main`，但齐全无妨）。
**失败**：回到源码树编译（`cd $SRC && ./build.sh` 或既有构建命令），产物在 `build/bin`。

### 3.4 【存储节点】FDP 设备与 XFS 能力

```bash
# 1) 设备是否支持 FDP：应列出 PID 0..N 且连续
for d in /dev/nvme3n1 /dev/nvme4n1; do
  echo "== $d"
  nvme fdp status "$d" -o json | python3 -c \
    "import json,sys;d=json.load(sys.stdin);print('nruhsd',d['nruhsd'],'PIDs',' '.join(str(e['pid']) for e in d['ruhss']))"
done

# 2) 数据盘挂载
findmnt -t xfs -o SOURCE,TARGET,OPTIONS

# 3) XFS 是否向用户暴露硬件写流
#    ⚠ python 的 bytes 不可变：ioctl 结果在“返回值”里，读入参 ws 永远是 0（常见误判）
python3 - <<'EOF'
import fcntl, os, struct
FS = 0xC010662B
for m in ("/storage/data3", "/storage/data4"):
    p = m + "/.getmax_probe"
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    ret = fcntl.ioctl(fd, FS, struct.pack("IIII", 1, 0, 0, 0))   # GET_MAX
    print(m, "GET_MAX =", struct.unpack("IIII", ret)[2])
    os.close(fd); os.unlink(p)
EOF
```

**预期**：

- `nvme fdp status` 能输出 PID 列表（本环境 `nruhsd 16`，PID 0..15）；
- `findmnt` 显示 `nvme3n1→/storage/data3`、`nvme4n1→/storage/data4`，选项含 `noatime,nodiratime`；
- `GET_MAX`：**本环境为 14**（硬件 16 条写流 − XFS 内部保留 2 条）→ FDP 分流可用，
  数据 stream 可用范围 3..14（§7.2 会验证到 PLID 级）。若返回 0 则说明设备未向内核暴露写流，
  3FS 会自动回退默认放置（不报错）。

**失败**：盘未挂载 → 按 §2.2 手工挂载；`GET_MAX` 报 `OSError` → 内核缺 ioctl，回到 §3.1。

### 3.5 【dskna004】依赖服务与 ssh 可达

```bash
# ClickHouse
clickhouse-client --password "$CH_PASSWD" -q "SELECT version()"

# FDB
fdbcli --version; ls -l /lib/libfdb_c.so*

# 到 3 台存储节点的 ssh（后续要分发 fdb.cluster）
for ip in $STORAGE_HOSTS; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip 'hostname' && echo "$ip OK"
done
```

**预期**：ClickHouse 版本号、FDB 7.3.x、3 个主机名。
**失败**：ClickHouse 未起 → `systemctl start clickhouse-server`（**只启动，不重启**）；
`sshpass` 缺失 → `apt install -y sshpass`。

---

## 4. 阶段 B：管理节点部署（dskna004）

> 对应官方 README Step 1–5。全部在 **dskna004** 执行。

### 4.1 ClickHouse：建表 + 把网络压缩改为 LZ4

**目的**：① 建 3FS 监控表；② 3FS 内置 clickhouse-cpp 只支持 LZ4，而 ClickHouse 26.x 默认 ZSTD，
不改会导致 monitor 报 `unsupported compression method 144` 且表里没有数据。

```bash
source /root/3fs-deploy/env.sh

# 1) 建表（官方 SQL，含 create database 3fs）
clickhouse-client --password "$CH_PASSWD" --multiquery < "$SQL/3fs-monitor.sql"
clickhouse-client --password "$CH_PASSWD" -q "SHOW TABLES FROM \`3fs\`"
```

**预期**：列出 `counters`、`distributions`。

```bash
# 2) 网络压缩降为 LZ4（只改 default profile，不重启 clickhouse-server）
clickhouse-client --password "$CH_PASSWD" -q \
  "SELECT value FROM system.settings WHERE name='network_compression_method'"
```

若输出不是 `lz4`：

```bash
cat > /etc/clickhouse-server/users.d/zz-3fs-lz4.xml <<'EOF'
<?xml version="1.0"?>
<!-- 3FS monitor_collector 内置 clickhouse-cpp 仅支持 LZ4；
     ClickHouse 26.x 默认 ZSTD 会让 INSERT 报 unsupported compression method 144 -->
<clickhouse>
    <profiles>
        <default>
            <network_compression_method>lz4</network_compression_method>
        </default>
    </profiles>
</clickhouse>
EOF
chmod 644 /etc/clickhouse-server/users.d/zz-3fs-lz4.xml
clickhouse-client --password "$CH_PASSWD" -q "SYSTEM RELOAD USERS"
clickhouse-client --password "$CH_PASSWD" -q \
  "SELECT value FROM system.settings WHERE name='network_compression_method'"   # 期望 lz4
```

**失败**：`SYSTEM RELOAD USERS` 报错 → 检查 XML 语法；仍然无效才考虑重启 clickhouse-server（会影响其他使用者，需评估）。

### 4.2 monitor_collector：采集并写 ClickHouse

```bash
source /root/3fs-deploy/env.sh

python3 /root/3fs-deploy/tomlset.py "$CFG/monitor_collector_main.toml" \
  "$ETCDIR/monitor_collector_main.toml" \
  "common" "cluster_id" "'$CLUSTER_ID'" \
  "common.ib_devices" "device_filter" "$IB_FILTER_META" \
  "server.monitor_collector.reporter" "type" "'clickhouse'" \
  "server.monitor_collector.reporter.clickhouse" "db" "'3fs'" \
  "server.monitor_collector.reporter.clickhouse" "host" "'127.0.0.1'" \
  "server.monitor_collector.reporter.clickhouse" "port" "'9000'" \
  "server.monitor_collector.reporter.clickhouse" "user" "'default'" \
  "server.monitor_collector.reporter.clickhouse" "passwd" "'$CH_PASSWD'"

# 校验关键段
grep -A6 "reporter.clickhouse" "$ETCDIR/monitor_collector_main.toml"

cp "$BIN/monitor_collector_main" "$OPT/bin/monitor_collector_main"
cp "$UNIT/monitor_collector_main.service" /usr/lib/systemd/system/
systemctl daemon-reload
systemctl enable --now monitor_collector_main
ss -lntp | grep 10000
```

**预期**：

- 配置文件出现 `type='clickhouse'`、`db='3fs'`、`port='9000'`、`passwd='samsung'`；
- `ss` 显示 `172.16.12.210:10000` 监听（或 `0.0.0.0:10000`）。

**注意**：monitor_collector 的 `remote_ip` 由各 *客户端* 配置指向它，它自己不需要知道 mgmtd。

### 4.3 FoundationDB：确认可用（必要时初始化）

**目的**：FDB 是 mgmtd/meta 的元数据底座。未 configure 的空库上 `fdbcli status json` 会**阻塞到超时返回空**，
不要据此判断"库损坏"。

```bash
source /root/3fs-deploy/env.sh
systemctl is-active foundationdb || systemctl start foundationdb

# 是否已可用（秒级返回，不会阻塞）
fdbcli --exec "status minimal" 2>&1 | head -3
```

**分支 1 —— 输出 `The database is available.`**：已就绪，跳到 §4.4。

**分支 2 —— 输出 `The database is unavailable` 或超时/空**：需要初始化（全新环境）：

```bash
# 确认服务与配置
systemctl status foundationdb --no-pager | head -5
grep -E "^(cluster_file|listen_address|datadir|port)" /etc/foundationdb/foundationdb.conf

# 初始化（单机单副本）
fdbcli --exec "configure new single ssd" 2>&1 | head -5
sleep 5
fdbcli --exec "status minimal"
```

**预期**：`The database is available.`

**⚠ 危险**：`configure new` 会清空该 FDB 集群。若这台机器的 FDB 上有**其他业务**，先确认 `datadir`
与 cluster file，必要时改用独立端口/目录。本环境的 FDB 只服务 3FS。

**失败**：`fdbcli` 报无法连接 → 检查 `foundationdb.conf` 的 `listen_address` 与
`/etc/foundationdb/fdb.cluster`；数据目录损坏才需要停服备份后清空 `datadir`
（本手册对应脚本的 `--reset-fdb` 行为）。

### 4.4 生成并分发 fdb.cluster

```bash
source /root/3fs-deploy/env.sh

# 权威来源是 FDB 自己的 cluster 文件（形如 3fsfdp:xxxxxxxx@127.0.0.1:4500）
cat /etc/foundationdb/fdb.cluster
cp /etc/foundationdb/fdb.cluster "$FDB_CLUSTER_FILE"
chmod 644 "$FDB_CLUSTER_FILE"

# 分发到 3 台存储节点（备用：本手册所有 admin_cli 管理命令都在 dskna004 执行）
for ip in $STORAGE_HOSTS; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip "mkdir -p $ETCDIR"
  sshpass -p '!@345Qwert' scp -o StrictHostKeyChecking=no "$FDB_CLUSTER_FILE" root@$ip:"$FDB_CLUSTER_FILE"
  echo "$ip OK"
done
```

**预期**：本地文件内容形如 `3fsfdp:772afc36@127.0.0.1:4500`，3 台存储节点收到同样内容，权限 644。

> **重要（本环境的现实做法）**：FDB 单机部署且只监听 `127.0.0.1:4500`
> （`ss -lntp | grep 4500` 可确认），因此**只有 dskna004 能真正连上 FDB**。
> 存储节点上的这份文件只是"备用/占位"，本手册里所有需要 FDB 的命令（`init-cluster`、
> `set-config`、`create-target`、`upload-chains`、`user-add`）**一律在 dskna004 执行**。
>
> 若确需在存储节点本地跑管理命令，必须二选一（都要动 FDB，需评估影响）：
> ① 把 `foundationdb.conf` 的 `listen-address` 改为 `0.0.0.0:4500` 并重启 `foundationdb`；
> ② 用 `socat`/ssh 隧道把本地 4500 转发到 dskna004。改完后 cluster 文件里的
> `127.0.0.1` 要换成可达地址。

### 4.5 admin_cli：命令行入口

```bash
source /root/3fs-deploy/env.sh

python3 /root/3fs-deploy/tomlset.py "$CFG/admin_cli.toml" "$ETCDIR/admin_cli.toml" \
  "" "cluster_id" "'$CLUSTER_ID'" \
  "fdb" "clusterFile" "'$FDB_CLUSTER_FILE'" \
  "ib_devices" "device_filter" "$IB_FILTER_META"

cp "$BIN/admin_cli" "$OPT/bin/admin_cli"
chmod +x "$OPT/bin/admin_cli"

# 定义两个便捷函数（写入 env.sh 便于后续 source）
cat >> /root/3fs-deploy/env.sh <<'EOF'

# admin_cli 包装：mgmtd 地址在命令行覆盖（admin_cli.toml 里没有这一项）
CLI()  { /opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
         --config.mgmtd_client.mgmtd_server_addresses "[\"$MGMTD_ADDR\"]" "$@"; }
CLIT() { CLI --config.user_info.token "$(cat /opt/3fs/etc/token.txt 2>/dev/null)" "$@"; }
EOF
source /root/3fs-deploy/env.sh

CLI help 2>&1 | head -5
```

**预期**：打印 `admin_cli` 用法列表。
**失败**：
`too many ibdevices ...` → 必须加 `ib_devices.device_filter`（本环境 dskna004 有 8 个活动 HCA，上限 4）；
`RoutingInfoNotReady` → mgmtd 还没起（下一步）或地址填错（§1.2）。

### 4.6 mgmtd + init-cluster

**目的**：拉起集群管理服务，并把"链表 1 / chunk 1MB / stripe N"写入 FDB（决定文件布局）。

```bash
source /root/3fs-deploy/env.sh

# 1) launcher 配置（FDB 路径 + IB 过滤 + 集群 ID）
python3 /root/3fs-deploy/tomlset.py "$CFG/mgmtd_main_launcher.toml" \
  "$ETCDIR/mgmtd_main_launcher.toml" \
  "" "cluster_id" "'$CLUSTER_ID'" \
  "fdb" "clusterFile" "'$FDB_CLUSTER_FILE'" \
  "kv_engine.fdb" "clusterFile" "'$FDB_CLUSTER_FILE'" \
  "ib_devices" "device_filter" "$IB_FILTER_META"

# 2) app 配置（node_id=1）
python3 /root/3fs-deploy/tomlset.py "$CFG/mgmtd_main_app.toml" "$ETCDIR/mgmtd_main_app.toml" \
  "" "allow_empty_node_id" "false" \
  "" "node_id" "1"

# 3) 安装并启动
cp "$BIN/mgmtd_main" "$OPT/bin/mgmtd_main"
cp "$UNIT/mgmtd_main.service" /usr/lib/systemd/system/
systemctl daemon-reload
systemctl enable mgmtd_main
systemctl restart mgmtd_main

sleep 5
systemctl is-active mgmtd_main
CLI list-nodes
```

**预期**：`list-nodes` 输出 MGMTD 行，状态 `PRIMARY_MGMTD`。

```bash
# 4) 初始化集群（只在第一次执行；重复执行会报 config 已存在）
CLI init-cluster "$INIT_CHAIN_TABLE_ID" "$INIT_CHUNK_SIZE" "$INIT_STRIP_SIZE"
```

**预期**：

```
Init filesystem, root directory layout: chain table ChainTableId(1), chunksize 1048576, stripesize 2
Init config for MGMTD version 1
```

**失败**：

- `init-cluster` 报已存在 → 说明之前初始化过；**改 stripe/chunk 必须清 FDB**（附录 B）。
- 报 `mgmtd not ready` → 先 `systemctl status mgmtd_main` 看日志。

```bash
# 5) 上传 MGMTD 运行时配置（把 monitor 地址下发下去）
python3 /root/3fs-deploy/tomlset.py "$CFG/mgmtd_main.toml" "$ETCDIR/mgmtd_main.toml" \
  "common.monitor.reporters.monitor_collector" "remote_ip" "'$MONITOR_ADDR'"
CLI set-config --type MGMTD --file "$ETCDIR/mgmtd_main.toml"
CLI list-nodes    # ConfigVersion 应变为 UPTODATE
```

### 4.7 meta

```bash
source /root/3fs-deploy/env.sh

# 1) launcher（mgmtd 地址 + IB 过滤）
python3 /root/3fs-deploy/tomlset.py "$CFG/meta_main_launcher.toml" "$ETCDIR/meta_main_launcher.toml" \
  "" "cluster_id" "'$CLUSTER_ID'" \
  "ib_devices" "device_filter" "$IB_FILTER_META" \
  "mgmtd_client" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]"

# 2) app（node_id=100）
python3 /root/3fs-deploy/tomlset.py "$CFG/meta_main_app.toml" "$ETCDIR/meta_main_app.toml" \
  "" "allow_empty_node_id" "false" \
  "" "node_id" "100"

# 3) 运行时配置（FDB + mgmtd + monitor）
python3 /root/3fs-deploy/tomlset.py "$CFG/meta_main.toml" "$ETCDIR/meta_main.toml" \
  "server.mgmtd_client" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]" \
  "server.fdb" "clusterFile" "'$FDB_CLUSTER_FILE'" \
  "server.kv_engine.fdb" "clusterFile" "'$FDB_CLUSTER_FILE'" \
  "common.monitor.reporters.monitor_collector" "remote_ip" "'$MONITOR_ADDR'"

# 4) 安装、下发运行时配置、启动
cp "$BIN/meta_main" "$OPT/bin/meta_main"
cp "$UNIT/meta_main.service" /usr/lib/systemd/system/
systemctl daemon-reload
CLI set-config --type META --file "$ETCDIR/meta_main.toml"
systemctl enable meta_main
systemctl restart meta_main

sleep 5
systemctl is-active meta_main
CLI list-nodes          # 应出现 META node 100，状态 HEARTBEAT_CONNECTED
```

**预期**：`set-config` 输出 `Succeed` + `ConfigVersion 1`；`list-nodes` 出现 `100 META ... HEARTBEAT_CONNECTED ... 1(UPTODATE)`。

> **注意**：本版本 `NodeStatus` 只有 `PRIMARY_MGMTD / HEARTBEAT_CONNECTED / ...`，**没有 `SERVING`**。
> 节点健康态就是 `HEARTBEAT_CONNECTED`；`SERVING` 只用于 target/链（`list-targets` / `list-chains`）。

### 4.8 上传 STORAGE 运行时配置（含 FDP 参数）

**目的**：存储节点的配置**以 mgmtd 下发为准**，本地文件只是参考。这一步决定 3 台存储节点的
`target_paths` 与 `fdp_compaction_stream_id`。

```bash
source /root/3fs-deploy/env.sh

python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main.toml" "$ETCDIR/storage_main.toml" \
  "server.mgmtd" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]" \
  "common.monitor.reporters.monitor_collector" "remote_ip" "'$MONITOR_ADDR'" \
  "server.targets" "target_paths" '["/storage/data3/3fs","/storage/data4/3fs"]' \
  "server.targets" "fdp_compaction_stream_id" "$FDP_COMPACTION_STREAM_ID"

# 校验关键段（应看到 fdp_compaction_stream_id = 2）
awk '/^\[server.targets\]/,/^\[server.targets.storage_target\]/' "$ETCDIR/storage_main.toml" | grep -vE '^\s*$'

CLI set-config --type STORAGE --file "$ETCDIR/storage_main.toml"
```

**预期**：

```
Succeed
ConfigVersion  1
```

（存储节点启动后用 `CLI list-nodes` 确认它们的 `ConfigVersion` 变成 `1(UPTODATE)`，见 §5.4。）

且 `[server.targets]` 段里是：

```toml
target_paths = ["/storage/data3/3fs","/storage/data4/3fs"]
fdp_compaction_stream_id = 2
```

**失败**：`set-config` 报 TOML 解析错误 → 用 `python3 -c "import tomli;tomli.load(open('$ETCDIR/storage_main.toml','rb'))"` 定位。

---

## 5. 阶段 C：存储节点部署（3 台）

> 对应官方 README Step 6。在 **dsksa304 / dsksa305 / dsksa348** 各自执行。
> 前置：§4.4 已把 `fdb.cluster` 推过来、§4.8 已把 STORAGE 配置上传到 mgmtd。

### 5.1 系统调优与数据目录

```bash
source /root/3fs-deploy/env.sh

# chunk engine 异步 IO 需要
cat > /etc/sysctl.d/99-3fs.conf <<'EOF'
fs.aio-max-nr = 67108864
EOF
sysctl -w fs.aio-max-nr=67108864
sysctl -n fs.aio-max-nr            # 期望 67108864

# 数据目录（必须是已挂载的 XFS）
for d in $STORAGE_DATA_DIRS; do
  mnt=${d%/3fs}
  mountpoint -q "$mnt" || { echo "!! $mnt 未挂载"; exit 1; }
  echo "$mnt ← $(findmnt -nrno SOURCE "$mnt")"
  mkdir -p "$d"
done
```

**预期**：`fs.aio-max-nr = 67108864`；`/storage/data3 ← /dev/nvme3n1`、`/storage/data4 ← /dev/nvme4n1`。

> 在线生效，**不需要重启**。若数据盘未挂载：
> ```bash
> mount -o noatime,nodiratime /dev/nvme3n1 /storage/data3
> mount -o noatime,nodiratime /dev/nvme4n1 /storage/data4
> ```
> 建议同时写入 `/etc/fstab`（本环境未写，重启后需手工挂载）。

### 5.2 存储节点的 admin_cli

```bash
source /root/3fs-deploy/env.sh

[[ -f "$FDB_CLUSTER_FILE" ]] || { echo "!! 缺少 $FDB_CLUSTER_FILE，先做 §4.4"; exit 1; }

python3 /root/3fs-deploy/tomlset.py "$CFG/admin_cli.toml" "$ETCDIR/admin_cli.toml" \
  "" "cluster_id" "'$CLUSTER_ID'" \
  "fdb" "clusterFile" "'$FDB_CLUSTER_FILE'" \
  "ib_devices" "device_filter" "$IB_FILTER_STORAGE"

cp "$BIN/admin_cli" "$OPT/bin/admin_cli"; chmod +x "$OPT/bin/admin_cli"
"$OPT/bin/admin_cli" -cfg "$ETCDIR/admin_cli.toml" help >/dev/null && echo "admin_cli 可用"
```

**预期**：`admin_cli 可用`（本地自检，不依赖 mgmtd/FDB）。

> **用途说明**：存储节点上的 admin_cli 只做本地自检/调试。**本手册所有管理命令都在 dskna004
> 执行**（原因见 §4.4：FDB 只监听 127.0.0.1）。若你在此处执行 `CLI list-nodes` 并报 FDB 连接失败，
> 属预期行为，不影响部署。

### 5.3 storage 二进制与配置

```bash
source /root/3fs-deploy/env.sh
NODE_ID=10001      # ← 按主机改：dsksa304=10001 / dsksa305=10002 / dsksa348=10003
```

| 主机 | NODE_ID |
|---|---|
| dsksa304 | 10001 |
| dsksa305 | 10002 |
| dsksa348 | 10003 |

```bash
# 1) launcher（mgmtd 地址 + IB 过滤；存储节点活动 HCA ≤2，用空列表）
python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main_launcher.toml" \
  "$ETCDIR/storage_main_launcher.toml" \
  "" "cluster_id" "'$CLUSTER_ID'" \
  "ib_devices" "device_filter" "$IB_FILTER_STORAGE" \
  "mgmtd_client" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]"

# 2) app（node_id）
python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main_app.toml" "$ETCDIR/storage_main_app.toml" \
  "" "allow_empty_node_id" "false" \
  "" "node_id" "$NODE_ID"

# 3) 本地 runtime 参考文件（真正生效的是 mgmtd 下发的那份，§4.8）
python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main.toml" "$ETCDIR/storage_main.toml" \
  "server.mgmtd" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]" \
  "common.monitor.reporters.monitor_collector" "remote_ip" "'$MONITOR_ADDR'" \
  "server.targets" "target_paths" '["/storage/data3/3fs","/storage/data4/3fs"]' \
  "server.targets" "fdp_compaction_stream_id" "$FDP_COMPACTION_STREAM_ID"

# 4) 安装
cp "$BIN/storage_main" "$OPT/bin/storage_main"      # 若报 Text file busy：先 rm -f 再 cp
cp "$UNIT/storage_main.service" /usr/lib/systemd/system/
systemctl daemon-reload
systemctl enable storage_main
```

**关于 `target_paths` 与 `--disk-index`**：数组下标就是后面 `create-target --disk-index` 的取值，
顺序不能变；`create-target` 会建 `<path>/<targetId>` 子目录（见 `StorageTargets.cc:200`）。

### 5.4 启动并确认拉取到配置

```bash
systemctl restart storage_main
sleep 6
systemctl is-active storage_main
grep -a "fdp_compaction_stream_id" /var/log/3fs/storage_main.log | tail -2
```

**预期**：`active`，且日志出现两处（launcher 与 mgmtd 运行时）：

```
TwoPhaseApplication.h:54 INFO] fdp_compaction_stream_id = 2
ConfigManager.cc:87 INFO] fdp_compaction_stream_id = 2
```

3 台都启动后，回 dskna004 检查：

```bash
CLI list-nodes
```

**预期**：出现 `10001/10002/10003 STORAGE ... ConfigVersion 1(UPTODATE)`。

**失败**：

- 服务起不来 → `journalctl -u storage_main -n 50 --no-pager`；
- `ConfigVersion 0` → mgmtd 上没有 STORAGE 配置，回到 §4.8；
- `disk index exceed` → 配置的 `target_paths` 比用法少（附录 B 会遇到）。

---

## 6. 阶段 D：集群收尾（dskna004）

> 对应官方 README Step 7–8。全部在 **dskna004**。

### 6.1 创建用户并保存 token

**原理**：3FS 的 token 内编码了 uid（`UserStore::addUser` 会调 `ensureTokenMatchUid()`），
**不能自己随便生成**，必须让服务端生成后落盘。

```bash
source /root/3fs-deploy/env.sh

# 已有有效 token 就跳过
if [[ -f "$TOKEN_FILE" ]] && CLIT current-user >/dev/null 2>&1; then
  echo "token 有效，跳过"
else
  out=$(CLI "user-add --root --admin 0 root") || { echo "$out"; exit 1; }
  echo "$out"
  # 输出形如: Token              AAAWX0nv8QADbKIr2wCHxy42(Expired at N/A)
  awk '/^Token/ {print $2}' <<<"$out" | sed 's/(Expired.*//' > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  CLIT current-user        # 期望 Uid 0 / Token 打印
fi
```

**预期**：

```
Uid     0
Gid     0
Groups  [0]
Token   AAAWX0...      # 已写入 /opt/3fs/etc/token.txt（权限 600）
```

**失败**：`kExists` → 用户已存在但 token 丢失（无法找回），需清 FDB 重建或人工处理。

### 6.2 创建 6 个 storage target

**规则**：每盘 1 个 target，`--disk-index` 对应 `target_paths` 下标；每条链 3 个 target
（HEAD/MIDDLE/TAIL 分别在某台节点上）；`--use-new-chunk-engine` 是 FDP 生效的前提。

```bash
source /root/3fs-deploy/env.sh

CLIT create-target --node-id 10001 --disk-index 0 --target-id 101000100101 --chain-id 900100001 --use-new-chunk-engine
CLIT create-target --node-id 10002 --disk-index 0 --target-id 101000200101 --chain-id 900100001 --use-new-chunk-engine
CLIT create-target --node-id 10003 --disk-index 0 --target-id 101000300101 --chain-id 900100001 --use-new-chunk-engine
CLIT create-target --node-id 10001 --disk-index 1 --target-id 101000100201 --chain-id 900200001 --use-new-chunk-engine
CLIT create-target --node-id 10002 --disk-index 1 --target-id 101000200201 --chain-id 900200001 --use-new-chunk-engine
CLIT create-target --node-id 10003 --disk-index 1 --target-id 101000300201 --chain-id 900200001 --use-new-chunk-engine

CLIT list-targets
```

**预期**：6 行 `Create target 101000100101 on disk 0 of 10001 succeeded`；
`list-targets` 显示 6 个 target，此时 `PublicState=SERVING`、`LocalState=OFFLINE`
（还没上传链，属正常），§6.3 上传链后转为 `SERVING/UPTODATE`。

命名规律（附录 B 会用）：`1010<节点序号 1-3>00<盘序号+1>01`，例如 node3、disk2 → `101000300301`。

### 6.3 上传链与链表

```bash
source /root/3fs-deploy/env.sh

cat > "$ETCDIR/generated_chains.csv" <<'EOF'
ChainId,TargetId,TargetId,TargetId
900100001,101000100101,101000200101,101000300101
900200001,101000100201,101000200201,101000300201
EOF

cat > "$ETCDIR/generated_chain_table.csv" <<'EOF'
ChainId
900100001
900200001
EOF

CLIT upload-chains "$ETCDIR/generated_chains.csv"
CLIT upload-chain-table --desc "$CLUSTER_ID" 1 "$ETCDIR/generated_chain_table.csv"

CLIT list-chains
CLIT list-chain-tables
```

**预期**：

```
Upload 2 chains succeeded
Upload ChainTableId(1) of ChainTableVersion(1) succeeded

ChainId    ... Status   Target(3 列均 SERVING-UPTODATE)
900100001  ... SERVING  101000100101(SERVING-UPTODATE) 101000200101(...) 101000300101(...)
900200001  ... SERVING  ...

ChainTableId  ChainTableVersion  ChainCount  ReplicaCount  Desc
1             1                  2           3             stage
```

**若 target 仍是 OFFLINE**：等 10–30 秒（storage 心跳刷新）；或 `systemctl restart storage_main`。

### 6.4 FUSE 客户端挂载

```bash
source /root/3fs-deploy/env.sh

# 1) launcher：挂载点 + token 文件 + IB 过滤 + mgmtd
python3 /root/3fs-deploy/tomlset.py "$CFG/hf3fs_fuse_main_launcher.toml" \
  "$ETCDIR/hf3fs_fuse_main_launcher.toml" \
  "" "cluster_id" "'$CLUSTER_ID'" \
  "" "mountpoint" "'$MOUNT_POINT'" \
  "" "token_file" "'$TOKEN_FILE'" \
  "ib_devices" "device_filter" "$IB_FILTER_META" \
  "mgmtd_client" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]"

# 2) runtime：mgmtd + monitor
python3 /root/3fs-deploy/tomlset.py "$CFG/hf3fs_fuse_main.toml" "$ETCDIR/hf3fs_fuse_main.toml" \
  "mgmtd" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]" \
  "common.monitor.reporters.monitor_collector" "remote_ip" "'$MONITOR_ADDR'"

# 3) 安装并挂载
cp "$BIN/hf3fs_fuse_main" "$OPT/bin/hf3fs_fuse_main"
cp "$UNIT/hf3fs_fuse_main.service" /usr/lib/systemd/system/
systemctl daemon-reload
CLI set-config --type FUSE --file "$ETCDIR/hf3fs_fuse_main.toml"
mkdir -p "$MOUNT_POINT"
systemctl enable hf3fs_fuse_main
systemctl restart hf3fs_fuse_main

sleep 5
mountpoint "$MOUNT_POINT" && mount | grep 3fs
```

**预期**：

```
/3fs/stage is a mountpoint
hf3fs.stage on /3fs/stage type fuse.hf3fs (rw,nosuid,nodev,relatime,...,allow_other,...)
```

**失败**：
`mountpoint` 不成立 → `journalctl -u hf3fs_fuse_main -n 50`：
token 无效（重新 §6.1）、mgmtd 地址错（§1.2）、链未 SERVING（§6.3）。

---

## 7. 阶段 E：验证

### 7.1 基本读写（FUSE）

```bash
mkdir -p /3fs/stage/test
dd if=/dev/urandom of=/3fs/stage/test/smoke bs=1M count=512 status=none
sync
md5sum /3fs/stage/test/smoke
dd if=/3fs/stage/test/smoke of=/tmp/smoke.copy bs=1M status=none
md5sum /tmp/smoke.copy
rm -f /3fs/stage/test/smoke /tmp/smoke.copy
```

**预期**：两个 md5 一致。若 `Input/output error` → 99% 是 §1.3 的 stripe > 链数，
看 `grep "have only" /var/log/3fs/hf3fs_meta_main.log`。

### 7.2 FDP 三层验证

**第 1 层：客户端 ioctl 透传**

```bash
python3 - <<'EOF'
import fcntl, os, struct
HF = (3 << 30) | (16 << 16) | (0x68 << 8) | 16      # HF3FS_IOC_WRITE_STREAM
fd = os.open("/3fs/stage/test/fdp_probe", os.O_RDWR | os.O_CREAT, 0o644)
for op, sid in ((1, 0), (4, 3), (2, 0)):            # GET_MAX / SET 3 / GET
    ws = struct.pack("IIII", op, sid, 0, 0)
    print(op, struct.unpack("IIII", fcntl.ioctl(fd, HF, ws)))
os.close(fd); os.unlink("/3fs/stage/test/fdp_probe")
EOF
```

**预期**：

```
1 (1, 0, 255, 0)     # GET_MAX=255 是 FUSE 层固定上限（内核 u8），真实上限在存储侧
4 (4, 3, 0, 0)       # SET 成功
2 (2, 3, 255, 0)     # GET 回读=3
```

**第 2 层：存储侧确实收到 stream**

```bash
# dskna004 写 1GB，指定 stream 7
python3 - <<'EOF'
import fcntl, os, struct
HF = (3 << 30) | (16 << 16) | (0x68 << 8) | 16
fd = os.open("/3fs/stage/test/fdp7.bin", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
fcntl.ioctl(fd, HF, struct.pack("IIII", 4, 7, 0, 0))
buf = b"\xa5" * (4 << 20)
for _ in range(256): os.write(fd, buf)
os.fsync(fd); os.close(fd); os.unlink("/3fs/stage/test/fdp7.bin")
print("写入 1GB with stream 7")
EOF

# 任一台存储节点
journalctl -u storage_main --no-pager | grep -a "FDP_DEBUG" | tail -5
```

**预期**（链路自下而上）：

```
[FDP_DEBUG] SERVER_WRITE: received streamId=7, chunkId=...
[FDP_DEBUG] SERVER_UPDATE_JOB: streamId=7 ...
[FDP_DEBUG] CHUNK_ENGINE_UPDATE: streamId=7 ...
[FDP_DEBUG] CLUSTER_PWRITE: streamId=7 ...
```

**第 3 层：内核/NVMe 层的写命令确实带 stream**

```bash
# 存储节点：写前计数 → 写 → 写后计数（dmesg 环形缓冲会滚动，必须马上对比）
dmesg | grep -o "write with stream [0-9]*" | awk '{print $4}' | sort -n | uniq -c
# ... 执行上面的 1GB 写入 ...
dmesg | grep -o "write with stream [0-9]*" | awk '{print $4}' | sort -n | uniq -c
```

**预期**：`stream 7` 的计数明显增长（实测三节点合计 5000+ 条）。

**关于“放置是否真的生效”**：`XFS GET_MAX = 14`，且 NVMe 命令的 placement 字段可实测：

| 客户端 SET | NVMe `dsmgmt` | PLID |
|---|---|---|
| 不设（0） | `0` | 无 placement |
| stream 3 | `131072`（`0x20000`） | **PLID 2** |
| stream 7 | `393216`（`0x60000`） | **PLID 6** |

抓法（在存储节点执行，`nvme_setup_cmd` 事件里 `cdw10[24]` 的第 5 个 DWORD 即 CDW14/dsmgmt）：

```bash
T=/sys/kernel/tracing
echo > $T/trace; echo 1 > $T/events/nvme/nvme_setup_cmd/enable
# ... 执行上面的 1GB 写入 ...
echo 0 > $T/events/nvme/nvme_setup_cmd/enable
grep -E "nvme3c|nvme4c" $T/trace | grep -o "dsmgmt=[0-9a-fx]*, reftag" | sort | uniq -c
```

> 早期文档曾误报 `GET_MAX=0`：原因是探测脚本 `fcntl.ioctl(fd, CMD, ws)` 后读了入参 `ws`
> （`bytes` 不可变，结果在返回值里）。`01_precheck.sh` / `03_setup_storage.sh` 已修正。

**第 4 层（可选）：compaction 解析日志**

```bash
journalctl -u storage_main --no-pager | grep -a "\[FDP\]"
# 可用: [FDP] compaction stream resolved: configured=2 max=14 resolved=2
# 回退: [FDP] compaction stream fell back to default placement: configured=2 max=0
```

触发条件：某分配组内废弃 chunk 累计 > `max_reserved_chunks`（默认 1GB），即"写入→删除"几 GB 后
由 `AllocateWorker` 自动拉起。

### 7.3 监控链路

```bash
clickhouse-client --password "$CH_PASSWD" -q "SELECT count() FROM \`3fs\`.counters"
clickhouse-client --password "$CH_PASSWD" -q "SELECT count() FROM \`3fs\`.distributions"
```

**预期**：两个数字都 > 0 且随时间增长。
**失败**：`/var/log/3fs/monitor_collector_main.log` 里
`unsupported compression method 144` → 回到 §4.1 的 LZ4 修复。

### 7.4 集群状态一览

```bash
CLI list-nodes            # 1 / 100 / 10001-10003 全在，非 DISABLED
CLIT list-targets         # 6 行 SERVING/UPTODATE
CLIT list-chains          # 2 条 SERVING
CLIT list-chain-tables    # 1 / 1 / 2 / 3 / stage
mount | grep 3fs
```

---

## 8. 故障速查表

| 现象 | 根因 | 处理 |
|---|---|---|
| `6004 MgmtdClient::RoutingInfoNotReady` | RDMA 地址填了 IPoIB | 改管理网 IP（§1.2） |
| `too many ibdevices` | 缺 `device_filter` | dskna004 设 `["mlx5_0".."mlx5_3"]` |
| mgmtd 起不来 / `list-nodes` 空 | launcher 配置错；或 FDB 不可用 | 看 `journalctl -u mgmtd_main`；§4.3 |
| `init-cluster` 报已存在 | 之前初始化过 | 改参数必须清 FDB（§附录 B） |
| 写文件 `Input/output error` + meta 日志 `have only N chains` | `stripeSize > 链数` | 重建 init-cluster，stripe ≤ 链数（§1.3） |
| `create-target` 报 `disk index exceed` | `target_paths` 项数不足 | 补 `target_paths` 并 `set-config` + 重启 storage |
| storage `ConfigVersion 0` | mgmtd 没有 STORAGE 配置 | §4.8 |
| target 一直 `OFFLINE` | 链未上传 / 心跳未刷新 | §6.3，等 30s 或重启 storage |
| 挂载失败 | token 无效 / 链未 SERVING | §6.1 / §6.3 |
| ClickHouse 表空 + `method 144` | 网络压缩 ZSTD | §4.1 |
| `dd oflag=direct` 失败 | FUSE 不保证支持 O_DIRECT | 用普通 `dd` |
| 日志无 `[FDP]` | compaction 未触发（需 >1GB 废弃 chunk） | §7.2 第 4 层 |

---

## 附录 A：把 FDP_COMPACTION_STREAM_ID 改为 0

> **目的**：关闭 chunk engine compaction 的 FDP 分流（做 WAF 对照实验，或设备不支持 FDP 时）。
> **关键点**：该参数是 **startup-loaded**（官方模板注释明确写 "changing it requires a storage
> service restart"），`set-config` 只改变"下一次启动要用的配置"，**必须重启 storage_main 才生效**。

### A.1 影响面

| stream | 改前 | 改后 |
|---|---|---|
| 1 | 空置 | 空置 |
| 2 | compaction 复制 | 不再使用（compaction 走默认放置） |
| 3.. | 业务（LMCache） | 不变 |

行为差异（`chunk_engine/src/core/engine.rs`）：

- `fdp_compaction_stream_id = 0` → 初始化时 `compaction_stream_id = 0`，
  **不探测 GET_MAX、不打印 `[FDP]` 日志**，compaction 写入不调 `FS_IOC_WRITE_STREAM`；
- `= 2` → 首次 compaction 时探测，成功打印 `resolved`，失败打印 `fell back`。

### A.2 完整步骤（dskna004 + 3 台存储）

**Step 1【dskna004】改配置并上传**

```bash
source /root/3fs-deploy/env.sh

# 方式一：改环境变量后重新生成（推荐，便于回滚）
export FDP_COMPACTION_STREAM_ID=0
python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main.toml" "$ETCDIR/storage_main.toml" \
  "server.mgmtd" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]" \
  "common.monitor.reporters.monitor_collector" "remote_ip" "'$MONITOR_ADDR'" \
  "server.targets" "target_paths" '["/storage/data3/3fs","/storage/data4/3fs"]' \
  "server.targets" "fdp_compaction_stream_id" "$FDP_COMPACTION_STREAM_ID"

# 确认写的是 0
grep -n "fdp_compaction_stream_id" "$ETCDIR/storage_main.toml"

# 上传到 mgmtd（运行时配置）
CLI set-config --type STORAGE --file "$ETCDIR/storage_main.toml"
```

**预期**：`Succeed` + `ConfigVersion 2`（版本号递增）。

**Step 2【3 台存储节点】同步本地参考文件 + 重启**

> 本地 `storage_main.toml` 不参与运行（运行时以 mgmtd 下发为准），但为保持一致性建议同步。
> 若不想手工改，可跳过本地文件，**只做重启**。

```bash
# 在 dskna004 上批量执行（含本地文件更新 + 重启）
source /root/3fs-deploy/env.sh
for ip in $STORAGE_HOSTS; do
  echo "== $ip"
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip '
    sed -i "s/^fdp_compaction_stream_id = .*/fdp_compaction_stream_id = 0/" /opt/3fs/etc/storage_main.toml
    systemctl restart storage_main
    sleep 6
    systemctl is-active storage_main
  '
done
```

**预期**：3 台都返回 `active`。

> 单台重启不会中断集群（RF=3，其余 2 副本继续服务）；重启后该节点 target 会短暂 `SYNCING`，
> 约 30–60 秒回到 `SERVING/UPTODATE`。

**Step 3 验证生效**

```bash
# 1) 进程实际加载的值（两处都应为 0）
for ip in $STORAGE_HOSTS; do
  echo "== $ip"
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip \
    'grep -a "fdp_compaction_stream_id" /var/log/3fs/storage_main.log | tail -2'
done

# 2) 集群恢复
CLI list-nodes
CLIT list-targets          # 6 行 SERVING/UPTODATE

# 3) 不再出现 [FDP] 解析日志（0 不探测）
journalctl -u storage_main --no-pager | grep -a "\[FDP\]" || echo "无 [FDP] 日志（符合 =0 预期）"
```

**预期**：日志两行均为 `fdp_compaction_stream_id = 0`；target 全部 SERVING；无 `[FDP]` 行。

**Step 4 回滚到 2**

```bash
# dskna004
source /root/3fs-deploy/env.sh
export FDP_COMPACTION_STREAM_ID=2
python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main.toml" "$ETCDIR/storage_main.toml" \
  "server.mgmtd" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]" \
  "common.monitor.reporters.monitor_collector" "remote_ip" "'$MONITOR_ADDR'" \
  "server.targets" "target_paths" '["/storage/data3/3fs","/storage/data4/3fs"]' \
  "server.targets" "fdp_compaction_stream_id" "$FDP_COMPACTION_STREAM_ID"
CLI set-config --type STORAGE --file "$ETCDIR/storage_main.toml"

# 3 台存储：改回本地文件并重启
for ip in $STORAGE_HOSTS; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip '
    sed -i "s/^fdp_compaction_stream_id = .*/fdp_compaction_stream_id = 2/" /opt/3fs/etc/storage_main.toml
    systemctl restart storage_main'
done
```

### A.3 注意事项

1. **不要只 `set-config` 不重启**：参数不会生效，`list-nodes` 仍显示新 `ConfigVersion`，容易误判。
2. **不要热更新**：`hot-update-config` 对该参数无效（startup-loaded）。
3. 若同时要改 `target_paths`（附录 B），两者一起改、一次重启。
4. 重启后 1–2 分钟内 `list-targets` 出现 `SYNCING` 属正常。

---

## 附录 B：三盘拓扑（9 target / 3 链 / RF=3）

> **目标**：每台存储 3 块 SSD、每盘 1 个 target、集群 9 个 target、3 条链（每链 3 副本）、`stripeSize=3`。
> **代价**：`init-cluster` 的 stripe 从 2 变 3 **不可在线修改**，必须清 FDB 全量重建（现有数据全部丢失）。

### B.0 先确认物理条件（**这一步决定你能不能做**）

```bash
# 在 3 台存储节点分别执行
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,MODEL
zpool list 2>/dev/null
sudo zfs list 2>/dev/null | head
```

**本环境实测结果（务必先读）**：

| 设备 | 现状 | 能否给 3FS |
|---|---|---|
| `nvme0n1` | 系统盘（ext4 `/` + `/boot/efi`） | ✗ |
| `nvme1n1` | 两个 `zfs_member` 分区（7T+7T） | ✗ |
| `nvme2n1` | ZFS 池 `ost00pool`，**9.97TB 已用**（Lustre OST） | ✗（除决意销毁） |
| `nvme3n1` | XFS `/storage/data3` | ✓ 已用 |
| `nvme4n1` | XFS `/storage/data4` | ✓ 已用 |

**结论：当前 3 台机器都没有第三块空闲 SSD。** 因此附录 B 提供两条路径：

- **B.1 真实三盘**：新增/腾出一块盘（推荐，符合"每台 3 个 SSD"要求）；
- **B.2 逻辑三 target**：不加盘，在现有 2 块盘上放 3 个 target（共用 chunk engine），
  用于先跑通"3 链 × RF=3"的代码路径，但**不是**物理三盘。

### B.1 路径一：真实三盘（9 target / 3 链）

#### B.1.1 准备第三块盘

**⚠ 危险**：以下操作会**销毁目标盘上所有数据**。先确认盘上没有在用数据（Lustre/ZFS/业务）。

```bash
# 1) 确认候选盘无挂载、无 zfs 池成员、无业务进程占用
DEV=/dev/nvme5n1                      # ← 按实际替换（新增盘通常是 nvme5n1 起）
lsblk "$DEV"
findmnt -S "$DEV" || echo "无挂载"
zpool status 2>/dev/null | grep -i "$(basename $DEV)" && echo "!! 该盘属于 zpool，禁止操作"
lsof "$DEV" 2>/dev/null | head

# 2) 若确认可清空：清掉旧分区表/文件系统签名
wipefs -a "$DEV"                      # ⚠ 破坏性

# 3) 建 XFS 并挂载
mkfs.xfs -f "$DEV"
mkdir -p /storage/data5
mount -o noatime,nodiratime "$DEV" /storage/data5
findmnt -no SOURCE,TARGET,OPTIONS /storage/data5

# 4) 写入 fstab（用 UUID，避免设备名变化）
UUID=$(blkid -s UUID -o value "$DEV")
echo "UUID=$UUID /storage/data5 xfs noatime,nodiratime 0 0" >> /etc/fstab
tail -1 /etc/fstab
```

**预期**：`/storage/data5` 挂载成功，`findmnt` 显示 `noatime,nodiratime`。

> 3 台存储节点都要做同样的操作（每台一块新盘）。

#### B.1.2 修改拓扑参数（dskna004）

```bash
source /root/3fs-deploy/env.sh

# 新的拓扑参数
export STORAGE_DATA_DIRS_3="/storage/data3/3fs /storage/data4/3fs /storage/data5/3fs"
export INIT_STRIP_SIZE=3              # 链数 3 ⇒ stripe 必须 ≤ 3
export FDP_COMPACTION_STREAM_ID=2     # 不变

# 同步到 env.sh，避免后续 shell 丢失
sed -i "s#^export STORAGE_DATA_DIRS=.*#export STORAGE_DATA_DIRS=\"$STORAGE_DATA_DIRS_3\"#" /root/3fs-deploy/env.sh
sed -i "s#^export INIT_STRIP_SIZE=.*#export INIT_STRIP_SIZE=$INIT_STRIP_SIZE#" /root/3fs-deploy/env.sh
source /root/3fs-deploy/env.sh
```

生成新的 STORAGE 运行时配置（`target_paths` 三项，顺序必须稳定）：

```bash
python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main.toml" "$ETCDIR/storage_main.toml" \
  "server.mgmtd" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]" \
  "common.monitor.reporters.monitor_collector" "remote_ip" "'$MONITOR_ADDR'" \
  "server.targets" "target_paths" '["/storage/data3/3fs","/storage/data4/3fs","/storage/data5/3fs"]' \
  "server.targets" "fdp_compaction_stream_id" "$FDP_COMPACTION_STREAM_ID"

awk '/^\[server.targets\]/,/^\[server.targets.storage_target\]/' "$ETCDIR/storage_main.toml" | grep -vE '^\s*$'
```

**预期**：

```toml
target_paths = ["/storage/data3/3fs","/storage/data4/3fs","/storage/data5/3fs"]
fdp_compaction_stream_id = 2
```

#### B.1.3 全量重建（清 FDB + 重新 init-cluster）

**⚠ 危险**：会清空集群元数据（所有文件消失），存储盘上的 chunk 数据也要清掉。

```bash
source /root/3fs-deploy/env.sh

# 1) 停 3FS 服务（FUSE → meta → mgmtd）
systemctl stop hf3fs_fuse_main meta_main mgmtd_main

# 2) 停存储服务并清 target 目录（3 台）
for ip in $STORAGE_HOSTS; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip '
    systemctl stop storage_main
    rm -rf /storage/data3/3fs/* /storage/data4/3fs/* /storage/data5/3fs/*
    echo "$(hostname) 清空完成"'
done

# 3) 清 FDB（单机环境）
systemctl stop foundationdb
cp -a /var/lib/foundationdb/data/4500 /var/lib/foundationdb/data/4500.bak.$(date +%s) 2>/dev/null || true
rm -rf /var/lib/foundationdb/data/4500/*
systemctl start foundationdb
sleep 3
fdbcli --exec "configure new single ssd"
sleep 5
fdbcli --exec "status minimal"        # The database is available.

# 4) 重新生成 fdb.cluster 并分发
desc=$(fdbcli --exec "status minimal" 2>/dev/null | grep -oE '[A-Za-z0-9_]+:[A-Za-z0-9]+@[0-9.]+:4500' | head -1)
printf '%s\n' "$desc" > "$FDB_CLUSTER_FILE"; chmod 644 "$FDB_CLUSTER_FILE"
for ip in $STORAGE_HOSTS; do
  sshpass -p '!@345Qwert' scp -o StrictHostKeyChecking=no "$FDB_CLUSTER_FILE" root@$ip:"$FDB_CLUSTER_FILE"
done

# 5) 起 mgmtd 并用新 stripe 初始化
systemctl start mgmtd_main
sleep 5
CLI list-nodes
CLI init-cluster "$INIT_CHAIN_TABLE_ID" "$INIT_CHUNK_SIZE" "$INIT_STRIP_SIZE"
```

**预期**：

```
Init filesystem, root directory layout: chain table ChainTableId(1), chunksize 1048576, stripesize 3
```

> 若你只是改 stripe 而不清 FDB，`init-cluster` 会报"已存在"，且 root layout 仍是 stripe=2，
> 后续 3 链也不会被用满 —— 所以必须走这套重置流程。

```bash
# 6) 上传 MGMTD / META / STORAGE 配置（内容与 §4.6/4.7/4.8 相同）
CLI set-config --type MGMTD  --file "$ETCDIR/mgmtd_main.toml"
systemctl start meta_main
CLI set-config --type META   --file "$ETCDIR/meta_main.toml"
CLI set-config --type STORAGE --file "$ETCDIR/storage_main.toml"
sleep 5
CLI list-nodes
```

**预期**：mgmtd、meta 均在；3 台存储稍后启动。

#### B.1.4 逐台改 storage 本地配置并启动（3 台）

```bash
# 在每台存储节点执行（NODE_ID 见 §5.3）
source /root/3fs-deploy/env.sh
NODE_ID=10001        # dsksa304；dsksa305=10002；dsksa348=10003

python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main_launcher.toml" \
  "$ETCDIR/storage_main_launcher.toml" \
  "" "cluster_id" "'$CLUSTER_ID'" \
  "ib_devices" "device_filter" "$IB_FILTER_STORAGE" \
  "mgmtd_client" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]"

python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main_app.toml" "$ETCDIR/storage_main_app.toml" \
  "" "allow_empty_node_id" "false" "" "node_id" "$NODE_ID"

python3 /root/3fs-deploy/tomlset.py "$CFG/storage_main.toml" "$ETCDIR/storage_main.toml" \
  "server.mgmtd" "mgmtd_server_addresses" "[\"$MGMTD_ADDR\"]" \
  "common.monitor.reporters.monitor_collector" "remote_ip" "'$MONITOR_ADDR'" \
  "server.targets" "target_paths" '["/storage/data3/3fs","/storage/data4/3fs","/storage/data5/3fs"]' \
  "server.targets" "fdp_compaction_stream_id" "$FDP_COMPACTION_STREAM_ID"

systemctl start storage_main
sleep 6
grep -a "fdp_compaction_stream_id\|target_paths" /var/log/3fs/storage_main.log | tail -3
```

**预期**：日志显示 `target_paths = ['/storage/data3/3fs', '/storage/data4/3fs', '/storage/data5/3fs']`。

#### B.1.5 建 9 个 target + 3 条链

```bash
source /root/3fs-deploy/env.sh

# 9 个 target：node N(1-3) × disk D(0-2)，targetId = 1010N0D01
for n in 1 2 3; do
  node=$((10000 + n))
  for d in 0 1 2; do
    tid=$(printf "101000%d00%d01" "$n" "$((d + 1))")
    cid=$(printf "900%d00001" "$((d + 1))")
    CLIT create-target --node-id "$node" --disk-index "$d" --target-id "$tid" --chain-id "$cid" --use-new-chunk-engine
  done
done

CLIT list-targets      # 期望 9 行
```

**预期 target id 表**：

| node | disk 0 | disk 1 | disk 2 |
|---|---|---|---|
| 10001（dsksa304） | 101000100101 | 101000100201 | 101000100301 |
| 10002（dsksa305） | 101000200101 | 101000200201 | 101000200301 |
| 10003（dsksa348） | 101000300101 | 101000300201 | 101000300301 |

链：`900100001`(disk0 三节点)、`900200001`(disk1)、`900300001`(disk2)。

```bash
cat > "$ETCDIR/generated_chains.csv" <<'EOF'
ChainId,TargetId,TargetId,TargetId
900100001,101000100101,101000200101,101000300101
900200001,101000100201,101000200201,101000300201
900300001,101000100301,101000200301,101000300301
EOF

cat > "$ETCDIR/generated_chain_table.csv" <<'EOF'
ChainId
900100001
900200001
900300001
EOF

CLIT upload-chains "$ETCDIR/generated_chains.csv"
CLIT upload-chain-table --desc "$CLUSTER_ID" 1 "$ETCDIR/generated_chain_table.csv"

CLIT list-chains
CLIT list-chain-tables
```

**预期**：

```
Upload 3 chains succeeded
Upload ChainTableId(1) of ChainTableVersion(1) succeeded

ChainTableId  ChainTableVersion  ChainCount  ReplicaCount  Desc
1             1                  3           3             stage
```

#### B.1.6 FUSE 重新挂载与验证

```bash
# dskna004
systemctl restart hf3fs_fuse_main
sleep 5
mountpoint /3fs/stage || { journalctl -u hf3fs_fuse_main -n 40; }

CLI list-nodes
CLIT list-targets
CLIT list-chains
```

**验证 1：三条链都被写入**

```bash
# 写 3GB（stripe=3 会把 chunk 轮转到 3 条链）
dd if=/dev/urandom of=/3fs/stage/test/stripe3.bin bs=1M count=3072 status=none
sync
CLIT list-targets          # 9 个 target 的 UsedSize 应都有增长（约 1GB/盘）
md5sum /3fs/stage/test/stripe3.bin
rm -f /3fs/stage/test/stripe3.bin
```

**验证 2：布局 stripe 已生效**

```bash
# meta 日志不应再出现 "have only N chains"
grep -a "have only" /var/log/3fs/hf3fs_meta_main.log || echo "无分配错误"
```

**验证 3：FDP 链路不变**

重复 §7.2 的三层验证（FUSE ioctl → `[FDP_DEBUG]` → dmesg `write with stream`）。

**验证 4：监控**

```bash
clickhouse-client --password "$CH_PASSWD" -q "SELECT count() FROM \`3fs\`.counters"
```

### B.2 路径二：无第三块盘时的等效 9 target（逻辑三 target）

**适用**：暂时拿不到第三块盘，但需要先把 `stripe=3 / 3 链 / RF=3` 的代码路径跑通。

**原理**：`create-target` 的路径是 `target_paths[diskIndex]/<targetId>`（`StorageTargets.cc:200`），
**同一 `disk-index` 可以创建多个 target**（不同 targetId → 不同子目录），它们共用一个 chunk engine。
因此 2 块盘可以放 3 个 target：

| node | disk-index 0（/storage/data3） | disk-index 1（/storage/data4） |
|---|---|---|
| 10001 | 101000100101、101000100102 | 101000100201 |
| 10002 | 101000200101、101000200102 | 101000200201 |
| 10003 | 101000300101、101000300102 | 101000300201 |

→ 9 个 target，仍可组成 3 条链（每链 3 节点各 1 个 target）：

- 链 1：`...00101`（3 节点）
- 链 2：`...00102`（3 节点，同在 data3 上）
- 链 3：`...00201`（3 节点）

步骤与 B.1 完全相同，只是：

1. **不需要**第三块盘与 `/storage/data5`；
2. `target_paths` 仍是两项；
3. `INIT_STRIP_SIZE=3`（三条链）；
4. `create-target` 的 9 条命令为：

```bash
CLIT create-target --node-id 10001 --disk-index 0 --target-id 101000100101 --chain-id 900100001 --use-new-chunk-engine
CLIT create-target --node-id 10002 --disk-index 0 --target-id 101000200101 --chain-id 900100001 --use-new-chunk-engine
CLIT create-target --node-id 10003 --disk-index 0 --target-id 101000300101 --chain-id 900100001 --use-new-chunk-engine
CLIT create-target --node-id 10001 --disk-index 0 --target-id 101000100102 --chain-id 900200001 --use-new-chunk-engine
CLIT create-target --node-id 10002 --disk-index 0 --target-id 101000200102 --chain-id 900200001 --use-new-chunk-engine
CLIT create-target --node-id 10003 --disk-index 0 --target-id 101000300102 --chain-id 900200001 --use-new-chunk-engine
CLIT create-target --node-id 10001 --disk-index 1 --target-id 101000100201 --chain-id 900300001 --use-new-chunk-engine
CLIT create-target --node-id 10002 --disk-index 1 --target-id 101000200201 --chain-id 900300001 --use-new-chunk-engine
CLIT create-target --node-id 10003 --disk-index 1 --target-id 101000300201 --chain-id 900300001 --use-new-chunk-engine
```

链 CSV 对应：

```csv
ChainId,TargetId,TargetId,TargetId
900100001,101000100101,101000200101,101000300101
900200001,101000100102,101000200102,101000300102
900300001,101000100201,101000200201,101000300201
```

**局限（必须知情）**：链 1 与链 2 的 target 物理上都在同一块 SSD（`/storage/data3`），
因此**不具备"单盘故障只降一个副本"的能力**，也会让该盘的写放大翻倍。仅用于功能验证。

### B.3 参数变更对照表（两种路径通用）

| 参数 | 当前 | 三盘（B.1） | 逻辑三 target（B.2） |
|---|---|---|---|
| `target_paths` | 2 项 | **3 项**（加 `/storage/data5/3fs`） | 2 项不变 |
| `init-cluster` stripe | 2 | **3** | **3** |
| 每节点 target 数 | 2 | 3 | 3 |
| 集群 target 总数 | 6 | **9** | **9** |
| 链数 / RF | 2 / 3 | **3 / 3** | **3 / 3** |
| `fdp_compaction_stream_id` | 2 | 2 | 2 |
| 是否需要清 FDB | — | **是**（stripe 变更） | **是** |
| `storage_main.toml` 本地文件 | 2 项 | 3 项 | 2 项 |

改完后的自检清单：

```bash
CLIT list-targets      | grep -c SERVING      # 9
CLIT list-chains       | grep -c SERVING      # 3
CLIT list-chain-tables                        # ChainCount=3 ReplicaCount=3
echo $INIT_STRIP_SIZE                         # 3
grep fdp_compaction_stream_id $ETCDIR/storage_main.toml   # 2
```

---

## 附录 C：配置与参数速查

### C.1 配置覆盖键一览（照抄即可核对）

| 文件 | 段 | 键 | 值 |
|---|---|---|---|
| `monitor_collector_main.toml` | `common` | `cluster_id` | `'stage'` |
| | `common.ib_devices` | `device_filter` | `["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]` |
| | `server.monitor_collector.reporter` | `type` | `'clickhouse'` |
| | `...reporter.clickhouse` | `db/host/port/user/passwd` | `'3fs'/'127.0.0.1'/'9000'/'default'/'samsung'` |
| `admin_cli.toml` | 根 | `cluster_id` | `'stage'` |
| | `fdb` | `clusterFile` | `'/opt/3fs/etc/fdb.cluster'` |
| | `ib_devices` | `device_filter` | 元数据节点 4 个 / 存储 `[]` |
| `mgmtd_main_launcher.toml` | 根 | `cluster_id` | `'stage'` |
| | `fdb` / `kv_engine.fdb` | `clusterFile` | `'/opt/3fs/etc/fdb.cluster'` |
| | `ib_devices` | `device_filter` | 4 个 mlx5 |
| `mgmtd_main_app.toml` | 根 | `node_id` | `1` |
| `mgmtd_main.toml` | `common.monitor.reporters.monitor_collector` | `remote_ip` | `'172.16.12.210:10000'` |
| `meta_main_launcher.toml` | `mgmtd_client` | `mgmtd_server_addresses` | `["RDMA://172.16.12.210:8000"]` |
| `meta_main_app.toml` | 根 | `node_id` | `100` |
| `meta_main.toml` | `server.mgmtd_client` | `mgmtd_server_addresses` | 同上 |
| | `server.fdb` / `server.kv_engine.fdb` | `clusterFile` | `'/opt/3fs/etc/fdb.cluster'` |
| `storage_main_launcher.toml` | `mgmtd_client` | `mgmtd_server_addresses` | 同上 |
| | `ib_devices` | `device_filter` | `[]` |
| `storage_main_app.toml` | 根 | `node_id` | `10001/10002/10003` |
| `storage_main.toml` | `server.mgmtd` | `mgmtd_server_addresses` | 同上 |
| | `server.targets` | `target_paths` | `["/storage/data3/3fs","/storage/data4/3fs"]` |
| | `server.targets` | **`fdp_compaction_stream_id`** | **`2`** |
| `hf3fs_fuse_main_launcher.toml` | 根 | `mountpoint` / `token_file` | `'/3fs/stage'` / `'/opt/3fs/etc/token.txt'` |
| | `mgmtd_client` | `mgmtd_server_addresses` | 同上 |
| `hf3fs_fuse_main.toml` | `mgmtd` | `mgmtd_server_addresses` | 同上 |

### C.2 文件与目录清单

```
/opt/3fs/bin/{admin_cli,mgmtd_main,meta_main,storage_main,hf3fs_fuse_main,monitor_collector_main}
/opt/3fs/etc/{mgmtd,meta,storage,hf3fs_fuse,monitor_collector,admin_cli}*.toml
/opt/3fs/etc/fdb.cluster
/opt/3fs/etc/token.txt                     # 600
/opt/3fs/etc/generated_chains.csv
/opt/3fs/etc/generated_chain_table.csv
/var/log/3fs/*.log
/storage/data{3,4,5}/3fs/                  # target 根目录（下标 = disk-index）
/3fs/stage/                                # FUSE 挂载点
/usr/lib/systemd/system/{mgmtd_main,meta_main,storage_main,hf3fs_fuse_main,monitor_collector_main}.service
```

### C.3 常用命令

```bash
systemctl {status,restart} {mgmtd_main,meta_main,storage_main,hf3fs_fuse_main,monitor_collector_main}
journalctl -u storage_main -n 100 --no-pager | grep -a "\[FDP\]"
CLI list-nodes
CLIT list-targets
CLIT list-chains
CLIT list-chain-tables
CLIT current-user
clickhouse-client --password samsung -q "SELECT count() FROM \`3fs\`.counters"
nvme fdp status /dev/nvme3n1 -o json | head -20
nvme smart-log /dev/nvme3n1 | grep -E "Data Units Written|Percentage Used"
dmesg | grep -o "write with stream [0-9]*" | sort | uniq -c
```

### C.4 与 LMCache 的衔接

| 项 | 值 |
|---|---|
| 挂载点 | `/3fs/stage` |
| token | `/opt/3fs/etc/token.txt` |
| stream 分配 | 1 空置、2 = compaction、3.. = LMCache |
| `fdp_stream_number` | 取 `GET_MAX−2` 以内固定值（本环境 GET_MAX=14 ⇒ 建议 8，即 3..10） |

### C.5 一键自检脚本（可选，放 `/root/3fs-deploy/check.sh`）

```bash
#!/bin/bash
# 只读自检：集群状态 / 拓扑 / FDP 参数 / 监控
source /root/3fs-deploy/env.sh
echo "=== nodes ===";        CLI list-nodes
echo "=== targets ===";      CLIT list-targets
echo "=== chains ===";       CLIT list-chains
echo "=== chain tables ===";  CLIT list-chain-tables
echo "=== stripe/链数 校验 ==="
chains=$(CLIT list-chains 2>/dev/null | grep -c SERVING)
echo "SERVING 链数=$chains （必须 >= INIT_STRIP_SIZE=$INIT_STRIP_SIZE）"
echo "=== FDP ==="
for ip in $STORAGE_HOSTS; do
  echo "-- $ip"
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip \
    'grep -a fdp_compaction_stream_id /var/log/3fs/storage_main.log | tail -1'
done
echo "=== monitor ==="
clickhouse-client --password "$CH_PASSWD" -q "SELECT count() FROM \`3fs\`.counters"
```

---

**文档结束**。若执行中遇到本文未覆盖的报错，按 §8 的顺序排查：
地址（§1.2）→ FDB（§4.3）→ 配置下发（§4.8）→ stripe/链数（§1.3）→ token（§6.1）。
