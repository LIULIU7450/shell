# 3FS FDP 集群部署报告（4 节点：dskna004 + dsksa304/305/348）

> 目标：在目标环境部署一个开启 **FDP write stream** 能力的 3FS 集群，作为后续
> LMCache HF3FS 后端 KV-cache offload WAF 实验的基础设施。
> 部署流程以 `3fs/deploy/README.md`（官方 Setup Guide）为主线，结合本 fork 的
> FDP 扩展配置（`fdp_compaction_stream_id`）。
>
> 报告生成前已完成：4 台服务器各自完成 3FS 源码编译（`SHUFFLE_METHOD=g++11`，
> 二进制位于 `/home/smrc/lzh/3fs-main/build/bin`）、内核 FDP ioctl 与 SSD FDP
> 功能验证。

---

## 0. 部署概览

### 0.1 集群拓扑

| 节点 | 角色 | 管理 IP | IPoIB IP (RDMA) | node_id | 部署服务 |
|---|---|---|---|---|---|
| dskna004 | meta + client | 172.16.12.210 | **10.10.44.210** | mgmtd=1, meta=100 | ClickHouse、monitor_collector、**FoundationDB**、mgmtd、meta、admin_cli、FUSE client |
| dsksa304 | storage | 172.16.18.64 | 10.10.44.64 | storage=**10001** | storage_main、admin_cli |
| dsksa305 | storage | 172.16.18.65 | 10.10.44.65 | storage=**10002** | storage_main、admin_cli |
| dsksa348 | storage | 172.16.18.169 | 10.10.44.169 | storage=**10003** | storage_main、admin_cli |

- **cluster_id = `stage`**（按官方惯例），FUSE 挂载点 `/3fs/stage`。
- 所有服务间通信地址统一使用 **IPoIB 地址**（InfiniBand 200Gb/s，`RDMA://10.10.44.210:8000` 等）。
- 管理网（172.16.x.x）仅用于 ssh / rsync 分发。
- 每台存储节点 3 块 Samsung PM1763（MZ3LD15THELC-00AGG，15.36TB，FDP 已启用，
  15 个 placement ID / `max_write_streams=16`），已整盘 XFS 挂载于 `/storage/data{2,3,4}`。
  ZFS 盘（nvme1n1）与 OS 盘（nvme0n1）**不纳入** 3FS。

### 0.2 已确认的关键设计决策

| 决策项 | 结论 |
|---|---|
| 数据放置 | **每盘 1 个 target、每节点 3 targets、共 9 targets / 3 条链、RF=3**；`--use-new-chunk-engine`（FDP compaction 分流仅存在于新 chunk engine） |
| 链结构 | 每条链横跨 3 个节点各 1 块同编号盘（3 节点 RF=3 下的唯一形态；放置模型已求解 optimal，对等恢复流量完全平衡） |
| init-cluster | `1 1048576 16`（链表 ID 1、chunk 1MB、strip 16，官方默认） |
| Compaction 分流 | `[server.targets] fdp_compaction_stream_id = 2` |
| LMCache 数据流（后续） | `start_fdp_stream_id = 3, fdp_stream_number = 13`（stream 3–15） |
| 监控 | **部署** ClickHouse + monitor_collector（按官方 README Step 1/2），位于 dskna004 |

### 0.3 FDP write stream 规划（PM1763：15 PID = PLID 0–14，GET_MAX = 16）

XFS 对 `stream_id >= 2` 的映射为 **PLID = stream_id − 1**（见 `tests/fuse/test_fdp_write_stream.py:321` 注释，与 `storage_main.toml:457` 的说明一致）。

| stream id | 用途 | 落到的 PLID | 配置处 |
|---|---|---|---|
| 0 | 默认放置（未标注写入） | 默认 RU | —（回退值） |
| 1 | 空置 | — | — |
| **2** | **chunk engine compaction 写入** | PLID 1 | 3FS `fdp_compaction_stream_id = 2` |
| **3–15** | **LMCache KV-cache 数据写入**（后续阶段） | PLID 2–14 | LMCache `start_fdp_stream_id=3, fdp_stream_number=13` |

