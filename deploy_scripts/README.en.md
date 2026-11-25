# 3FS + XFS FDP Cluster Setup Guide

This document describes the deployment procedure for **this lab environment**. Its chapter structure follows
[`3fs-main/deploy/README.md`](../../3fs-main/deploy/README.md); all parameters are taken from the cluster that is
currently running (dskna004 + dsksa304/305/348).

For background (root causes, verification principles, troubleshooting), see the documents in the same directory:

- `3FS_FDP_部署手册_逐步执行版.md` — self-contained, command-level handbook (Chinese)
- `3FS_FDP_部署手册.md` — deployment record and list of fixes (Chinese)
- `README_执行顺序.md` — script-based deployment quick reference (Chinese)

---

## Installation prerequisites

### Hardware specifications

| Node | OS | Kernel | Management IP | IPoIB | SSD | RDMA | Role |
|---|---|---|---|---|---|---|---|
| dskna004 | Ubuntu 22.04 | 7.0.0-rc2 | 172.16.12.210 | 10.10.44.210 | — | mlx5 × 4 | mgmtd / meta / monitor / FUSE |
| dsksa304 | Ubuntu 22.04 | 7.0.0-rc2 | 172.16.18.64 | 10.10.44.64 | 15.36TB × 2 | mlx5 | storage (node 10001) |
| dsksa305 | Ubuntu 22.04 | 7.0.0-rc2 | 172.16.18.65 | 10.10.44.65 | 15.36TB × 2 | mlx5 | storage (node 10002) |
| dsksa348 | Ubuntu 22.04 | 7.0.0-rc2 | 172.16.18.169 | 10.10.44.169 | 15.36TB × 2 | mlx5 | storage (node 10003) |

Disk layout (identical on all storage nodes):

| Device | Mount point | Usage | Note |
|---|---|---|---|
| `/dev/nvme0n1` | `/` | OS disk | ext4, **do not use** |
| `/dev/nvme1n1` | — | ZFS member | used by another workload, **do not use** |
| `/dev/nvme2n1` | — | ZFS pool `ost00pool` (Lustre OST) | ~10TB already used, **do not use** |
| `/dev/nvme3n1` | `/storage/data3` | 3FS target root | XFS, `noatime,nodiratime` |
| `/dev/nvme4n1` | `/storage/data4` | 3FS target root | XFS, `noatime,nodiratime` |

> Mount command (these mounts are not listed in `/etc/fstab`; they must be mounted manually after a reboot):
> ```bash
> mount -o noatime,nodiratime /dev/nvme3n1 /storage/data3
> mount -o noatime,nodiratime /dev/nvme4n1 /storage/data4
> ```

### Kernel requirement

XFS requires the Samsung FDP patch that provides `FS_IOC_WRITE_STREAM`
(`_IOWR('f', 43, struct fs_write_stream)`).

```bash
uname -r                                   # expect 7.0.0-rc2
grep -rn "FS_IOC_WRITE_STREAM" /usr/src/linux-headers-$(uname -r)/include/uapi/linux/fs.h
```

