# 3FS + XFS FDP Cluster Setup Guide

本文件描述 **本实验环境** 的部署流程，章节结构与 [`3fs-main/deploy/README.md`](../../3fs-main/deploy/README.md) 一致，
参数取值均来自当前已运行集群（dskna004 + dsksa304/305/348）。
需要背景说明（各步骤的根因、验证原理、故障排查）时，见同目录：

- `3FS_FDP_部署手册_逐步执行版.md` —— 自包含的命令级手册
- `3FS_FDP_部署手册.md` —— 部署记录 + 问题修复清单
- `README_执行顺序.md` —— 脚本化部署速查

---

## Installation prerequisites

### Hardware specifications

| Node | OS | Kernel | 管理网 IP | IPoIB | SSD | RDMA | Role |
|---|---|---|---|---|---|---|---|
| dskna004 | Ubuntu 22.04 | 7.0.0-rc2 | 172.16.12.210 | 10.10.44.210 | — | mlx5 × 4 | mgmtd / meta / monitor / FUSE |
| dsksa304 | Ubuntu 22.04 | 7.0.0-rc2 | 172.16.18.64 | 10.10.44.64 | 15.36TB × 2 | mlx5 | storage (node 10001) |
| dsksa305 | Ubuntu 22.04 | 7.0.0-rc2 | 172.16.18.65 | 10.10.44.65 | 15.36TB × 2 | mlx5 | storage (node 10002) |
| dsksa348 | Ubuntu 22.04 | 7.0.0-rc2 | 172.16.18.169 | 10.10.44.169 | 15.36TB × 2 | mlx5 | storage (node 10003) |

数据盘规划（存储节点一致）：

| 设备 | 挂载点 | 用途 | 备注 |
|---|---|---|---|
| `/dev/nvme0n1` | `/` | 系统盘 | ext4，**不要使用** |
| `/dev/nvme1n1` | — | ZFS 成员 | 被其他业务占用，**不要使用** |
| `/dev/nvme2n1` | — | ZFS 池 `ost00pool`（Lustre OST） | 已用 ~10TB，**不要使用** |
| `/dev/nvme3n1` | `/storage/data3` | 3FS target 根目录 | XFS，`noatime,nodiratime` |
| `/dev/nvme4n1` | `/storage/data4` | 3FS target 根目录 | XFS，`noatime,nodiratime` |

> 挂载命令（未写入 `/etc/fstab`，重启后需手工挂载）：
> ```bash
> mount -o noatime,nodiratime /dev/nvme3n1 /storage/data3
> mount -o noatime,nodiratime /dev/nvme4n1 /storage/data4
> ```

### Kernel requirement

XFS 侧需要 Samsung FDP 补丁，提供 `FS_IOC_WRITE_STREAM`（`_IOWR('f', 43, struct fs_write_stream)`）。

```bash
uname -r                                   # 期望 7.0.0-rc2
grep -rn "FS_IOC_WRITE_STREAM" /usr/src/linux-headers-$(uname -r)/include/uapi/linux/fs.h
```