> 验证物理放置的方法：`nvme fdp status` 的 **RUAMW（可写余量）差值**——写入发生后
> 对应 PLID 的 RUAMW 下降最多。这是本 fork 自带测试采用的标准手段。

---

## 1. 全节点预检

> 在 4 台服务器上逐一执行。任何一项不过都**不要继续后续步骤**。

### 1.1 内核版本锁定（关键！）

所有节点必须运行 Samsung FDP 内核 **7.0.0-rc2**（含 `FS_IOC_WRITE_STREAM` ioctl）。
存储节点上还装有 `6.8.0-149-generic`、`7.0.0-43-generic` 等普通内核——**它们没有该
ioctl，一旦被误启动，FDP 分流全链路失效**。

```bash
uname -r          # 必须输出 7.0.0-rc2
grep FS_IOC_WRITE_STREAM /lib/modules/$(uname -r)/build/include/uapi/linux/fs.h
                  # 必须有输出

# 锁定引导条目，防止 apt 升级/重启后引导到普通内核：
sudo grub-editenv - set saved_entry="$(grep -m1 submenu /boot/grub/grub.cfg | \
  sed -n 's/.*menuentry_id_string \(["'\''][^"'\'']*["'\'']\).*/\1/p' | tr -d "'")"
# 简单做法（推荐）：确认当前内核可引导后
sudo grub-set-default "$(sudo awk -F\' '/menuentry / {print $2}' /boot/grub/grub.cfg | grep -m1 7.0.0-rc2)"
```

### 1.2 FDP 设备与 XFS ioctl 预检（仅 3 台存储节点）

```bash
# (a) 盘与 FDP 状态：3 块 PM1763 各应有 15 个 PID（0–14），RUAMW 约 10543104
for d in /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1; do
  sudo nvme fdp status $d -o json | head -5
done
cat /sys/block/nvme2n1/queue/max_write_streams   # 期望 16

# (b) XFS ioctl GET_MAX：在每块 3FS 数据盘上探测，期望 max_streams=16
python3 - /storage/data2 <<'EOF'
import fcntl, os, struct, sys
FS_IOC_WRITE_STREAM = 0xC010662B   # _IOWR('f', 43, struct fs_write_stream)
OP_GET_MAX = 1
fd = os.open(sys.argv[1], os.O_RDONLY)
ws = struct.pack("IIII", OP_GET_MAX, 0, 0, 0)
fcntl.ioctl(fd, FS_IOC_WRITE_STREAM, ws)
op, sid, mx, rsvd = struct.unpack("IIII", ws)
print(f"GET_MAX: op={op} max_streams={mx}")
assert mx == 16, f"期望 16, 实际 {mx} — XFS 未暴露 FDP 流, 停止部署!"
os.close(fd)
EOF
# 对 /storage/data3、/storage/data4 重复
```

> 历史基线：11/17 环境采集时 GET_MAX 曾返回 0；你已确认修复并返回 16。
> 此步骤是防止环境回退的硬闸门。

### 1.3 RDMA（IPoIB）连通性检查（官方 README 要求）

在 4 台之间两两验证（示例：dskna004 → dsksa304）：

```bash
# 服务端 (dsksa304)
ib_write_bw --rdmacm -d mlx5_0 -R
# 客户端 (dskna004)
ib_write_bw --rdmacm -d mlx5_0 -R 10.10.44.64
```

- 设备名以 `ibstat` 输出为准（dskna004 上为 mlx5_0…mlx5_7，存储节点为 ibp137s0f0 等）。
- 期望带宽接近 200 Gb/s（约 23 GB/s 级）。dsksa304 只有 1 个活动 IB 端口，不影响功能。
- 注意 IPoIB 掩码不一致（dskna004 /24，存储节点 /21）：若 10.10.44.x 互 ping 不通，
  需在存储节点补路由或统一掩码后再继续。

### 1.4 其他预检

```bash
chronyc tracking        # 各节点必须同步 (Leap status = Normal)
fdbcli --version        # dskna004: 必须为 7.1.x，且与 libfdb_c (ldconfig -p | grep fdb) 大版本一致
ls /home/smrc/lzh/3fs-main/build/bin/   # 4 台各自确认二进制齐全:
# admin_cli  hf3fs_fuse_main  meta_main  mgmtd_main  monitor_collector_main  storage_main
```