`XFS GET_MAX = 14` (16 hardware write streams − 2 reserved internally by XFS). `GET_MAX = 0` means the device
exposes no write streams; 3FS then falls back to default placement without reporting an error.
**When probing, always use the ioctl return value** — see [FAQ](#faq).

### Pre-flight checks (run on every node)

```bash
# 1) kernel and ioctl (the FDP patch)
uname -r
grep -rn "FS_IOC_WRITE_STREAM" /usr/src/linux-headers-$(uname -r)/include/uapi/linux/fs.h

# 2) time synchronization (clock drift breaks leases and heartbeats)
chronyc tracking | grep -E "Leap status|System time"          # Leap status : Normal

# 3) binaries
ls -l ~/3fs/build/bin/{admin_cli,mgmtd_main,meta_main,storage_main,hf3fs_fuse_main,monitor_collector_main}

# 4) [storage nodes] FDP device: PIDs must be contiguous starting at 0
for d in /dev/nvme3n1 /dev/nvme4n1; do
  echo "== $d"
  nvme fdp status "$d" -o json | python3 -c \
    "import json,sys;d=json.load(sys.stdin);print('nruhsd',d['nruhsd'],'PIDs',' '.join(str(e['pid']) for e in d['ruhss']))"
done

# 5) [storage nodes] data disks mounted
findmnt -t xfs -o SOURCE,TARGET,OPTIONS

# 6) [dskna004] IB port, dependencies, ssh to storage nodes (needed by Step 6 to push fdb.cluster)
ibstat | grep -c "State:.*Active"                              # >= 1
clickhouse-client --password samsung -q "SELECT version()"
fdbcli --version && ls -l /lib/libfdb_c.so*
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip hostname
done
```

See Step 9.2 for probing `XFS GET_MAX` (always use the ioctl return value, otherwise it reads as 0).

### Third-party dependencies

| Service | Version | Node | Note |
|---|---|---|---|
| [ClickHouse](https://clickhouse.com/docs/install) | 26.10 | dskna004 | `network_compression_method` must be set to LZ4 (Step 1) |
| [FoundationDB](https://apple.github.io/foundationdb/administration.html) | 7.3.63 | dskna004 | single-node `single ssd`; `libfdb_c` must match the server version |

---

## Step 0: Build 3FS

The build artifacts already exist in `~/3fs/build/bin` and are used as-is in this environment
(`-rwxr-xr-x`, built on 2026-11-19):

```bash
ls -l ~/3fs/build/bin/{admin_cli,mgmtd_main,meta_main,storage_main,hf3fs_fuse_main,monitor_collector_main}
```

To rebuild, **keep the build parameters used by the running cluster** — a different `std::shuffle`
implementation makes the binaries incompatible with the deployed data layout:

```bash
cd ~/3fs
cmake -S . -B build \
      -DCMAKE_CXX_COMPILER=clang++-14 -DCMAKE_C_COMPILER=clang-14 \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
      -DSHUFFLE_METHOD=g++11        # the existing cluster is g++11; do not change
cmake --build build -j 32
```

Current build parameters (`build/CMakeCache.txt`): `CMAKE_CXX_COMPILER=/usr/bin/clang++-14`,
`SHUFFLE_METHOD=g++11`.

### Services and clients

| Service | Binary | Config files (under `/opt/3fs/etc`) | NodeID | Node |
|---|---|---|---|---|
| monitor | `monitor_collector_main` | `monitor_collector_main.toml` | — | dskna004 |
| admin_cli | `admin_cli` | `admin_cli.toml` + `fdb.cluster` | — | dskna004 |
| mgmtd | `mgmtd_main` | `mgmtd_main_launcher.toml`<br>`mgmtd_main.toml`<br>`mgmtd_main_app.toml`<br>`fdb.cluster` | 1 | dskna004 |
| meta | `meta_main` | `meta_main_launcher.toml`<br>`meta_main.toml`<br>`meta_main_app.toml`<br>`fdb.cluster` | 100 | dskna004 |
| storage | `storage_main` | `storage_main_launcher.toml`<br>`storage_main.toml`<br>`storage_main_app.toml` | 10001 / 10002 / 10003 | dsksa304 / 305 / 348 |
| client | `hf3fs_fuse_main` | `hf3fs_fuse_main_launcher.toml`<br>`hf3fs_fuse_main.toml` | — | dskna004 |

Cluster constants (all following commands are based on these values):

```bash
CLUSTER_ID=stage
MOUNT_POINT=/3fs/stage
MGMTD_ADDR='RDMA://172.16.12.210:8000'     # must be the management-network IP, not IPoIB
MONITOR_ADDR=172.16.12.210:10000
INIT_CHAIN_TABLE_ID=1
INIT_CHUNK_SIZE=1048576
INIT_STRIP_SIZE=2                          # must be <= number of chains (6 targets / RF=3 => 2 chains)
FDP_COMPACTION_STREAM_ID=2
STORAGE_HOSTS="172.16.18.64 172.16.18.65 172.16.18.169"
```

### Base directories (all nodes)

All services install binaries into `/opt/3fs/bin`, read configs from `/opt/3fs/etc` and write logs to
`/var/log/3fs`:

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

**Must do**: ClickHouse 26.x defaults to `network_compression_method=ZSTD`, while the clickhouse-cpp bundled
with 3FS only implements LZ4. Without this change, `monitor_collector` fails with
`unsupported compression method 144` and the metrics tables stay empty.

```bash
clickhouse-client --password samsung -q \
  "SELECT value FROM system.settings WHERE name='network_compression_method'"   # expect lz4
```

If the value is not `lz4`:

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
clickhouse-client --password samsung -q "SYSTEM RELOAD USERS"                   # no service restart required
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
   device_filter = ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]   # keep in sync with admin_cli/mgmtd (dskna004 has 8 active HCAs)
   ```
3. Start service:
   ```bash
   cp ~/3fs/deploy/systemd/monitor_collector_main.service /usr/lib/systemd/system
   systemctl daemon-reload && systemctl enable --now monitor_collector_main
   ss -lntp | grep 10000        # 172.16.12.210:10000
   ```

---

## Step 3: Admin client

Install `admin_cli` on **dskna004** (a copy may also be placed on the storage nodes for local debugging only;
FDB listens on `127.0.0.1`, so all management commands run on dskna004).

1. Check FoundationDB, create the cluster file if missing:
   ```bash
   fdbcli --exec "status minimal"                 # The database is available.
   cat /etc/foundationdb/fdb.cluster              # 3fsfdp:xxxxxxxx@127.0.0.1:4500
   cp /etc/foundationdb/fdb.cluster /opt/3fs/etc/fdb.cluster && chmod 644 /opt/3fs/etc/fdb.cluster
   ```

   Key settings for the single-node FDB (`/etc/foundationdb/foundationdb.conf`, values used here):

   ```toml
   [fdbmonitor]
   user = foundationdb
   group = foundationdb

   [general]
   cluster-file = /etc/foundationdb/fdb.cluster

   [fdbserver]
   command = /usr/sbin/fdbserver
   public-address = auto:$ID
   listen-address = public          # binds 127.0.0.1:4500 only, hence all admin commands run on dskna004
   datadir = /var/lib/foundationdb/data/$ID
   logdir = /var/log/foundationdb

   [fdbserver.4500]
   ```

   If the database has not been initialized yet (fresh environment):
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
   device_filter = ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]   # dskna004 has 8 active HCAs; 3FS supports at most 4
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

4. (Optional) Install `admin_cli` on each storage node — for local self-test only: FDB listens on
   `127.0.0.1` and all management commands run on dskna004 (see FAQ 10):
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

   > - `1` — chain table ID
   > - `1048576` — chunk size in bytes
   > - `2` — file strip size, **must be ≤ the number of chains** (2 chains here; setting `16` makes all
   >   write requests fail with `EIO`, see FAQ)
   >
   > Once written to FDB, `stripesize` and `chunksize` cannot be changed; resizing requires wiping FDB and
   > re-initializing the cluster.

4. Upload the mgmtd runtime config:
   ```bash
   CLI set-config --type MGMTD --file /opt/3fs/etc/mgmtd_main.toml
   CLI list-nodes                                  # ConfigVersion becomes UPTODATE
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
3. Upload the config to mgmtd and start the service:
   ```bash
   CLI set-config --type META --file /opt/3fs/etc/meta_main.toml
   cp ~/3fs/deploy/systemd/meta_main.service /usr/lib/systemd/system
   systemctl daemon-reload && systemctl enable --now meta_main
   CLI list-nodes                                  # META 100  HEARTBEAT_CONNECTED
   ```

> In this release `flat::NodeStatus` only contains `PRIMARY_MGMTD / HEARTBEAT_CONNECTED / ...` and has
> **no `SERVING`**; the healthy state of a node is `HEARTBEAT_CONNECTED`. `SERVING` is only used for
> target / chain states (`list-targets`, `list-chains`).

---

## Step 6: Storage service

Install `storage` on **dsksa304 / dsksa305 / dsksa348** (node_id 10001 / 10002 / 10003 respectively).

1. On each storage node — tune `aio` and prepare the directories:
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
   scp dskna004:/opt/3fs/etc/fdb.cluster /opt/3fs/etc/   # pushed from dskna004
   ```
3. Update config files:
   - `storage_main_app.toml` (different per node): `node_id = 10001` / `10002` / `10003`
   - `storage_main_launcher.toml`:
     ```toml
     cluster_id = 'stage'

     [mgmtd_client]
     mgmtd_server_addresses = ["RDMA://172.16.12.210:8000"]

     [ib_devices]
     device_filter = []        # storage nodes have <= 2 active HCAs, no filter needed
     ```
4. On **dskna004**, prepare the storage runtime config (shared by all storage nodes) and upload it to mgmtd:
   ```bash
   cp ~/3fs/configs/storage_main.toml /opt/3fs/etc/storage_main.toml   # only used to generate the uploaded config
   ```

   ```toml
   [server.mgmtd]
   mgmtd_server_addresses = ["RDMA://172.16.12.210:8000"]

   [common.monitor.reporters.monitor_collector]
   remote_ip = '172.16.12.210:10000'

   [server.targets]
   target_paths = ["/storage/data3/3fs", "/storage/data4/3fs"]   # index == --disk-index of create-target
   fdp_compaction_stream_id = 2                                   # 1-255; 0 = disable compaction stream steering
   ```
   ```bash
   CLI set-config --type STORAGE --file /opt/3fs/etc/storage_main.toml
   ```
5. Start storage on each node and verify that the config was pulled from mgmtd:
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

1. Create the admin user and save the token (the token is generated by the server, **never craft it yourself**):
   ```bash
   out=$(CLI "user-add --root --admin 0 root") && echo "$out"
   awk '/^Token/ {print $2}' <<<"$out" | sed 's/(Expired.*//' > /opt/3fs/etc/token.txt
   chmod 600 /opt/3fs/etc/token.txt
   CLIT current-user                        # Uid 0 / Token ...
   ```
2. Create 6 storage targets — one per disk; targets sharing the same `--chain-id` form one chain
   (RF=3, one HEAD/MIDDLE/TAIL per node):
   ```bash
   CLIT create-target --node-id 10001 --disk-index 0 --target-id 101000100101 --chain-id 900100001 --use-new-chunk-engine
   CLIT create-target --node-id 10002 --disk-index 0 --target-id 101000200101 --chain-id 900100001 --use-new-chunk-engine
   CLIT create-target --node-id 10003 --disk-index 0 --target-id 101000300101 --chain-id 900100001 --use-new-chunk-engine
   CLIT create-target --node-id 10001 --disk-index 1 --target-id 101000100201 --chain-id 900200001 --use-new-chunk-engine
   CLIT create-target --node-id 10002 --disk-index 1 --target-id 101000200201 --chain-id 900200001 --use-new-chunk-engine
   CLIT create-target --node-id 10003 --disk-index 1 --target-id 101000300201 --chain-id 900200001 --use-new-chunk-engine

   CLIT list-targets
   ```

   > `--use-new-chunk-engine` is a prerequisite for FDP (the legacy chunk engine does not support write
   > streams). With 3 nodes × 2 disks the target list is written by hand; for larger clusters use
   > `~/3fs/deploy/data_placement` to generate it.

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
4. Check chains and the chain table:
   ```bash
   CLIT list-chains          # 2 chains, each with 3 targets SERVING-UPTODATE
   CLIT list-chain-tables    # 1 / 1 / 2 / 3 / stage
   ```

---

## Step 8: FUSE client

Install the client on **dskna004** (co-locating clients with service nodes is not recommended in production).

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
3. Set mgmtd and monitor addresses in `hf3fs_fuse_main.toml`:
   ```toml
   [mgmtd]
   mgmtd_server_addresses = ["RDMA://172.16.12.210:8000"]

   [common.monitor.reporters.monitor_collector]
   remote_ip = '172.16.12.210:10000'
   ```
4. Upload the config to mgmtd and start the client:
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
CLI list-nodes                 # 1 / 100 / 10001-10003 present, none DISABLED
CLIT list-targets              # 6 rows SERVING/UPTODATE
CLIT list-chains               # 2 chains SERVING
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

clickhouse-client --password samsung -q "SELECT count() FROM \`3fs\`.counters"        # > 0 and increasing
clickhouse-client --password samsung -q "SELECT count() FROM \`3fs\`.distributions"
```

### FDP write stream

1. FUSE ioctl (client side, `HF3FS_IOC_WRITE_STREAM = 0xC0106810`):
   ```bash
   python3 - <<'EOF'
   import fcntl, os, struct
   HF = (3 << 30) | (16 << 16) | (0x68 << 8) | 16
   fd = os.open("/3fs/stage/test/fdp_probe", os.O_RDWR | os.O_CREAT, 0o644)
   for op, sid in ((1, 0), (4, 3), (2, 0)):          # GET_MAX / SET 3 / GET
       print(op, struct.unpack("IIII", fcntl.ioctl(fd, HF, struct.pack("IIII", op, sid, 0, 0))))
   os.close(fd); os.unlink("/3fs/stage/test/fdp_probe")
   EOF
   # 1 (1, 0, 255, 0)   FUSE always reports 255; the real limit lives on the storage side
   # 4 (4, 3, 0, 0)
   # 2 (2, 3, 255, 0)
   ```
2. Storage side — XFS capability and the compaction parameter:
   ```bash
   python3 - <<'EOF'      # run on a storage node; must use the ioctl return value
   import fcntl, os, struct
   p = "/storage/data3/.getmax_probe"
   fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
   ret = fcntl.ioctl(fd, 0xC010662B, struct.pack("IIII", 1, 0, 0, 0))
   print("GET_MAX =", struct.unpack("IIII", ret)[2])       # 14
   os.close(fd); os.unlink(p)
   EOF

   grep -a "fdp_compaction_stream_id" /var/log/3fs/storage_main.log | tail -2   # = 2
   ```
3. End-to-end — the placement field of the NVMe command (`dsmgmt` bits 31:16 = PLID = `stream_id − 1`).

   Enable the tracepoint on a **storage node** (`cdw10[24]` of `nvme_setup_cmd` covers CDW10..CDW15; the 5th
   DWORD is CDW14, i.e. `dsmgmt`):
   ```bash
   T=/sys/kernel/tracing
   echo > $T/trace
   echo 1 > $T/events/nvme/nvme_setup_cmd/enable
   ```

   On the **client (dskna004)** write 256MB with stream 7:
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

   Back on the **storage node**, stop tracing and aggregate:
   ```bash
   echo 0 > $T/events/nvme/nvme_setup_cmd/enable
   grep -E "nvme3c|nvme4c" $T/trace | grep -o "dsmgmt=[0-9a-fx]*, reftag" | sort | uniq -c
   #  256 dsmgmt=393216, reftag    -> 0x60000, PLID 6 (stream 7 - 1)
   ```

   The storage side also logs `[FDP_DEBUG] SERVER_WRITE: received streamId=7` and
   `CLUSTER_PWRITE: streamId=7`. If `dsmgmt=0`, check that the `SET` was issued, or that the device exposes
   write streams (`GET_MAX = 0` means it does not).

---

## Step 10: Operations and changes

### 10.1 Change `fdp_compaction_stream_id` (including disabling it with `0`)

This parameter is **startup-loaded**: `set-config` only updates what mgmtd serves for the next start, so the
storage service **must be restarted** for the change to take effect.

```bash
# 1) dskna004: update the runtime config and upload it
sed -i 's/^fdp_compaction_stream_id = .*/fdp_compaction_stream_id = 0/' /opt/3fs/etc/storage_main.toml
CLI set-config --type STORAGE --file /opt/3fs/etc/storage_main.toml

# 2) all three storage nodes: sync the local file and restart (rolling; RF=3 keeps serving)
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip '
    sed -i "s/^fdp_compaction_stream_id = .*/fdp_compaction_stream_id = 0/" /opt/3fs/etc/storage_main.toml
    systemctl restart storage_main'
done

# 3) verify: the process should load 0 and no [FDP] resolution log should appear
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh root@$ip 'grep -a fdp_compaction_stream_id /var/log/3fs/storage_main.log | tail -2'
done
CLIT list-targets        # back to 6 rows of SERVING/UPTODATE
```

To restore `2`, run the same steps with `0` replaced by `2`.

### 10.2 Hot-update tunables without restart

`max_reserved_chunks`, `min_remain_groups` and similar knobs are `CONFIG_HOT_UPDATED_ITEM`s. In this
environment the `admin_cli` sub-command must be passed as **a single string**:

```bash
printf '[server.allocate_worker]\nmax_reserved_chunks = "512MB"\n' > /tmp/hot.toml
CLI "hot-update-config -t STORAGE -f /tmp/hot.toml"
```

### 10.3 WAF / write amplification observation

```bash
# storage node: NAND writes (unit = 512KB)
nvme smart-log /dev/nvme3n1 | grep -E "Data Units Written|Percentage Used"

# compare before/after a workload (wrapped by the script); WAF = ΔDataUnitsWritten × 512KB ÷ host writes
sudo bash 03_setup_storage.sh verify snap
sudo bash 03_setup_storage.sh verify check
```

> On the PM1763 the `nvme fdp status` RUAMW value is static (it does not change with writes), so it cannot be
> used to observe placement; `nvme fdp stats` is unsupported on this drive as well. Use the `dsmgmt` evidence
> from Step 9.3 instead.

### 10.4 Reset the cluster (wipe FDB and rebuild)

⚠ Deletes all files and target data. Only use it when changing `stripesize`/`chunksize` or when FDB is
corrupted.

```bash
# 1) stop 3FS services
systemctl stop hf3fs_fuse_main meta_main mgmtd_main
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh root@$ip 'systemctl stop storage_main; rm -rf /storage/data3/3fs/* /storage/data4/3fs/*'
done

# 2) wipe FDB (single node)
systemctl stop foundationdb
cp -a /var/lib/foundationdb/data/4500 /var/lib/foundationdb/data/4500.bak.$(date +%s)
rm -rf /var/lib/foundationdb/data/4500/*
systemctl start foundationdb && sleep 3
fdbcli --exec "configure new single ssd" && sleep 5 && fdbcli --exec "status minimal"

# 3) redistribute fdb.cluster (its content may have changed)
cp /etc/foundationdb/fdb.cluster /opt/3fs/etc/fdb.cluster
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' scp /opt/3fs/etc/fdb.cluster root@$ip:/opt/3fs/etc/
done

# 4) rerun in order: mgmtd (init-cluster) → meta → STORAGE config → storage → user/targets/chains → FUSE
sudo bash 02_setup_meta.sh --reset-fdb
#   on each storage node: sudo bash 03_setup_storage.sh
sudo bash 04_finalize_cluster.sh
```

### 10.5 Restart order

```bash
# dskna004
systemctl restart mgmtd_main
systemctl restart meta_main
systemctl restart hf3fs_fuse_main          # the mount point is recreated with the FUSE service

# three storage nodes (parallel is fine; rolling is safer)
systemctl restart storage_main
```

Order: `mgmtd → meta → storage → FUSE`. Restarting a single storage node does not interrupt IO (RF=3), but its
targets briefly go `SYNCING` and return to `SERVING/UPTODATE` within ~30–60 seconds.

---

## FAQ

**1. `admin_cli` fails with `6004 MgmtdClient::RoutingInfoNotReady`**
The host inside `RDMA://` is the TCP handshake endpoint; `Listener` only binds on `en*/eth*/bond*` NICs.
**It must be the management-network IP** (`RDMA://172.16.12.210:8000`), never the IPoIB address
(10.10.44.x). IB participates in the data path only through `[ib_devices] device_filter`.

**2. `admin_cli: too many ibdevices ...`**
dskna004 has 8 active HCAs while 3FS supports at most 4, so `device_filter` must be set in
`admin_cli.toml` / `*_launcher.toml`:
`device_filter = ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]`.

**3. Writing to the mount returns `Input/output error`**
If the meta log shows `Failed to allocate ... chain table 1 have only N chains`, the `stripesize` passed to
`init-cluster` is larger than the number of chains. With 6 targets / RF=3 there are 2 chains, so the stripe
must be ≤ 2. Changing it requires wiping FDB and re-initializing (`init-cluster` cannot modify an existing
cluster).

**4. ClickHouse tables stay empty and the monitor logs `unsupported compression method 144`**
ClickHouse 26.x defaults to ZSTD while the clickhouse-cpp bundled with 3FS only supports LZ4. Follow Step 1
to add `users.d/zz-3fs-lz4.xml` and run `SYSTEM RELOAD USERS` (no restart of clickhouse-server needed).

**5. `GET_MAX` probing always returns 0**
Python `bytes` objects are immutable: `fcntl.ioctl(fd, cmd, ws)` writes the result into the **return value**,
so reading `ws` always yields the initial 0. Use `ret = fcntl.ioctl(...); struct.unpack("IIII", ret)[2]`.
The correct value in this environment is **14** (16 hardware streams − 2 reserved by XFS). The Rust code
inside 3FS passes `&mut ws` and is not affected by this pitfall.

**6. Nodes stay in `HEARTBEAT_CONNECTED` instead of `SERVING`**
`flat::NodeStatus` in this release has no `SERVING`; `HEARTBEAT_CONNECTED` is the healthy state.
`SERVING` only appears for target / chain states in `list-targets` / `list-chains`.

**7. `[FDP] compaction stream resolved` never appears**
`fdp_compaction_stream_id` is resolved lazily on the **first compaction copy** and logged once. It requires
both `reserved_size > max_reserved_chunks` (default 1GB) **and** a "partially used" group in
`active_levels`. Sequential writes that fill whole groups, or write-then-delete workloads, rarely satisfy
this — that is expected and does not affect the FDP data path (see Step 9.3).

**8. The data disks disappear after a reboot**
`/storage/data3` and `/storage/data4` are mounted manually and are not listed in `/etc/fstab`. Add them
(preferably by UUID):
```bash
UUID=$(blkid -s UUID -o value /dev/nvme3n1)
echo "UUID=$UUID /storage/data3 xfs noatime,nodiratime 0 0" >> /etc/fstab
```

**9. FDB reports `The database is unavailable`**
On FDB 7.3, `fdbcli status json` blocks until timeout and returns nothing when the database has never been
configured — do not treat that as corruption. On a fresh environment run
`fdbcli --exec "configure new single ssd"` and wait until `status minimal` reports available.

**10. `admin_cli` on a storage node cannot reach FDB**
In this environment FDB listens on `127.0.0.1:4500` only, so it is reachable from dskna004 alone. All
management commands (`init-cluster`, `set-config`, `create-target`, `upload-chains`, `user-add`) are executed
on dskna004.
