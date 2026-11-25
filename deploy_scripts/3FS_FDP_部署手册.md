# 3FS + XFS FDP 集群部署手册（dskna004 + dsksa304/305/348）

> 适用对象：本仓库 `3fs-main`（含 FDP write stream 扩展）在本实验环境的**完整、可复现**部署。
> 本手册替代旧文档 `../3fs_fdp_deployment_guide.md` 中已过时的部分（差异见 §7）。
> 所有命令均在本环境实测通过；脚本入口见同目录 `01_precheck.sh` / `02_setup_meta.sh` /
> `03_setup_storage.sh` / `04_finalize_cluster.sh`（共享库 `common.sh`）。

---

## 1. 部署结论（本次实测结果）

| 项 | 结果 |
|---|---|
| 部署状态 | **成功**，4 步脚本（01→04）全部通过，可幂等重跑 |
| 集群 | mgmtd(1) + meta(100) + storage(10001/10002/10003)，全部心跳正常 |
| 存储 | 6 targets（3 节点 × 2 盘 × 1 target/盘）、2 条链、RF=3，全部 `SERVING/UPTODATE` |
| 文件系统 | FUSE 挂载 `/3fs/stage`，512MB 写读 md5 一致 |
| FDP 软件链路 | 客户端 `ioctl SET stream 3` → 存储 `[FDP_DEBUG] SERVER_WRITE received streamId=3` → 内核 `write with stream 3`（NVMe 命令带 placement 信息）**全链路打通** |
| FDP 物理放置 | **已验证生效**：`XFS GET_MAX = 14`，NVMe 命令 `dsmgmt` 高位 = `stream_id − 1`（stream 3→PLID 2、stream 7→PLID 6，详见 §8.3） |
| 监控 | ClickHouse `3fs.counters` 持续写入（实测 30 万+ 行） |

集群拓扑（**服务间地址一律使用管理网 IP，不是 IPoIB**，原因见 §7.2）：

| 节点 | 角色 | 管理网 IP | IPoIB | node_id |
|---|---|---|---|---|
| dskna004 | mgmtd + meta + monitor + FUSE | **172.16.12.210** | 10.10.44.210 | mgmtd=1, meta=100 |
| dsksa304 | storage | 172.16.18.64 | 10.10.44.64 | 10001 |
| dsksa305 | storage | 172.16.18.65 | 10.10.44.65 | 10002 |
| dsksa348 | storage | 172.16.18.169 | 10.10.44.169 | 10003 |

关键参数：`cluster_id=stage`；`mgmtd=RDMA://172.16.12.210:8000`；
`monitor=172.16.12.210:10000`；`init-cluster 1 1048576 2`（链表 1 / chunk 1MB / **stripe 2**）；
`fdp_compaction_stream_id = 2`。

---

## 2. 官方部署流程梳理（`3fs-main/deploy/README.md`）

| 官方步骤 | 内容 | 本环境对应 |
|---|---|---|
| 前置 | 硬件（meta 1 + storage N）、RDMA、ClickHouse、FoundationDB（**客户端与服务端版本必须一致**） | ClickHouse 26.10、FDB 7.3.63（`/lib/libfdb_c.so` 与 server 同为 7.3.63） |
| Step 0 | 编译 3FS，产物在 `build/bin` | 已完成（4 台均有 `admin_cli storage_main mgmtd_main meta_main hf3fs_fuse_main monitor_collector_main`） |
| Step 1 | ClickHouse 建表 `deploy/sql/3fs-monitor.sql` | `02` 第 1 步 |
| Step 2 | `monitor_collector`（meta 节点） | `02` 第 2 步 |
| Step 3 | `admin_cli` + `fdb.cluster`（**所有节点**） | `02` 第 4–5 步（含 scp 分发） |
| Step 4 | `mgmtd` + `init-cluster` | `02` 第 6 步 |
| Step 5 | `meta` + `set-config --type META` | `02` 第 7 步 |
| Step 6 | `storage`（XFS 数据盘、`fs.aio-max-nr`、`--use-new-chunk-engine` 前置） | `03` |
| Step 7 | 建用户 / targets / 链 / 链表 | `04` 第 2–4 步 |
| Step 8 | FUSE 客户端挂载 | `04` 第 6 步 |
| FAQ | 服务起不来先看 `journalctl` 与 `/var/log/3fs/`；改 `*_main.toml` 必须 `set-config` | §9 |