---

## 2. 系统参数（存储节点）

systemd 单元自带 `LimitNOFILE=1000000`（存储服务另有 `LimitMEMLOCK=infinity`），
无需手工调 shell ulimit。`fs.aio-max-nr` 必须调：

```bash
# 3 台存储节点:
cat <<'EOF' | sudo tee /etc/sysctl.d/99-3fs.conf
fs.aio-max-nr = 67108864
EOF
sudo sysctl --system
sysctl fs.aio-max-nr    # 确认 67108864 (默认 65536 不够)
```

---

## 3. ClickHouse + monitor_collector（dskna004）

按官方 Step 1/2。ClickHouse 与 monitor 都部署在 meta 节点 dskna004。

### 3.1 安装 ClickHouse（Ubuntu 22.04，需互联网，已确认可达）

```bash
curl -fsSL https://packages.clickhouse.com/deb/lts/CLICKHOUSE-KEY.GPG | \
  sudo gpg --dearmor -o /usr/share/keyrings/clickhouse-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/clickhouse-keyring.gpg] https://packages.clickhouse.com/deb/lts main/" | \
  sudo tee /etc/apt/sources.list.d/clickhouse.list
sudo apt update
sudo apt install -y clickhouse-server clickhouse-client
# 安装过程中提示设置 default 用户密码; 测试集群可留空
sudo systemctl enable --now clickhouse-server
```

### 3.2 建监控表

```bash
clickhouse-client -n < /home/smrc/lzh/3fs-main/deploy/sql/3fs-monitor.sql
clickhouse-client -q "SHOW TABLES FROM \`3fs\`"   # 应看到 counters / distributions
```

### 3.3 部署 monitor_collector

```bash
mkdir -p /opt/3fs/{bin,etc} /var/log/3fs
cp /home/smrc/lzh/3fs-main/build/bin/monitor_collector_main /opt/3fs/bin/
cp /home/smrc/lzh/3fs-main/configs/monitor_collector_main.toml /opt/3fs/etc/
```

编辑 `/opt/3fs/etc/monitor_collector_main.toml` 的 reporter 段（本机 ClickHouse，监听 10000 端口已内置）：

```toml
[server.monitor_collector.reporter]
type = 'clickhouse'

[server.monitor_collector.reporter.clickhouse]
db = '3fs'
host = '127.0.0.1'
passwd = ''            # 与安装时设置的密码一致
port = '9000'
user = 'default'
```

启动：

```bash
sudo cp /home/smrc/lzh/3fs-main/deploy/systemd/monitor_collector_main.service /usr/lib/systemd/system
sudo systemctl daemon-reload
sudo systemctl enable --now monitor_collector_main
journalctl -u monitor_collector_main -n 20 --no-pager   # 无报错即 OK
```

---

## 4. FoundationDB 初始化（dskna004）

FDB 7.1 软件包已装（1.4 预检确认），单节点测试配置：

```bash
sudo mkdir -p /var/lib/foundationdb/data /etc/foundationdb
sudo tee /etc/foundationdb/foundationdb.conf >/dev/null <<'EOF'
## foundationdb.conf
[general]
restart-check-batches = 60
cluster-file = /etc/foundationdb/fdb.cluster

[fdbmonitor]
[backup]

[sequential]
[sqldb]

## Server parameters
[server]
public-address = auto
listen-address = public
datadir = /var/lib/foundationdb/data
logdir = /var/log/foundationdb

[server.1]
class = storage
EOF

sudo systemctl enable --now foundationdb
sleep 3
fdbcli --exec "configure new single ssd"   # 测试集群用 single ssd
fdbcli --exec "status"                     # 期望: fully_replicated
cat /etc/foundationdb/fdb.cluster          # 记下内容, 后面要分发
```

---

## 5. admin_cli（4 台全装）

每台执行：

```bash
mkdir -p /opt/3fs/{bin,etc} /var/log/3fs
cp /home/smrc/lzh/3fs-main/build/bin/admin_cli /opt/3fs/bin/
cp /home/smrc/lzh/3fs-main/configs/admin_cli.toml /opt/3fs/etc/
```

