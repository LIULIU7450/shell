# 3FS FDP 集群部署 — 执行顺序与运维速查

配套脚本：`deploy_scripts/`（4 个入口脚本 + 共享库 + FDP 写入工具）
完整手册：同目录 `3FS_FDP_部署手册.md`（含根因分析与验证方法，**先读它**）
官方基线：`/home/smrc/lzh/3fs-main/deploy/README.md`（Step 0–8）

## 脚本一览

| 脚本 | 在哪执行 | 作用 |
|---|---|---|
| `common.sh` | — | 共享库（被 source，勿单独执行）：主机→角色/node_id 映射、SSH、`admin_cli` 封装、**官方模板派生配置生成** |
| `01_precheck.sh` | **4 台全部** | 只读预检：内核 7.0.0-rc2、`FS_IOC_WRITE_STREAM`、chrony、二进制、FDP PID 连续性、XFS GET_MAX、IB 端口、FDB/ClickHouse/ssh 可达性 |
| `02_setup_meta.sh` | **仅 dskna004** | ClickHouse 建表(+LZ4 profile) → monitor_collector → FDB 自检/自愈 → 推送 fdb.cluster → admin_cli → mgmtd(+init-cluster) → meta → 上传 STORAGE 配置 |
| `02_setup_meta.sh --reset-fdb` | 同上 | FDB 数据损坏或需重建集群状态（清数据 + 重新 configure + 重新 init-cluster） |
| `03_setup_storage.sh` | **3 台存储节点** | aio-max-nr 调优 + admin_cli + storage 安装并启动（配置从 mgmtd 拉取） |
| `03_setup_storage.sh verify status\|snap\|check` | 同上 | FDP/WAF 观测：RUAMW+GET_MAX+DUW / 基线快照 / 与基线对比 |
| `04_finalize_cluster.sh` | **仅 dskna004** | 等 storage → 建 root 用户(token) → 6 targets → 2 链 + 链表 → FUSE 挂载 → 冒烟验证 |
| `fdp_stream_write.py` | 任意客户端 | `python3 fdp_stream_write.py <目录> <MB> <stream_id>` 按指定 FDP stream 写数据 |

## 执行顺序（4 步）

```
第 1 步  4 台各自:        sudo bash 01_precheck.sh        # 只读；WARN 不阻塞
第 2 步  仅 dskna004:     sudo bash 02_setup_meta.sh
第 3 步  3 台存储节点:    sudo bash 03_setup_storage.sh   # 结束后回 dskna004 看 list-nodes
第 4 步  仅 dskna004:     sudo bash 04_finalize_cluster.sh
```

顺序不可调换：03 依赖 02 推送的 `fdb.cluster` 与 mgmtd 中的 STORAGE 配置；04 依赖 03 起来的 storage。

## 集群参数（改这些只看 `common.sh`）

| 常量 | 值 | 说明 |
|---|---|---|
| `MGMTD_ADDR` | `RDMA://172.16.12.210:8000` | **必须用管理网 IP**：RDMA 方案的监听端只在 `en*/eth*/bond*` 网卡上（`Listener.cc:33`），数据面才走 IB |
| `MONITOR_ADDR` | `172.16.12.210:10000` | 同上 |
| `INIT_CHAIN_TABLE_ID/CHUNK_SIZE/STRIP_SIZE` | `1 / 1048576 / 2` | **stripe ≤ 链数**（本集群 6 targets/RF=3 ⇒ 2 条链），改了必须 `02 --reset-fdb` |
| `FDP_COMPACTION_STREAM_ID` | `2` | compaction 写入走 stream 2（→PLID 1）；stream 1 空置 |
| `IB_DEVICE_FILTER_META` | `["mlx5_0".."mlx5_3"]` | dskna004 有 8 个活动 HCA，3FS 上限 4，必须过滤 |
| `STORAGE_DATA_DIRS` | `/storage/data3/3fs`,`/storage/data4/3fs` | 仅 nvme3n1/nvme4n1；nvme2n1 不用 |

## 安全承诺（脚本遵守）

- **不重启服务器**；`sysctl fs.aio-max-nr` 在线生效；GRUB 不动
- 只操作 3FS 自有对象：`/opt/3fs/*`、`/var/log/3fs`、`/3fs/stage`、systemd 单元
  `mgmtd_main / meta_main / storage_main / hf3fs_fuse_main / monitor_collector_main / foundationdb`
- 不动数据盘内容（只建目录）、不碰 nvme2n1/ZFS/OS 盘、不影响 Lustre 等其他服务
- ClickHouse 只做连接/建表/改 default profile 的压缩方式（`SYSTEM RELOAD USERS`，不重启）
- 全部脚本幂等可重跑

## 常用运维命令

```bash
cd /home/smrc/lzh/shell/deploy_scripts && source ./common.sh

admin_cli list-nodes                 # 节点（健康态是 HEARTBEAT_CONNECTED，本版本无 SERVING 节点态）
admin_cli_token list-targets         # 6 targets，期望 SERVING/UPTODATE
admin_cli_token list-chains          # 2 条链 SERVING
mount | grep /3fs/stage

# FDP / WAF（存储节点）
sudo bash 03_setup_storage.sh verify status
sudo bash 03_setup_storage.sh verify snap
sudo bash 03_setup_storage.sh verify check
```

## 失败恢复

- 任一脚本失败：修原因后**重跑同一脚本**（幂等）。
- FDB 异常：`sudo bash 02_setup_meta.sh --reset-fdb`，再清各存储节点 `/storage/data{3,4}/3fs/*`，重跑 03、04。
- 只重建 targets：`offline-target` / `remove-target` 同 ID 后再跑 04。
- 更多报错对照表见 `3FS_FDP_部署手册.md` §10。