官方未写、但本环境必须做的三件事：**IB 设备过滤**、**ClickHouse 压缩方式**、**stripe ≤ 链数**（见 §7）。

---

## 3. 依赖与预检（`01_precheck.sh`，4 台各跑一次）

```bash
sudo bash 01_precheck.sh
```

检查项与判定：

| 检查 | 期望 | 失败处理 |
|---|---|---|
| 内核 | `uname -r` = `7.0.0-rc2`，头文件含 `FS_IOC_WRITE_STREAM` | 换内核/改 GRUB（本次已锁定，脚本不再动） |
| chrony | `Leap status : Normal` | 修时间同步，否则租约异常 |
| 3FS 二进制 | meta 节点 6 个、存储节点 2 个 | 重新编译 |
| FDP 设备（存储） | `nvme fdp status` 有 PID 列表且从 0 连续 | 盘未开 FDP |
| `XFS GET_MAX`（存储） | `>=3` 可分流，**本环境实测 14** | `0` 表示设备未暴露写流（仅回退默认放置，不阻塞部署） |
| IB 端口 | 至少 1 个 Active | 查 `ibstat` |
| FDB（meta） | `fdbcli` 存在、`libfdb_c` 存在 | 装对应 deb |
| ClickHouse（meta） | `clickhouse-client -q "SELECT 1"` | 启动 clickhouse-server |
| ssh（meta） | 到 3 台存储 `root@IP` 免交互可登录 | 装 `sshpass`、核对密码 |

> 存储节点上 `fs.aio-max-nr` 由 `03` 在线调为 `67108864`，无需手工改。

---

## 4. 部署步骤

### 4.1 第 1 步：预检

```bash
# 4 台节点分别执行
sudo bash 01_precheck.sh
```
**目的**：确认内核 FDP 能力、FDP 设备、二进制、时间同步、ssh/ClickHouse/FDB 可用。
**预期**：末尾输出 `===== 全部通过 =====`；存储节点应显示 `GET_MAX = 14 — FDP 分流可用`。

---

### 4.2 第 2 步：meta 节点一体化部署（仅 dskna004）

```bash
sudo bash 02_setup_meta.sh              # 正常部署 / 幂等重跑
sudo bash 02_setup_meta.sh --reset-fdb  # FDB 数据损坏或需重建集群状态时
```

依次完成 9 个小步：

| 小步 | 做什么 | 预期输出 |
|---|---|---|
| 1/9 | ClickHouse 建表 + 把网络压缩改为 **LZ4**（§7.4） | `counters / distributions 就绪`、`ClickHouse 网络压缩已是 LZ4` |
| 2/9 | 安装并启动 `monitor_collector`（监听 172.16.12.210:10000） | `monitor_collector 已运行` |
| 3/9 | 检查/修复 FDB：服务→进程→配置→可用性，未配置则 `configure new single ssd` | `FDB 数据库可用`、`fdb.cluster: 3fsfdp:xxxx@127.0.0.1:4500` |
| 4/9 | 把 `fdb.cluster` 推到 3 台存储节点（`/opt/3fs/etc/fdb.cluster`） | 3 行 `— OK` |
| 5/9 | 安装 `admin_cli` + 生成 `admin_cli.toml`（含 IB 过滤） | `admin_cli 就绪` |
| 6/9 | 安装 `mgmtd`；`init-cluster 1 1048576 2`（FDB 哨兵键幂等）；启动；`set-config --type MGMTD` 同步运行时配置 | `mgmtd (node 1) 已 SERVING` |
| 7/9 | 安装 `meta`；`set-config --type META`；启动 | `meta (node 100) 已 SERVING` |
| 8/9 | 上传 STORAGE 运行时配置（`fdp_compaction_stream_id=2`） | `已上传 — 存储节点现在可以启动并拉取配置` |
| 9/9 | 收尾提示 | — |