`fdb.cluster` 从 dskna004 分发（各台均已有同版本 FDB 客户端库）：

```bash
# 在 dskna004 上:
for h in 172.16.18.64 172.16.18.65 172.16.18.169; do
  scp /etc/foundationdb/fdb.cluster $h:/opt/3fs/etc/
done
cp /etc/foundationdb/fdb.cluster /opt/3fs/etc/
```

编辑各台 `/opt/3fs/etc/admin_cli.toml`：

```toml
cluster_id = "stage"

[fdb]
clusterFile = '/opt/3fs/etc/fdb.cluster'
```

> FDB client/server 版本必须匹配（官方注意事项）；预检 1.4 已确认。

---

## 6. mgmtd 服务（dskna004，node_id = 1）

```bash
cp /home/smrc/lzh/3fs-main/build/bin/mgmtd_main /opt/3fs/bin/
cp /home/smrc/lzh/3fs-main/configs/{mgmtd_main.toml,mgmtd_main_launcher.toml,mgmtd_main_app.toml} /opt/3fs/etc/
```

配置编辑：

- `/opt/3fs/etc/mgmtd_main_app.toml`：`node_id = 1`（并把 `allow_empty_node_id` 保持 true 无妨）
- `/opt/3fs/etc/mgmtd_main_launcher.toml`：

```toml
cluster_id = "stage"

[fdb]
clusterFile = '/opt/3fs/etc/fdb.cluster'
```

- `/opt/3fs/etc/mgmtd_main.toml`：监控上报地址：

```toml
[common.monitor.reporters.monitor_collector]
remote_ip = "10.10.44.210:10000"
```

初始化集群（chunk 1MB、strip 16，官方默认；后续改动 mgmtd_main.toml 需清 FDB 重来，见官方 FAQ）：

```bash
/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  "init-cluster --mgmtd /opt/3fs/etc/mgmtd_main.toml 1 1048576 16"
```

启动并验证：

```bash
sudo cp /home/smrc/lzh/3fs-main/deploy/systemd/mgmtd_main.service /usr/lib/systemd/system
sudo systemctl daemon-reload && sudo systemctl enable --now mgmtd_main

/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' "list-nodes"
# 应看到 mgmtd 节点 1 处于 SERVING
```

---

## 7. meta 服务（dskna004，node_id = 100）

```bash
cp /home/smrc/lzh/3fs-main/build/bin/meta_main /opt/3fs/bin/
cp /home/smrc/lzh/3fs-main/configs/{meta_main_launcher.toml,meta_main.toml,meta_main_app.toml} /opt/3fs/etc/
```

配置编辑：

- `meta_main_app.toml`：`node_id = 100`
- `meta_main_launcher.toml`：

```toml
cluster_id = "stage"

[mgmtd_client]
mgmtd_server_addresses = ["RDMA://10.10.44.210:8000"]
```

- `meta_main.toml`：

```toml
[server.mgmtd_client]
mgmtd_server_addresses = ["RDMA://10.10.44.210:8000"]

[common.monitor.reporters.monitor_collector]
remote_ip = "10.10.44.210:10000"

[server.fdb]
clusterFile = '/opt/3fs/etc/fdb.cluster'
```

配置由 mgmtd 统一管理，上传后启动：

```bash
/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' \
  "set-config --type META --file /opt/3fs/etc/meta_main.toml"

sudo cp /home/smrc/lzh/3fs-main/deploy/systemd/meta_main.service /usr/lib/systemd/system
sudo systemctl daemon-reload && sudo systemctl enable --now meta_main

# 验证: list-nodes 中出现 node 100 (meta, SERVING)
```

---

## 8. storage 服务（3 台存储节点，node_id = 10001/10002/10003）

### 8.1 数据目录

盘已 XFS 格式化并挂载在 `/storage/data{2,3,4}`（挂载参数已含 `noatime,nodiratime`，
扇区 4K，符合官方要求）。每台只需创建 engine 子目录：

```bash
mkdir -p /storage/data2/3fs /storage/data3/3fs /storage/data4/3fs
```

### 8.2 安装与配置（三台相同，仅 node_id 不同）