`XFS GET_MAX = 14`（硬件 16 条写流 − XFS 内部保留 2 条）；`GET_MAX = 0` 表示设备未暴露写流，
3FS 会自动回退默认放置（不报错）。**探测时必须读 ioctl 的返回值**，见 [FAQ](#faq)。

### Pre-flight checks (run on every node)

```bash
# 1) 内核与 ioctl（FDP 补丁）
uname -r
grep -rn "FS_IOC_WRITE_STREAM" /usr/src/linux-headers-$(uname -r)/include/uapi/linux/fs.h

# 2) 时间同步（时钟漂移会导致租约/心跳异常）
chronyc tracking | grep -E "Leap status|System time"          # Leap status : Normal

# 3) 二进制
ls -l ~/3fs/build/bin/{admin_cli,mgmtd_main,meta_main,storage_main,hf3fs_fuse_main,monitor_collector_main}

# 4) 【存储节点】FDP 设备：PID 必须从 0 连续
for d in /dev/nvme3n1 /dev/nvme4n1; do
  echo "== $d"
  nvme fdp status "$d" -o json | python3 -c \
    "import json,sys;d=json.load(sys.stdin);print('nruhsd',d['nruhsd'],'PIDs',' '.join(str(e['pid']) for e in d['ruhss']))"
done

# 5) 【存储节点】数据盘挂载
findmnt -t xfs -o SOURCE,TARGET,OPTIONS

# 6) 【dskna004】IB 端口、依赖服务、到存储节点的 ssh（Step 6 分发 fdb.cluster 需要）
ibstat | grep -c "State:.*Active"                              # >= 1
clickhouse-client --password samsung -q "SELECT version()"
fdbcli --version && ls -l /lib/libfdb_c.so*
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip hostname
done
```

`XFS GET_MAX` 的探测方法见 Step 9.2（必须读 ioctl 返回值，否则恒为 0）。

### Third-party dependencies

| Service | Version | Node | 说明 |
|---|---|---|---|
| [ClickHouse](https://clickhouse.com/docs/install) | 26.10 | dskna004 | 需把 `network_compression_method` 改为 LZ4（Step 1） |
| [FoundationDB](https://apple.github.io/foundationdb/administration.html) | 7.3.63 | dskna004 | 单机 `single ssd`；`libfdb_c` 必须与服务端同版本 |

---

## Step 0: Build 3FS

构建产物已存在于 `~/3fs/build/bin`，本环境直接使用（`-rwxr-xr-x`，2026-11-19 构建）：

```bash
ls -l ~/3fs/build/bin/{admin_cli,mgmtd_main,meta_main,storage_main,hf3fs_fuse_main,monitor_collector_main}
```

如需重新构建（**必须沿用现网构建参数**，否则 `std::shuffle` 不同会导致数据布局不兼容）：

```bash
cd ~/3fs
cmake -S . -B build \
      -DCMAKE_CXX_COMPILER=clang++-14 -DCMAKE_C_COMPILER=clang-14 \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      -DSHUFFLE_METHOD=g++11        # 本环境既有集群即为 g++11，不可更改
cmake --build build -j 32
```

当前构建参数（`build/CMakeCache.txt`）：`CMAKE_CXX_COMPILER=/usr/bin/clang++-14`、`SHUFFLE_METHOD=g++11`。

### Services and clients

| Service | Binary | Config files（位于 `/opt/3fs/etc`） | NodeID | Node |
|---|---|---|---|---|
| monitor | `monitor_collector_main` | `monitor_collector_main.toml` | — | dskna004 |
| admin_cli | `admin_cli` | `admin_cli.toml` + `fdb.cluster` | — | dskna004 |
| mgmtd | `mgmtd_main` | `mgmtd_main_launcher.toml`<br>`mgmtd_main.toml`<br>`mgmtd_main_app.toml`<br>`fdb.cluster` | 1 | dskna004 |
| meta | `meta_main` | `meta_main_launcher.toml`<br>`meta_main.toml`<br>`meta_main_app.toml`<br>`fdb.cluster` | 100 | dskna004 |
| storage | `storage_main` | `storage_main_launcher.toml`<br>`storage_main.toml`<br>`storage_main_app.toml` | 10001 / 10002 / 10003 | dsksa304 / 305 / 348 |
| client | `hf3fs_fuse_main` | `hf3fs_fuse_main_launcher.toml`<br>`hf3fs_fuse_main.toml` | — | dskna004 |

集群常量（下文命令均基于此）：

```bash
CLUSTER_ID=stage
MOUNT_POINT=/3fs/stage
MGMTD_ADDR='RDMA://172.16.12.210:8000'     # 必须用管理网 IP，不能用 IPoIB
MONITOR_ADDR=172.16.12.210:10000
INIT_CHAIN_TABLE_ID=1
INIT_CHUNK_SIZE=1048576
INIT_STRIP_SIZE=2                          # 必须 <= 链数（本集群 6 targets / RF=3 => 2 条链）
FDP_COMPACTION_STREAM_ID=2
STORAGE_HOSTS="172.16.18.64 172.16.18.65 172.16.18.169"
```

### Base directories (all nodes)

所有服务都把二进制装在 `/opt/3fs/bin`、配置读自 `/opt/3fs/etc`、日志写 `/var/log/3fs`：

```bash
mkdir -p /opt/3fs/bin /opt/3fs/etc /var/log/3fs
```

---

## Step 1: Create ClickHouse tables for metrics

Install `clickhouse` on **dskna004**, then:

```bash
clickhouse-client --password samsung --multiquery < ~/3fs/deploy/sql/3fs-monitor.sql
clickhouse-client --password samsung -q "SHOW TABLES FROM \`3fs\`"      # counters / distributions
```

**Must do**: ClickHouse 26.x 默认 `network_compression_method=ZSTD`，而 3FS 内置 clickhouse-cpp 只实现 LZ4，
不改会导致 monitor 写入报 `unsupported compression method 144`、监控表为空。

```bash
clickhouse-client --password samsung -q \
  "SELECT value FROM system.settings WHERE name='network_compression_method'"   # 期望 lz4
```

若不是 `lz4`：

```bash
cat > /etc/clickhouse-server/users.d/zz-3fs-lz4.xml <<'EOF'
<?xml version="1.0"?>
<clickhouse>
    <profiles>
        <default>
            <network_compression_method>lz4</network_compression_method>
        </default>
    </profiles>
</clickhouse>
EOF
clickhouse-client --password samsung -q "SYSTEM RELOAD USERS"                   # 无需重启服务
```

---

## Step 2: Monitor service

Install `monitor_collector` on **dskna004**.

1. Copy binary and config:
   ```bash
   cp ~/3fs/build/bin/monitor_collector_main /opt/3fs/bin
   cp ~/3fs/configs/monitor_collector_main.toml /opt/3fs/etc
   ```
2. Set cluster id and ClickHouse reporter in `/opt/3fs/etc/monitor_collector_main.toml`:
   ```toml
   [common]
   cluster_id = 'stage'

   [server.monitor_collector.reporter]
   type = 'clickhouse'

   [server.monitor_collector.reporter.clickhouse]
   db = '3fs'
   host = '127.0.0.1'
   port = '9000'
   user = 'default'
   passwd = 'samsung'

   [common.ib_devices]
   device_filter = ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]   # 与 admin_cli/mgmtd 一致（dskna004 有 8 个活动 HCA）
   ```
3. Start service:
   ```bash
   cp ~/3fs/deploy/systemd/monitor_collector_main.service /usr/lib/systemd/system
   systemctl daemon-reload && systemctl enable --now monitor_collector_main
   ss -lntp | grep 10000        # 172.16.12.210:10000
   ```

---

## Step 3: Admin client

Install `admin_cli` on **dskna004**（存储节点也放一份，仅作本地调试；FDB 只监听 127.0.0.1，管理命令统一在 dskna004 执行）。

1. Check FoundationDB, create cluster file if missing:
   ```bash
   fdbcli --exec "status minimal"                 # The database is available.
   cat /etc/foundationdb/fdb.cluster              # 3fsfdp:xxxxxxxx@127.0.0.1:4500
   cp /etc/foundationdb/fdb.cluster /opt/3fs/etc/fdb.cluster && chmod 644 /opt/3fs/etc/fdb.cluster
   ```

   单机 FDB 的关键配置（`/etc/foundationdb/foundationdb.conf`，本环境取值）：

   ```toml
   [fdbmonitor]
   user = foundationdb
   group = foundationdb

   [general]
   cluster-file = /etc/foundationdb/fdb.cluster

   [fdbserver]
   command = /usr/sbin/fdbserver
   public-address = auto:$ID
   listen-address = public          # 只监听 127.0.0.1:4500，因此管理命令都在 dskna004 执行
   datadir = /var/lib/foundationdb/data/$ID
   logdir = /var/log/foundationdb

   [fdbserver.4500]
   ```

   若数据库尚未初始化（全新环境）：
   ```bash
   systemctl start foundationdb
   fdbcli --exec "configure new single ssd"
   sleep 5 && fdbcli --exec "status minimal"
   ```

2. Copy binary and config; set `cluster_id` / `clusterFile` / IB filter in `/opt/3fs/etc/admin_cli.toml`:
   ```bash
   cp ~/3fs/build/bin/admin_cli /opt/3fs/bin
   cp ~/3fs/configs/admin_cli.toml /opt/3fs/etc
   ```
   ```toml
   cluster_id = 'stage'

   [fdb]
   clusterFile = '/opt/3fs/etc/fdb.cluster'

   [ib_devices]
   device_filter = ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]   # dskna004 有 8 个活动 HCA，3FS 上限 4
   ```

3. Define two helpers used by the rest of this guide:
   ```bash
   cat >> ~/.bashrc <<'EOF'
   CLI()  { /opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml \
            --config.mgmtd_client.mgmtd_server_addresses '["RDMA://172.16.12.210:8000"]' "$@"; }
   CLIT() { CLI --config.user_info.token "$(cat /opt/3fs/etc/token.txt 2>/dev/null)" "$@"; }
   EOF
   source ~/.bashrc
   CLI help | head -5
   ```

4. (可选) 在 3 台存储节点安装 `admin_cli` —— 仅作本地自检：FDB 只监听 `127.0.0.1`，
   管理命令统一在 dskna004 执行（见 FAQ 10）：
   ```bash
   cp ~/3fs/build/bin/admin_cli /opt/3fs/bin
   cp ~/3fs/configs/admin_cli.toml /opt/3fs/etc
   sed -i 's/^device_filter = .*/device_filter = []/' /opt/3fs/etc/admin_cli.toml
   /opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml help >/dev/null && echo "admin_cli ok"
   ```

---

## Step 4: Mgmtd service

Install `mgmtd` on **dskna004**.

1. Copy binary and configs:
   ```bash
   cp ~/3fs/build/bin/mgmtd_main /opt/3fs/bin
   cp ~/3fs/configs/{mgmtd_main.toml,mgmtd_main_launcher.toml,mgmtd_main_app.toml} /opt/3fs/etc
   ```
2. Update config files:
   - `mgmtd_main_app.toml`: `node_id = 1`
   - `mgmtd_main_launcher.toml`:
     ```toml
     cluster_id = 'stage'

     [fdb]
     clusterFile = '/opt/3fs/etc/fdb.cluster'

     [kv_engine.fdb]
     clusterFile = '/opt/3fs/etc/fdb.cluster'

     [ib_devices]
     device_filter = ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]
     ```
   - `mgmtd_main.toml`:
     ```toml
     [common.monitor.reporters.monitor_collector]
     remote_ip = '172.16.12.210:10000'
     ```
3. Start mgmtd, then initialize the cluster **once**:
   ```bash
   cp ~/3fs/deploy/systemd/mgmtd_main.service /usr/lib/systemd/system
   systemctl daemon-reload && systemctl enable --now mgmtd_main
   sleep 3 && CLI list-nodes                       # MGMTD  PRIMARY_MGMTD

   CLI init-cluster 1 1048576 2
   # Init filesystem, root directory layout: chain table ChainTableId(1), chunksize 1048576, stripesize 2
   ```

   Parameters of `init-cluster`:

   > - `1` —— chain table ID
   > - `1048576` —— chunk size in bytes
   > - `2` —— file strip size，**必须 ≤ 链数**（本集群 2 条链；配 16 会导致写请求 `EIO`，见 FAQ）
   >
   > stripe 与 chunk 一旦写入 FDB 不可修改，调整需清 FDB 重建。

4. Upload mgmtd runtime config:
   ```bash
   CLI set-config --type MGMTD --file /opt/3fs/etc/mgmtd_main.toml
   CLI list-nodes                                  # ConfigVersion 变为 UPTODATE
   ```

---

## Step 5: Meta service

Install `meta` on **dskna004**.

1. Copy binary and configs:
   ```bash
   cp ~/3fs/build/bin/meta_main /opt/3fs/bin
   cp ~/3fs/configs/{meta_main.toml,meta_main_launcher.toml,meta_main_app.toml} /opt/3fs/etc
   ```
2. Update config files:
   - `meta_main_app.toml`: `node_id = 100`
   - `meta_main_launcher.toml`:
     ```toml
     cluster_id = 'stage'

     [mgmtd_client]
     mgmtd_server_addresses = ["RDMA://172.16.12.210:8000"]

     [ib_devices]
     device_filter = ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]
     ```
   - `meta_main.toml`:
     ```toml
     [server.mgmtd_client]
     mgmtd_server_addresses = ["RDMA://172.16.12.210:8000"]

     [server.fdb]
     clusterFile = '/opt/3fs/etc/fdb.cluster'

     [server.kv_engine.fdb]
     clusterFile = '/opt/3fs/etc/fdb.cluster'

     [common.monitor.reporters.monitor_collector]
     remote_ip = '172.16.12.210:10000'
     ```
3. Upload the config to mgmtd and start:
   ```bash
   CLI set-config --type META --file /opt/3fs/etc/meta_main.toml
   cp ~/3fs/deploy/systemd/meta_main.service /usr/lib/systemd/system
   systemctl daemon-reload && systemctl enable --now meta_main
   CLI list-nodes                                  # META 100  HEARTBEAT_CONNECTED
   ```

> 本版本 `NodeStatus` 只有 `PRIMARY_MGMTD / HEARTBEAT_CONNECTED / ...`，**没有 `SERVING`**；
> 节点健康态即 `HEARTBEAT_CONNECTED`，`SERVING` 只用于 target / chain（`list-targets`、`list-chains`）。

---

## Step 6: Storage service

Install `storage` on **dsksa304 / dsksa305 / dsksa348**（node_id 分别为 10001 / 10002 / 10003）。

1. For each storage node — tune `aio` and prepare directories:
   ```bash
   cat > /etc/sysctl.d/99-3fs.conf <<'EOF'
   fs.aio-max-nr = 67108864
   EOF
   sysctl -w fs.aio-max-nr=67108864
   mkdir -p /storage/data3/3fs /storage/data4/3fs
   ```
2. Copy binary, configs and the FDB cluster file:
   ```bash
   cp ~/3fs/build/bin/storage_main /opt/3fs/bin
   cp ~/3fs/configs/{storage_main.toml,storage_main_launcher.toml,storage_main_app.toml} /opt/3fs/etc
   scp dskna004:/opt/3fs/etc/fdb.cluster /opt/3fs/etc/   # 由 dskna004 推送
   ```
3. Update config files:
   - `storage_main_app.toml`（每台不同）：`node_id = 10001` / `10002` / `10003`
   - `storage_main_launcher.toml`：
     ```toml
     cluster_id = 'stage'

     [mgmtd_client]
     mgmtd_server_addresses = ["RDMA://172.16.12.210:8000"]

     [ib_devices]
     device_filter = []        # 存储节点活动 HCA ≤ 2，无需过滤
     ```
4. On **dskna004**, prepare the storage runtime config (shared by all storage nodes) and upload it to mgmtd:
   ```bash
   cp ~/3fs/configs/storage_main.toml /opt/3fs/etc/storage_main.toml   # 仅用于生成上传内容
   ```

   ```toml
   [server.mgmtd]
   mgmtd_server_addresses = ["RDMA://172.16.12.210:8000"]

   [common.monitor.reporters.monitor_collector]
   remote_ip = '172.16.12.210:10000'

   [server.targets]
   target_paths = ["/storage/data3/3fs", "/storage/data4/3fs"]   # 下标 = create-target 的 --disk-index
   fdp_compaction_stream_id = 2                                   # 1-255；0 = 关闭 compaction 分流
   ```
   ```bash
   CLI set-config --type STORAGE --file /opt/3fs/etc/storage_main.toml
   ```
5. Start storage on each node and verify config is pulled from mgmtd:
   ```bash
   cp ~/3fs/deploy/systemd/storage_main.service /usr/lib/systemd/system
   systemctl daemon-reload && systemctl enable --now storage_main
   grep -a "fdp_compaction_stream_id" /var/log/3fs/storage_main.log | tail -2   # = 2
   ```
   ```bash
   CLI list-nodes        # 10001/10002/10003 STORAGE ... ConfigVersion 1(UPTODATE)
   ```

---

## Step 7: Create admin user, storage targets and chain table

Run on **dskna004**.

1. Create the admin user and save the token (token 由服务端生成，**不要自己造**):
   ```bash
   out=$(CLI "user-add --root --admin 0 root") && echo "$out"
   awk '/^Token/ {print $2}' <<<"$out" | sed 's/(Expired.*//' > /opt/3fs/etc/token.txt
   chmod 600 /opt/3fs/etc/token.txt
   CLIT current-user                        # Uid 0 / Token ...
   ```
2. Create 6 storage targets — 每盘 1 个，`--chain-id` 相同表示同一条链（RF=3，HEAD/MIDDLE/TAIL 各在一个节点）:
   ```bash
   CLIT create-target --node-id 10001 --disk-index 0 --target-id 101000100101 --chain-id 900100001 --use-new-chunk-engine
   CLIT create-target --node-id 10002 --disk-index 0 --target-id 101000200101 --chain-id 900100001 --use-new-chunk-engine
   CLIT create-target --node-id 10003 --disk-index 0 --target-id 101000300101 --chain-id 900100001 --use-new-chunk-engine
   CLIT create-target --node-id 10001 --disk-index 1 --target-id 101000100201 --chain-id 900200001 --use-new-chunk-engine
   CLIT create-target --node-id 10002 --disk-index 1 --target-id 101000200201 --chain-id 900200001 --use-new-chunk-engine
   CLIT create-target --node-id 10003 --disk-index 1 --target-id 101000300201 --chain-id 900200001 --use-new-chunk-engine

   CLIT list-targets
   ```

   > `--use-new-chunk-engine` 是 FDP 生效的前提（旧 chunk engine 不支持 write stream）。
   > 本集群规模小（3 节点 × 2 盘），直接手写即可；更大规模可参考 `~/3fs/deploy/data_placement` 自动生成。

3. Upload chains and the chain table:
   ```bash
   cat > /opt/3fs/etc/generated_chains.csv <<'EOF'
   ChainId,TargetId,TargetId,TargetId
   900100001,101000100101,101000200101,101000300101
   900200001,101000100201,101000200201,101000300201
   EOF

   cat > /opt/3fs/etc/generated_chain_table.csv <<'EOF'
   ChainId
   900100001
   900200001
   EOF

   CLIT upload-chains /opt/3fs/etc/generated_chains.csv
   CLIT upload-chain-table --desc stage 1 /opt/3fs/etc/generated_chain_table.csv
   ```
4. Check chains and chain table:
   ```bash
   CLIT list-chains          # 2 条链，3 个 target 均 SERVING-UPTODATE
   CLIT list-chain-tables    # 1 / 1 / 2 / 3 / stage
   ```

---

## Step 8: FUSE client

Install the client on **dskna004**（生产环境不建议与 service 混部）。

1. Copy binary and configs:
   ```bash
   cp ~/3fs/build/bin/hf3fs_fuse_main /opt/3fs/bin
   cp ~/3fs/configs/{hf3fs_fuse_main.toml,hf3fs_fuse_main_launcher.toml} /opt/3fs/etc
   mkdir -p /3fs/stage
   ```
2. Set cluster id, mount point, token file and mgmtd address in `hf3fs_fuse_main_launcher.toml`:
   ```toml
   cluster_id = 'stage'
   mountpoint = '/3fs/stage'
   token_file = '/opt/3fs/etc/token.txt'

   [mgmtd_client]
   mgmtd_server_addresses = ["RDMA://172.16.12.210:8000"]

   [ib_devices]
   device_filter = ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]
   ```
3. Set mgmtd and monitor address in `hf3fs_fuse_main.toml`:
   ```toml
   [mgmtd]
   mgmtd_server_addresses = ["RDMA://172.16.12.210:8000"]

   [common.monitor.reporters.monitor_collector]
   remote_ip = '172.16.12.210:10000'
   ```
4. Upload the config to mgmtd and start:
   ```bash
   CLI set-config --type FUSE --file /opt/3fs/etc/hf3fs_fuse_main.toml
   cp ~/3fs/deploy/systemd/hf3fs_fuse_main.service /usr/lib/systemd/system
   systemctl daemon-reload && systemctl enable --now hf3fs_fuse_main
   mount | grep '/3fs/stage'
   # hf3fs.stage on /3fs/stage type fuse.hf3fs (rw,...,allow_other,max_read=1048576)
   ```

---

## Step 9: Verification

### Cluster state

```bash
CLI list-nodes                 # 1 / 100 / 10001-10003 全在，非 DISABLED
CLIT list-targets              # 6 行 SERVING/UPTODATE
CLIT list-chains               # 2 条 SERVING
CLIT list-chain-tables         # ChainCount=2 ReplicaCount=3
mount | grep '/3fs/stage'
```

### IO and metrics

```bash
mkdir -p /3fs/stage/test
dd if=/dev/urandom of=/3fs/stage/test/smoke bs=1M count=512 status=none && sync
md5sum /3fs/stage/test/smoke
dd if=/3fs/stage/test/smoke of=/tmp/smoke.copy bs=1M status=none && md5sum /tmp/smoke.copy
rm -f /3fs/stage/test/smoke /tmp/smoke.copy

clickhouse-client --password samsung -q "SELECT count() FROM \`3fs\`.counters"        # > 0 且增长
clickhouse-client --password samsung -q "SELECT count() FROM \`3fs\`.distributions"
```

### FDP write stream

1. FUSE ioctl（客户端侧，`HF3FS_IOC_WRITE_STREAM = 0xC0106810`）:
   ```bash
   python3 - <<'EOF'
   import fcntl, os, struct
   HF = (3 << 30) | (16 << 16) | (0x68 << 8) | 16
   fd = os.open("/3fs/stage/test/fdp_probe", os.O_RDWR | os.O_CREAT, 0o644)
   for op, sid in ((1, 0), (4, 3), (2, 0)):          # GET_MAX / SET 3 / GET
       print(op, struct.unpack("IIII", fcntl.ioctl(fd, HF, struct.pack("IIII", op, sid, 0, 0))))
   os.close(fd); os.unlink("/3fs/stage/test/fdp_probe")
   EOF
   # 1 (1, 0, 255, 0)   FUSE 层固定返回 255，真实上限在存储侧
   # 4 (4, 3, 0, 0)
   # 2 (2, 3, 255, 0)
   ```
2. Storage side — XFS 能力与 compaction 参数:
   ```bash
   python3 - <<'EOF'      # 在存储节点执行；必须读 ioctl 返回值
   import fcntl, os, struct
   p = "/storage/data3/.getmax_probe"
   fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
   ret = fcntl.ioctl(fd, 0xC010662B, struct.pack("IIII", 1, 0, 0, 0))
   print("GET_MAX =", struct.unpack("IIII", ret)[2])       # 14
   os.close(fd); os.unlink(p)
   EOF

   grep -a "fdp_compaction_stream_id" /var/log/3fs/storage_main.log | tail -2   # = 2
   ```
3. End-to-end — NVMe 命令的 placement 字段（`dsmgmt` 高 16 位 = PLID = `stream_id − 1`）。

   在**存储节点**开启 tracepoint（`nvme_setup_cmd` 的 `cdw10[24]` 中第 5 个 DWORD 即 CDW14/dsmgmt）：
   ```bash
   T=/sys/kernel/tracing
   echo > $T/trace
   echo 1 > $T/events/nvme/nvme_setup_cmd/enable
   ```

   在**客户端（dskna004）**按 stream 7 写 256MB：
   ```python
   import fcntl, os, struct
   HF = (3 << 30) | (16 << 16) | (0x68 << 8) | 16            # HF3FS_IOC_WRITE_STREAM
   p = "/3fs/stage/test/fdp7.bin"
   fd = os.open(p, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
   fcntl.ioctl(fd, HF, struct.pack("IIII", 4, 7, 0, 0))      # SET stream 7
   for _ in range(64):
       os.write(fd, b"\xa5" * (4 << 20))                     # 256MB
   os.fsync(fd); os.close(fd); os.unlink(p)
   ```

   回到**存储节点**停止抓取并统计：
   ```bash
   echo 0 > $T/events/nvme/nvme_setup_cmd/enable
   grep -E "nvme3c|nvme4c" $T/trace | grep -o "dsmgmt=[0-9a-fx]*, reftag" | sort | uniq -c
   #  256 dsmgmt=393216, reftag    -> 0x60000，PLID 6（stream 7 - 1）
   ```

   存储侧同时可见 `[FDP_DEBUG] SERVER_WRITE: received streamId=7`、`CLUSTER_PWRITE: streamId=7`。
   若 `dsmgmt=0`，检查是否漏了 `SET`，或设备未暴露写流（`GET_MAX = 0`）。

---

## Step 10: Operations and changes

### 10.1 Change `fdp_compaction_stream_id` (including disabling it with `0`)

该参数是 **startup-loaded**：`set-config` 只更新 mgmtd 中“下次启动使用”的配置，**必须重启 storage 才生效**。

```bash
# 1) dskna004：改运行配置并上传
sed -i 's/^fdp_compaction_stream_id = .*/fdp_compaction_stream_id = 0/' /opt/3fs/etc/storage_main.toml
CLI set-config --type STORAGE --file /opt/3fs/etc/storage_main.toml

# 2) 3 台存储节点：同步本地文件 + 重启（逐台滚动，RF=3 期间不影响读写）
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip '
    sed -i "s/^fdp_compaction_stream_id = .*/fdp_compaction_stream_id = 0/" /opt/3fs/etc/storage_main.toml
    systemctl restart storage_main'
done

# 3) 验证：进程实际加载值应为 0，且不再出现 [FDP] 解析日志
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh root@$ip 'grep -a fdp_compaction_stream_id /var/log/3fs/storage_main.log | tail -2'
done
CLIT list-targets        # 恢复为 6 行 SERVING/UPTODATE
```

改回 `2` 时重复同样步骤，只把 `0` 换回 `2`。

### 10.2 Hot-update tunables without restart

`max_reserved_chunks`、`min_remain_groups` 等属于 `CONFIG_HOT_UPDATED_ITEM`，可热更新
（本环境 `admin_cli` 的子命令要作为**一个字符串**传入）：

```bash
printf '[server.allocate_worker]\nmax_reserved_chunks = "512MB"\n' > /tmp/hot.toml
CLI "hot-update-config -t STORAGE -f /tmp/hot.toml"
```

### 10.3 WAF / write amplification observation

```bash
# 存储节点：NAND 写入量（单位 512KB）
nvme smart-log /dev/nvme3n1 | grep -E "Data Units Written|Percentage Used"

# 负载前后对比（脚本已封装）；WAF = ΔDataUnitsWritten × 512KB ÷ host 写入量
sudo bash 03_setup_storage.sh verify snap
sudo bash 03_setup_storage.sh verify check
```

> PM1763 的 `nvme fdp status` RUAMW 是静态值（写入后不变），不能用于分流观测；
> `nvme fdp stats` 该盘也不支持。物理放置请以 Step 9.3 的 `dsmgmt` 为准。

### 10.4 Reset the cluster (wipe FDB and rebuild)

⚠ 会清空所有文件与 target 数据，仅在参数（`stripesize`/`chunksize`）变更或 FDB 损坏时使用。

```bash
# 1) 停 3FS 服务
systemctl stop hf3fs_fuse_main meta_main mgmtd_main
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh root@$ip 'systemctl stop storage_main; rm -rf /storage/data3/3fs/* /storage/data4/3fs/*'
done

# 2) 清 FDB（单机）
systemctl stop foundationdb
cp -a /var/lib/foundationdb/data/4500 /var/lib/foundationdb/data/4500.bak.$(date +%s)
rm -rf /var/lib/foundationdb/data/4500/*
systemctl start foundationdb && sleep 3
fdbcli --exec "configure new single ssd" && sleep 5 && fdbcli --exec "status minimal"

# 3) 重新分发 fdb.cluster（内容可能已变化）
cp /etc/foundationdb/fdb.cluster /opt/3fs/etc/fdb.cluster
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' scp /opt/3fs/etc/fdb.cluster root@$ip:/opt/3fs/etc/
done

# 4) 依次重跑：mgmtd(init-cluster) → meta → STORAGE 配置 → storage → user/targets/chain → FUSE
sudo bash 02_setup_meta.sh --reset-fdb
#   3 台存储节点各执行：sudo bash 03_setup_storage.sh
sudo bash 04_finalize_cluster.sh
```

### 10.5 Restart order

```bash
# dskna004
systemctl restart mgmtd_main
systemctl restart meta_main
systemctl restart hf3fs_fuse_main          # 挂载点随 FUSE 服务重建

# 3 台存储节点（可并行；逐台滚动更稳）
systemctl restart storage_main
```

顺序：`mgmtd → meta → storage → FUSE`。单独重启 storage 不影响读写（RF=3），但该节点 target 会短暂
`SYNCING`，约 30–60 秒恢复 `SERVING/UPTODATE`。

---

## FAQ

**1. `admin_cli` 报 `6004 MgmtdClient::RoutingInfoNotReady`**
`RDMA://` 里的地址是 TCP 握手端点，`Listener` 只在 `en*/eth*/bond*` 网卡监听。
**必须填管理网 IP**（`RDMA://172.16.12.210:8000`），不能填 IPoIB（10.10.44.x），
IB 只通过 `[ib_devices] device_filter` 参与数据面。

**2. `admin_cli: too many ibdevices ...`**
dskna004 有 8 个活动 HCA，3FS 上限 4，必须在 `admin_cli.toml` / `*_launcher.toml` 中设置
`device_filter = ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]`。

**3. 挂载后写文件报 `Input/output error`**
meta 日志若出现 `Failed to allocate ... chain table 1 have only N chains`，说明
`init-cluster` 的 `stripesize` 大于链数。本集群 6 targets / RF=3 ⇒ 2 条链 ⇒ stripe 必须 ≤ 2。
修改 stripe 需清 FDB 重建（`init-cluster` 不能改已有集群）。

**4. ClickHouse 表为空，monitor 日志报 `unsupported compression method 144`**
ClickHouse 26.x 默认 ZSTD，3FS 内置 clickhouse-cpp 只支持 LZ4。按 Step 1 写
`users.d/zz-3fs-lz4.xml` 并 `SYSTEM RELOAD USERS`（不需要重启 clickhouse-server）。

**5. `GET_MAX` 探测总是返回 0**
Python 的 `bytes` 不可变：`fcntl.ioctl(fd, cmd, ws)` 的结果在**返回值**里，读 `ws` 永远得到初始值 0。
正确写法：`ret = fcntl.ioctl(...); struct.unpack("IIII", ret)[2]`。
本环境正确值为 **14**（硬件 16 − XFS 保留 2），3FS 内部（Rust）用 `&mut ws` 不受此影响。

**6. 节点状态一直是 `HEARTBEAT_CONNECTED`，不是 `SERVING`**
本版本 `flat::NodeStatus` 没有 `SERVING`；节点健康态就是 `HEARTBEAT_CONNECTED`。
`SERVING` 只出现在 `list-targets` / `list-chains` 的 target 状态里。

**7. 从没见过 `[FDP] compaction stream resolved`**
`fdp_compaction_stream_id` 在**首次 compaction 复制**时才懒解析并打印，需同时满足：
`reserved_size > max_reserved_chunks`（默认 1GB）**且** `active_levels` 中存在"半满组"。
顺序写满整组 / 写后删光的负载很难满足，属正常现象，不影响 FDP 数据面（见 Step 9.3）。

**8. 数据盘重启后不见了**
`/storage/data3`、`/storage/data4` 是手工挂载，未写入 `/etc/fstab`。
建议补充（用 UUID）：
```bash
UUID=$(blkid -s UUID -o value /dev/nvme3n1)
echo "UUID=$UUID /storage/data3 xfs noatime,nodiratime 0 0" >> /etc/fstab
```

**9. FDB 显示 `The database is unavailable`**
7.3 的 `fdbcli status json` 在未 configure 的库上会阻塞到超时并返回空，不要据此判断"库损坏"。
全新环境执行 `fdbcli --exec "configure new single ssd"`，等待 `status minimal` 返回 available。

**10. 存储节点上的 `admin_cli` 连不上 FDB**
本环境 FDB 只监听 `127.0.0.1:4500`，仅 dskna004 可访问；所有管理命令（`init-cluster`、
`set-config`、`create-target`、`upload-chains`、`user-add`）都在 dskna004 执行。