**注意**：`init-cluster` 参数一旦写进 FDB 就不可改（改则必须清 FDB 重跑，FAQ 明确）。
本脚本用 FDB 内的哨兵键 `deploy_3fs_init_marker = stage:1:1048576:2` 判断是否已初始化，
FDB 被清空后会自动重新 init-cluster，不会出现"mgmtd 空库起不来"。

---

### 4.3 第 3 步：存储节点部署（3 台各一次）

```bash
# dsksa304 / dsksa305 / dsksa348 分别执行
sudo bash 03_setup_storage.sh
```

| 小步 | 做什么 | 预期 |
|---|---|---|
| 1/4 | `fs.aio-max-nr=67108864`（在线生效）+ 建 `/storage/data{3,4}/3fs` | `在线生效, 无需重启` |
| 2/4 | 安装 `admin_cli`（空 IB 过滤）+ 校验 `fdb.cluster` 存在 | `admin_cli 就绪 (node_id=1000x)` |
| 3/4 | 安装 `storage_main`，写 app/launcher/runtime 配置 | `配置写入完成` |
| 4/4 | 启动 `storage_main`，从 mgmtd 拉取配置 | `storage_main (node 1000x) 已启动` |

**预期**：回到 dskna004 执行 `admin_cli list-nodes` 能看到 3 个 STORAGE 节点，且
`ConfigVersion 1(UPTODATE)`（说明 `fdp_compaction_stream_id` 等配置已下发）。

---

### 4.4 第 4 步：收尾（仅 dskna004）

```bash
sudo bash 04_finalize_cluster.sh
```

| 小步 | 做什么 | 预期 |
|---|---|---|
| 1/7 | 等 3 个 storage 注册 | `3 个 storage 节点已注册` |
| 2/7 | 建 root 用户并保存 token（**token 必须由服务端生成**，§7.6） | `token 已保存到 /opt/3fs/etc/token.txt (权限 600)` |
| 3/7 | 建 6 个 target（`--use-new-chunk-engine`，每盘 1 个） | 6 行 `Create target ... succeeded` |
| 4/7 | 上传 2 条链 + 链表（tableId=1） | `Upload 2 chains succeeded`、`Upload ChainTableId(1) ... succeeded` |
| 5/7 | 等 meta/storage 心跳 + 6 targets `SERVING` | `6 个 target 全部 SERVING` |
| 6/7 | 安装 FUSE 客户端并挂载 `/3fs/stage` | `已挂载: /3fs/stage` |
| 7/7 | 冒烟：512MB 读写 md5、FUSE FDP ioctl、ClickHouse 计数 | `512MB 读写数据一致`、`GET_MAX = 255`、`SET 3 → GET = 3`、`counters 行数 = N` |

**预期最终输出**：`===== 集群部署完成 =====`

---

## 5. 部署后的状态自检（可直接复制）

```bash
# dskna004
cd /home/smrc/lzh/shell/deploy_scripts && source ./common.sh
admin_cli list-nodes                 # 1/100/10001-10003 全在，状态非 DISABLED
admin_cli_token list-targets         # 6 行 SERVING/UPTODATE
admin_cli_token list-chains          # 2 条链 SERVING，3 个 target 均 SERVING-UPTODATE
admin_cli_token list-chain-tables    # 1 / 1 / 2 / 3 / stage
mount | grep /3fs/stage
clickhouse-client --password samsung -q "SELECT count() FROM \`3fs\`.counters"

# 3 台存储节点
sudo bash 03_setup_storage.sh verify status     # RUAMW + GET_MAX + DUW
sudo bash 03_setup_storage.sh verify snap       # WAF 基线
sudo bash 03_setup_storage.sh verify check      # 与基线对比
```