```bash
cp /home/smrc/lzh/3fs-main/build/bin/storage_main /opt/3fs/bin/
cp /home/smrc/lzh/3fs-main/configs/{storage_main_launcher.toml,storage_main.toml,storage_main_app.toml} /opt/3fs/etc/
```

- `storage_main_app.toml`：`node_id = 10001`（dsksa305 → 10002，dsksa348 → 10003）
- `storage_main_launcher.toml`：

```toml
cluster_id = "stage"

[mgmtd_client]
mgmtd_server_addresses = ["RDMA://10.10.44.210:8000"]
```

- `storage_main.toml`（**注意：`target_paths` 数组顺序 = create-target 的 `--disk-index` 下标**，
  `--disk-index 0/1/2` 分别对应数组第 1/2/3 个路径）：

```toml
[server.mgmtd]
mgmtd_server_addresses = ["RDMA://10.10.44.210:8000"]

[common.monitor.reporters.monitor_collector]
remote_ip = "10.10.44.210:10000"

[server.targets]
# FDP: compaction 写入走 stream 2 (→ PLID 1), 与 LMCache 数据流 (3-15) 隔离。
# 设备不支持或超范围时自动回退 0 (默认放置), 不会报错。
# 仅启动时加载: 修改后需 set-config + systemctl restart storage_main。
fdp_compaction_stream_id = 2
target_paths = ["/storage/data2/3fs","/storage/data3/3fs","/storage/data4/3fs"]
```

上传配置（mgmtd 统一管理）并启动：

```bash
/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' \
  "set-config --type STORAGE --file /opt/3fs/etc/storage_main.toml"

sudo cp /home/smrc/lzh/3fs-main/deploy/systemd/storage_main.service /usr/lib/systemd/system
sudo systemctl daemon-reload && sudo systemctl enable --now storage_main

# 三台都起后, 在 dskna004 验证:
/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' "list-nodes"
# 应看到 3 个 storage 节点全部 SERVING
```

---

## 9. 管理用户、targets、链与链表

以下命令全部在 **dskna004** 上执行。

### 9.1 创建 root 用户并保存 token

```bash
/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' \
  "user-add --root --admin 0 root"
# 输出的 token 保存到 /opt/3fs/etc/token.txt
```

### 9.2 创建 9 个 storage targets（每盘 1 个，新 chunk engine）

链表由官方 data_placement 工具生成，并已实际验证（放置模型 3 节点/RF=3/每盘 1 target
求解 optimal；生成命令含 `--use-new-chunk-engine`——FDP compaction 分流依赖新 chunk
engine，**不可省略**）。命令全文如下：

```bash
# 注意: 先给 target 建目录数据所在盘对应关系见 8.2 (disk-index 0→data2, 1→data3, 2→data4)
/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' \
  --config.user_info.token $(<"/opt/3fs/etc/token.txt") <<'EOF'
create-target --node-id 10001 --disk-index 0 --target-id 101000100101 --chain-id 900100001  --use-new-chunk-engine
create-target --node-id 10002 --disk-index 0 --target-id 101000200101 --chain-id 900100001  --use-new-chunk-engine
create-target --node-id 10003 --disk-index 0 --target-id 101000300101 --chain-id 900100001  --use-new-chunk-engine
create-target --node-id 10001 --disk-index 1 --target-id 101000100201 --chain-id 900200001  --use-new-chunk-engine
create-target --node-id 10002 --disk-index 1 --target-id 101000200201 --chain-id 900200001  --use-new-chunk-engine
create-target --node-id 10003 --disk-index 1 --target-id 101000300201 --chain-id 900200001  --use-new-chunk-engine
create-target --node-id 10001 --disk-index 2 --target-id 101000100301 --chain-id 900300001  --use-new-chunk-engine
create-target --node-id 10002 --disk-index 2 --target-id 101000200301 --chain-id 900300001  --use-new-chunk-engine
create-target --node-id 10003 --disk-index 2 --target-id 101000300301 --chain-id 900300001  --use-new-chunk-engine
EOF
```

结构（3 条链，每链跨 3 节点各一块盘）：

```
链 900100001:  dsksa304·data2 → dsksa305·data2 → dsksa348·data2
链 900200001:  dsksa304·data3 → dsksa305·data3 → dsksa348·data3
链 900300001:  dsksa304·data4 → dsksa305·data4 → dsksa348·data4
```