---

## 6. 目录与文件清单

| 文件 | 作用 |
|---|---|
| `common.sh` | 共享库：节点角色映射、SSH、`admin_cli` 封装、**官方模板派生配置**（`render_toml`） |
| `01_precheck.sh` | 只读预检（4 台） |
| `02_setup_meta.sh` | meta 节点：ClickHouse/monitor/FDB/admin_cli/mgmtd/meta/STORAGE 配置（支持 `--reset-fdb`） |
| `03_setup_storage.sh` | 存储节点：调优 + admin_cli + storage 安装启动；`verify status\|snap\|check` |
| `04_finalize_cluster.sh` | 用户/targets/链/链表/FUSE/冒烟 |
| `fdp_stream_write.py` | 经 FUSE 以指定 stream 写数据（FDP 验证 / WAF 试验用） |
| `README_执行顺序.md` | 执行顺序与运维速查 |
| 本文件 | 完整部署手册 |

配置模板来源：`/home/smrc/lzh/3fs-main/configs/*.toml`（官方样例），脚本只覆盖少量键值，
其余（线程池、IB、网络、日志、服务组）保持官方默认 —— 这是能一次跑通的关键（§7.3）。

---

## 7. 本次部署修复的问题（旧脚本/旧文档的缺陷）

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 7.1 | `02` 第 3 步 `[FATAL] FDB status 不可解析且数据目录非空` | ① FDB 7.3 未 configure 时 `fdbcli --exec "status json"` 会**阻塞到超时返回空**，脚本误判"损坏"；② 全新 fdbserver 启动即生成 `coordination-*.fdq`，被当作"损坏证据" | 改为"先判 available；不可用且未配置就直接 `configure new single ssd`，再等可用"；删掉数据目录启发式；新增 `--reset-fdb`（停服→备份 data→重建 cluster 文件→configure） |
| 7.2 | `admin_cli list-nodes` 报 `6004 MgmtdClient::RoutingInfoNotReady`，服务日志报文 `Connection refused` | **3FS 的 RDMA 地址填的是 TCP 握手端点的以太网 IP**：`Listener.cc:33 checkNicType()` 对 `Address::RDMA` 只挑 `en*/eth*/bond*/xgbe*` 网卡监听，数据面才走 IB。旧文档要求填 IPoIB 地址（10.10.44.x），服务实际绑在 172.16.x.x 上 | `MGMTD_ADDR=RDMA://172.16.12.210:8000`、`MONITOR_ADDR=172.16.12.210:10000`；IB 只通过 `[ib_devices] device_filter` 参与数据面 |
| 7.3 | mgmtd/meta 起来后不监听、或 `Server::groups().front()` 崩溃 | 旧脚本手写"极简"运行时配置，缺少 `[[server.base.groups]]`（`Server.h` 的 `CONFIG_OBJ_ARRAY(groups, ..., 4)` 默认长度 1 且 `services` 为空），服务组没有服务/监听项 | 全部配置改为**从官方 `configs/*.toml` 派生**（`render_toml` 精确覆盖键值 + `tomli` 语法校验） |
| 7.4 | monitor 日志刷 `ClickHouse insert counters failed: unsupported compression method 144`，CH 表无数据 | ClickHouse 26.x 默认 `network_compression_method=ZSTD(0x90=144)`，而 3FS 内置 clickhouse-cpp 只实现 LZ4 | 写 `/etc/clickhouse-server/users.d/zz-3fs-lz4.xml` 把 default profile 降为 LZ4 + `SYSTEM RELOAD USERS`（**不重启 clickhouse-server**） |
| 7.5 | 挂载后写入报 `Input/output error`，meta 日志 `ChainAllocator.h:108 Failed to allocate ... chain table 1 have only 2 chains` | `ChainAllocator` 要求 **链数 ≥ stripeSize**；旧文档用 `init-cluster 1 1048576 16` 但本集群只有 2 条链（3 节点×2 盘×1 target，RF=3 的上限） | `init-cluster 1 1048576 **2**`；`common.sh` 的 `INIT_STRIP_SIZE=2` 并写明约束 |
| 7.6 | `04` 建用户后所有鉴权失败 | 旧脚本 `user-add ... --token <随机 hex>`，服务端 `UserStore::addUser` 会走 `ensureTokenMatchUid()`（token 内编码了 uid），随机串必然不匹配 | 不带 `--token`，从 `user-add` 输出表解析服务端生成的 token 落盘；已存在且有效则跳过 |
| 7.7 | `04` 死等 `SERVING` 节点、`mkdir`/`oflag=direct` 步骤报错 | ① 本版本 `flat::NodeStatus` 只有 `PRIMARY_MGMTD/HEARTBEAT_CONNECTED/...`，**没有 SERVING**；② `admin_cli mkdir` 冗余；③ FUSE 下 `dd oflag=direct` 不可靠 | 节点判据改 `HEARTBEAT_CONNECTED` + `list-targets` 的 `SERVING`；删掉 mkdir；冒烟改普通 `dd` + `md5sum` |