> 如需重新生成/复核，命令为（在任一台有 python3 + pip 的机器上）：
> `pip install -r 3fs/deploy/data_placement/requirements.txt`（highspy==1.8.0 若无
> 源可放宽到 ≥1.9），然后
> `python src/model/data_placement.py -ql -relax -type CR --num_nodes 3 --replication_factor 3 --min_targets_per_disk 1`
> + `python src/setup/gen_chain_table.py --chain_table_type CR --node_id_begin 10001 --node_id_end 10003 --num_disks_per_node 3 --num_targets_per_disk 1 --target_id_prefix 1 --chain_id_prefix 9 --incidence_matrix_path output/<解目录>/incidence_matrix.pickle`

### 9.3 上传链与链表

```bash
# 生成 chains/chain table CSV (内容见 9.4, 也可用 gen_chain_table.py 重新生成文件)
/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' \
  --config.user_info.token $(<"/opt/3fs/etc/token.txt") \
  "upload-chains /path/to/generated_chains.csv"

/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' \
  --config.user_info.token $(<"/opt/3fs/etc/token.txt") \
  "upload-chain-table --desc stage 1 /path/to/generated_chain_table.csv"

# 验证:
... "list-chains"          # 3 条链
... "list-chain-tables"    # 表 1, version 1, 含 3 条链
```

`generated_chains.csv` 内容（可直接手工保存使用）：

```
ChainId,TargetId,TargetId,TargetId
900100001,101000100101,101000200101,101000300101
900200001,101000100201,101000200201,101000300201
900300001,101000100301,101000200301,101000300301
```

`generated_chain_table.csv` 内容：

```
ChainId
900100001
900200001
900300001
```

---

## 10. FUSE client（dskna004）

```bash
cp /home/smrc/lzh/3fs-main/build/bin/hf3fs_fuse_main /opt/3fs/bin/
cp /home/smrc/lzh/3fs-main/configs/{hf3fs_fuse_main_launcher.toml,hf3fs_fuse_main.toml} /opt/3fs/etc/
mkdir -p /3fs/stage
```

- `hf3fs_fuse_main_launcher.toml`：

```toml
cluster_id = "stage"
mountpoint = '/3fs/stage'
token_file = '/opt/3fs/etc/token.txt'

[mgmtd_client]
mgmtd_server_addresses = ["RDMA://10.10.44.210:8000"]
```

- `hf3fs_fuse_main.toml`：

```toml
[mgmtd]
mgmtd_server_addresses = ["RDMA://10.10.44.210:8000"]

[common.monitor.reporters.monitor_collector]
remote_ip = "10.10.44.210:10000"
```

上传配置并启动：

```bash
/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' \
  "set-config --type FUSE --file /opt/3fs/etc/hf3fs_fuse_main.toml"

sudo cp /home/smrc/lzh/3fs-main/deploy/systemd/hf3fs_fuse_main.service /usr/lib/systemd/system
sudo systemctl daemon-reload && sudo systemctl enable --now hf3fs_fuse_main

mount | grep '/3fs/stage'    # 确认挂载
```

---

## 11. 部署后验证

### 11.1 基本功能

```bash
# (dskna004) 集群状态
/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
  --config.mgmtd_client.mgmtd_server_addresses '["RDMA://10.10.44.210:8000"]' "list-nodes"
# 期望: mgmtd(1) + meta(100) + storage(10001/10002/10003) 全部 SERVING

# 读写冒烟测试
mkdir -p /3fs/stage/test
dd if=/dev/urandom of=/3fs/stage/test/f1 bs=1M count=512 oflag=direct
md5sum /3fs/stage/test/f1          # 记录 md5
dd if=/3fs/stage/test/f1 of=/tmp/f1.copy bs=1M iflag=direct
md5sum /tmp/f1.copy                # 两次 md5 必须一致

# 监控链路验证: 有写入后 ClickHouse 应出现数据
clickhouse-client -q "SELECT count() FROM \`3fs\`.counters"
clickhouse-client -q "SELECT count() FROM \`3fs\`.distributions"
```

### 11.2 FDP 能力验证（三层）