---

## 8. FDP 能力验证（三层）

### 8.1 层 1：存储侧 chunk engine 解析（compaction 分流）

`fdp_compaction_stream_id` 只在**首次 move/compact 块时**懒解析，并打印：

```bash
journalctl -u storage_main --no-pager | grep -a "\[FDP\]"
# 期望（本环境实测条件：GET_MAX=14）:
# [FDP] compaction stream resolved: configured=2 max=14 resolved=2
# 若设备未暴露写流才会出现:
# [FDP] compaction stream fell back to default placement: configured=2 max=0 ...
```

触发 compaction 需要"某分配组内废弃 chunk > `max_reserved_chunks`（默认 1GB）"，
即 **写入 → 删除** 反复几 GB 后由 `AllocateWorker`（100ms 轮询）拉起。

### 8.2 层 2：客户端 FUSE ioctl 透传

```bash
cd /home/smrc/lzh/shell/deploy_scripts
python3 - <<'EOF'
import fcntl, os, struct
HF = (3<<30)|(16<<16)|(0x68<<8)|16   # HF3FS_IOC_WRITE_STREAM = 0xC0106810
fd = os.open("/3fs/stage/test/probe", os.O_RDWR|os.O_CREAT, 0o644)
for op, sid in ((1, 0), (4, 3), (2, 0)):
    ws = struct.pack("IIII", op, sid, 0, 0)
    print(op, struct.unpack("IIII", fcntl.ioctl(fd, HF, ws)))
os.close(fd)
EOF
# 实测: op=1 (GET_MAX) → (1, 0, 255, 0)  # FUSE 固定返回 255(内核 u8 上限), 真实上限在存储侧
#       op=4 (SET 3)   → (4, 3, 0, 0)
#       op=2 (GET)     → (2, 3, 255, 0)  # 返回该 fd 当前 stream_id
```

写入工具（等价于 LMCache 的 `use_fdp` 行为）：

```bash
sudo python3 fdp_stream_write.py /3fs/stage/test 1024 7
# GET_MAX = 255 / SET stream=7 → GET = 7 / 写入 1024 MB ... 
```

### 8.3 层 3：物理放置证据（NVMe 命令级，dsmgmt → PLID）

**结论：FDP 放置在本环境是真实生效的**，`XFS GET_MAX = 14`（硬件 16 条流 − XFS 内部保留 2 条），
`PLID = stream_id − 1`。

> ⚠ 早期误判说明：用 Python 探测时若写成 `fcntl.ioctl(fd, CMD, ws)` 后读 `ws`，会**永远得到 0**
> —— `bytes` 不可变，ioctl 的结果在**返回值**里。本手册早期版本因此误报 `GET_MAX=0`。
> 正确写法见下，`01_precheck.sh` / `03_setup_storage.sh` 已修正。

```bash
# 存储节点：正确读取 GET_MAX（必须用 ioctl 的返回值）
python3 - <<'EOF'
import fcntl, os, struct
FS = 0xC010662B
p = "/storage/data3/.getmax_probe"
fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
ret = fcntl.ioctl(fd, FS, struct.pack("IIII", 1, 0, 0, 0))
print("GET_MAX =", struct.unpack("IIII", ret)[2])     # 本环境 14
os.close(fd); os.unlink(p)
EOF
```

**直接抓 NVMe 命令的 placement 字段**（最硬的证据，`cdw10[24]` 中第 5 个 DWORD 即 CDW14=dsmgmt）：

```bash
T=/sys/kernel/tracing
echo > $T/trace
echo 1 > $T/events/nvme/nvme_setup_cmd/enable

python3 - <<'EOF'
import fcntl, os, struct
FS = 0xC010662B
for sid in (0, 3, 7):
    p = f"/storage/data3/dsmgmt_{sid}.bin"
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644)
    if sid:
        fcntl.ioctl(fd, FS, struct.pack("IIII", 4, sid, 0, 0))   # SET stream
    for _ in range(8):
        os.write(fd, b"\xa5" * (4 << 20))                       # 32MB
    os.fsync(fd); os.close(fd); os.unlink(p)
EOF

echo 0 > $T/events/nvme/nvme_setup_cmd/enable
grep -E "nvme3c|nvme4c" $T/trace | grep -o "dsmgmt=[0-9a-fx]*, reftag" | sort | uniq -c
```

实测结果：

| 客户端 SET | NVMe `dsmgmt` | 解析出的 PLID |
|---|---|---|
| 不设（0） | `0` | 无 placement（默认放置） |
| stream 3 | `131072` = `0x20000` | **PLID 2** |
| stream 7 | `393216` = `0x60000` | **PLID 6** |

同时还伴随 `ctrl=0x20`（DTYPE 位），即 NVMe 写命令确实携带了 FDP placement directive。
这比 dmesg 的 `write with stream N` 更强：后者只证明 bio 带了 stream id，前者证明它**被翻译成了
PLID 并写进了 NVMe 命令**。

```bash
# 端到端链路佐证（存储侧日志）
journalctl -u storage_main --no-pager | grep -a "FDP_DEBUG" | tail
# [FDP_DEBUG] SERVER_WRITE: received streamId=7 ...
# [FDP_DEBUG] CLUSTER_PWRITE: streamId=7 ...
```

> `nvme fdp status` 的 RUAMW 在 PM1763 上是**静态值**（16 个 PID 全为 10543104，写入后无变化），
> `nvme fdp stats` 该盘不支持（Invalid Field），因此无法用设备计数器观测。
> 物理放置请以本节的 `dsmgmt`（NVMe 命令级）为准；WAF 用 `nvme smart-log` 的
> `Data Units Written`（×512KB = NAND 写入量）。

---

## 9. 运维操作

```bash
# 服务状态
systemctl status mgmtd_main meta_main hf3fs_fuse_main monitor_collector_main   # dskna004
systemctl status storage_main                                                  # 存储节点

# 只重启 3FS 自己（不重启服务器）
systemctl restart mgmtd_main meta_main            # dskna004
systemctl restart storage_main                    # 存储节点

# 改 fdp_compaction_stream_id（WAF 对照实验）
vim /home/smrc/lzh/shell/deploy_scripts/common.sh   # FDP_COMPACTION_STREAM_ID=0/2
sudo bash 02_setup_meta.sh                          # 只做到上传 STORAGE 配置即可(Ctrl-C 之前也行)
# 或直接:
source common.sh && render_storage_cfg /opt/3fs/etc/storage_main.toml
admin_cli "set-config --type STORAGE --file /opt/3fs/etc/storage_main.toml"
# 3 台存储节点:
systemctl restart storage_main
journalctl -u storage_main --no-pager | grep -a "\[FDP\]"

# WAF 观测（3 台存储节点）
sudo bash 03_setup_storage.sh verify snap     # 负载前
# ... 跑 LMCache KV offload ...
sudo bash 03_setup_storage.sh verify check    # 负载后: DUW 增量 / RUAMW / 内核 stream 计数
#   WAF = (DUW_after − DUW_before) × 512KB ÷ host 写入量
```