**层 1 — 存储节点：chunk engine FDP 探测日志。** compaction 首次触发时，storage 日志应出现
解析成功的 INFO（`src/storage/chunk_engine/src/core/engine.rs:309`）：

```bash
# 在 3 台存储节点:
journalctl -u storage_main --no-pager | grep "\[FDP\]"
# 期望 (写入量足够触发 compaction 后):
# [FDP] compaction stream resolved: configured=2 max=16 resolved=2
# 若出现 "fell back to default placement" 说明 ioctl/设备异常, 需回到第 1 章预检
```

**层 2 — 客户端：FUSE ioctl 透传。** 3FS 的 FUSE ioctl（`HF3FS_IOC_WRITE_STREAM = 0xC0106810`，
GET_MAX=1 / GET=2 / SET=4）：

```bash
# (dskna004) 对挂载点上的文件执行 GET_MAX, 期望透传到存储盘并返回 16
python3 - /3fs/stage/test <<'EOF'
import fcntl, os, struct, sys
HF3FS_IOC_WRITE_STREAM = (3 << 30) | (16 << 16) | (0x68 << 8) | 16  # 0xC0106810
OP_GET_MAX = 1
p = os.path.join(sys.argv[1], "fdp_probe")
fd = os.open(p, os.O_RDWR | os.O_CREAT, 0o644)
ws = struct.pack("IIII", OP_GET_MAX, 0, 0, 0)
fcntl.ioctl(fd, HF3FS_IOC_WRITE_STREAM, ws)
op, sid, mx, rsvd = struct.unpack("IIII", ws)
print(f"FUSE GET_MAX: max_streams={mx}")
assert mx == 16, f"期望 16, 实际 {mx}"
os.close(fd)
EOF
```

**层 3 — 物理放置：RUAMW 差值。**（本 fork 测试 `test_fdp_write_stream.py:280` 的标准手段）

```bash
# (任一存储节点, 例: nvme2n1)
sudo nvme fdp status /dev/nvme2n1 -o json > /tmp/before.json
# (dskna004) 经 FUSE ioctl SET stream 3 写入 ~1GB:
#   用上面脚本改 OP_SET(=4), stream_id=3, 循环 os.write
sudo nvme fdp status /dev/nvme2n1 -o json > /tmp/after.json
# 对比 RUAMW: PLID 2 (= stream 3 - 1) 的下降量应显著大于其他 PLID
```

> 也可直接运行仓库自带集成测试（在 dskna004）：
> `python3 /home/smrc/lzh/3fs-main/tests/fuse/test_fdp_write_stream.py /3fs/stage`
> （物理放置检查依赖从写入路径反查 NVMe 设备，跨节点场景会 SKIP 属正常，
> 以层 1/2 + 存储节点层 3 手工验证为准。）

### 11.3 故障排查入口（官方 FAQ 摘要）

- 服务启动失败 → `journalctl -u <service>` 看 stdout/stderr。
- 各节点 `/var/log/3fs/` 日志文件。
- `init-cluster` 报错 → 检查 mgmtd_main.toml；**改此文件需清空 FDB 数据重跑 init-cluster**。
- 改任何 `*_main.toml` → 必须 `admin_cli set-config` 上传，且启动期加载项
  （如 `fdp_compaction_stream_id`）还要 `systemctl restart storage_main`。

---

## 12. WAF 观测手段（为后续 LMCache 实验准备）

部署完成后，测量写入放大的基准手段（3 台存储节点）：

```bash
# 总写入量 (host 视角 → NAND 视角): smart-log 的 Data Units Written
# 1 unit = 512KB; WAF = NAND 写入 / host 写入
sudo nvme smart-log /dev/nvme2n1 | grep -i "data_units_written"

# 分流观测: 各 PLID 的 RUAMW 变化 (stream 2→PLID1 为 compaction, stream 3-15→PLID2-14 为数据)
sudo nvme fdp status /dev/nvme2n1 -o json
```

实验对比维度建议：
1. `fdp_compaction_stream_id = 0`（关闭）vs `= 2`（开启）——存储侧 compaction 分流的 WAF 收益；
2. LMCache `use_fdp=false` vs `true (start=3, number=13)`——数据流分流的收益；
3. 每次 DUT 切换配置后 `systemctl restart storage_main` 并记录基线 smart-log 读数。