---

## 10. 故障排查速查

| 现象 | 原因 / 处理 |
|---|---|
| `6004 MgmtdClient::RoutingInfoNotReady` | 地址用了 IPoIB；改成管理网 IP（§7.2） |
| `admin_cli: too many ibdevices ... abort` | 缺 `[ib_devices] device_filter`（dskna004 有 8 个活动 HCA，上限 4） |
| mgmtd 起不来 / `list-nodes` 为空 | `mgmtd_main.toml` 有误；改它必须清 FDB 重跑 `init-cluster`（`02 --reset-fdb`） |
| 写入 `EIO`，meta 日志 `have only N chains` | `stripeSize > 链数`；重跑 init-cluster（stripe ≤ 链数，§7.5） |
| ClickHouse 表为空 + `unsupported compression method 144` | 网络压缩为 ZSTD；按 §7.4 改 LZ4 并 `SYSTEM RELOAD USERS` |
| storage 反复 SYNCING | 用 `list-targets` 观察，属正常恢复；RF=3 下不影响读写 |
| 无 `[FDP]` 日志 | compaction 未触发（需 >1GB 废弃 chunk）；触发后应见 `resolved: configured=2 max=14` |
| `list-targets` 无输出 | 还没 create-target，或 `--use-new-chunk-engine` 未加 |

---

## 11. 重置与回滚

```bash
# 全量重建（不改 init-cluster 参数时）
sudo bash 02_setup_meta.sh --reset-fdb      # 清 FDB + 重新 configure + init-cluster
# 3 台存储节点:
systemctl stop storage_main
rm -rf /storage/data3/3fs/* /storage/data4/3fs/*
systemctl start storage_main
sudo bash 04_finalize_cluster.sh            # 重新建 user/targets/链/FUSE
```

- 只重跑某一步是安全的：4 个脚本都幂等（target 已存在会告警跳过，链重复上传不影响）。
- 改了 `init-cluster` 参数（stripe/chunk）**必须** `--reset-fdb`，否则 FDB 里 root layout 不会变。

---

## 12. 与 LMCache 阶段衔接

| 参数 | 值 |
|---|---|
| 挂载点 | `/3fs/stage` |
| token | `/opt/3fs/etc/token.txt`（root，权限 600） |
| FDP | `use_fdp=true, start_fdp_stream_id=3`，`fdp_stream_number` 取 `GET_MAX−2` 以内的固定值 |
| 当前环境 | **GET_MAX=14** ⇒ 可用 stream 3..14；建议 `fdp_stream_number=8`（3..10） |
| 预留 | stream 1（→PLID 0）空置；stream 2（→PLID 1）= 3FS compaction |

---

## 13. 环境注意事项（非脚本可解决）

1. **数据盘未写入 `/etc/fstab`**：`/storage/data3`、`/storage/data4` 是手工挂载，
   重启后不会自动恢复。建议补 fstab（本次未改，避免影响现有环境）：
   `UUID=... /storage/data3 xfs noatime,nodiratime 0 0`
2. **禁止 reboot**：FDP 相关能力（GET_MAX、设备写流）在重启后行为可能变化，务必先跑 `01_precheck.sh`。
3. **ClickHouse 与 FDB 是共享服务**：脚本只做"连接/建表/改 profile/配置"，不重启它们；
   若他人也在使用这台 ClickHouse，请确认 LZ4 profile 变更可接受（只影响 default 用户）。
4. **`deploy_scripts` 内含 root 密码**（`common.sh`），部署完成后建议 `chmod 700` 目录。