---

## 13. 附录

### 13.1 完整执行顺序清单

| # | 节点 | 动作 | 章节 |
|---|---|---|---|
| 1 | 全部 | 内核锁定 / FDP ioctl / RDMA / FDB / chrony 预检 | 1 |
| 2 | 存储×3 | sysctl aio-max-nr | 2 |
| 3 | dskna004 | ClickHouse 安装 + 建表 | 3.1–3.2 |
| 4 | dskna004 | monitor_collector 部署启动 | 3.3 |
| 5 | dskna004 | FDB 初始化 | 4 |
| 6 | 全部 | admin_cli 安装 + fdb.cluster 分发 + admin_cli.toml | 5 |
| 7 | dskna004 | mgmtd 安装、init-cluster、启动、list-nodes | 6 |
| 8 | dskna004 | meta 安装、set-config META、启动、list-nodes | 7 |
| 9 | 存储×3 | 目录、storage 安装（node_id 唯一）、set-config STORAGE、启动 | 8 |
| 10 | dskna004 | user-add 存 token | 9.1 |
| 11 | dskna004 | create-target ×9（--use-new-chunk-engine） | 9.2 |
| 12 | dskna004 | upload-chains + upload-chain-table + list 验证 | 9.3 |
| 13 | dskna004 | FUSE 安装、set-config FUSE、启动、mount 验证 | 10 |
| 14 | 全部 | 11.1 功能冒烟 → 11.2 FDP 三层验证 | 11 |

### 13.2 重建/回滚

- **完全重建**：停全部服务 → 清 FDB（`rm -rf /var/lib/foundationdb/data/*` 后重启
  foundationdb 并重新 `configure new`）→ rm 目标引擎目录 `/storage/data{2,3,4}/3fs/*`
  → 从第 5 步重跑（`init-cluster` 会生成全新集群状态）。
- **仅重建 targets**：`admin_cli` 依次 `offline-target`/`remove-target`（生成脚本见
  `deploy/data_placement` 的 `remove_target_cmd.txt` 输出），清引擎目录后重跑 9.2。
- 修改 `fdp_compaction_stream_id`：编辑 storage_main.toml → `set-config --type STORAGE` →
  三台 `systemctl restart storage_main` → 看 `[FDP] compaction stream resolved` 日志。

### 13.3 与 LMCache 阶段的衔接参数（备忘）

3FS 就绪后，LMCache HF3FS 后端（后续部署）需与本集群对齐的参数：

- 挂载点：`/3fs/stage`（`hf3fs://` / L2 adapter 配置）
- FDP：`use_fdp=true, start_fdp_stream_id=3, fdp_stream_number=13`（stream 3–15 → PLID 2–14，
  与 compaction 的 stream 2 / PLID 1 隔离；0–1 空置）
- token：`/opt/3fs/etc/token.txt`（root 用户）
- 客户端 python 包：`lmcache_hf3fs` 原生扩展需链接本集群同版 3FS 客户端库
  （`libhf3fs_api_shared.so`，构建方式见 LMCache 仓库 `setup.py` 的
  `BUILD_HF3FS=1 HF3FS_INCLUDE_DIR/HF3FS_LIB_DIR`）。

### 13.4 本报告的依据

- 部署主线：`3fs/deploy/README.md`（官方 Setup Guide，Step 0–8 全部保留，含 monitor）
- FDP 配置：`3fs/configs/storage_main.toml:451-462`、
  `3fs/docs/openspec/specs/storage-internal-fdp-stream/spec.md`（回退语义：不报错、不影响写入）
- FDP 验证手段：`3fs/tests/fuse/test_fdp_write_stream.py`（RUAMW 差值法、XFS PLID 映射、
  FUSE ioctl 常量）
- 放置方案：`3fs/deploy/data_placement`（3 节点/RF=3/每盘 1 target 求解 optimal，
  9 targets/3 chains 生成命令已验证）
- 环境事实：`shell/*_envinfo_*.txt`（4 台环境采集报告）+ 用户确认
  （编译完成、FDB 依赖已装、GET_MAX=16、盘可清空、ZFS 盘排除）
