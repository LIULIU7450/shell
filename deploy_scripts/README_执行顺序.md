# 3FS FDP 集群部署脚本 — 执行顺序说明

配套脚本集：`deploy_scripts/`（4 个入口脚本 + 共享库）
配套报告：`/home/lzh/max_lab/3fs_fdp_deployment_guide.md`（每步在脚本注释中标明对应章节）

## 脚本一览

| 脚本 | 在哪执行 | 作用 | 对应指南 |
|---|---|---|---|
| `common.sh` | — | 共享库（被 source，勿直接执行）：主机→角色/node_id 自动映射、路径常量、admin_cli 封装、配置生成器 | — |
| `01_precheck.sh` | **4 台全部** | 只读预检：内核 7.0.0-rc2、FS_IOC_WRITE_STREAM、chrony、二进制、FDP PID 连续性、**XFS GET_MAX≥3 硬闸门**、IB 端口、FDB/ClickHouse/ssh 可达性 | §1 |
| `02_setup_meta.sh` | **仅 dskna004** | meta 节点一体化：ClickHouse 监控表 → monitor_collector → FDB 初始化 → 推送 fdb.cluster → admin_cli → mgmtd（init-cluster `1 1048576 16`）→ meta → **上传 STORAGE 配置（`fdp_compaction_stream_id=2`）** | §3–§8 |
| `03_setup_storage.sh` | **3 台存储节点** | 部署模式（无参数）：aio-max-nr 调优 + admin_cli + storage 安装**并启动**（配置从 mgmtd 拉取） | §2, §5, §8 |
| 同上 | 同上 | 运维模式：`03_setup_storage.sh verify status\|snap\|check`（[FDP] 日志 / WAF 基线快照 / PLID 差值分析） | §11.2 层1/3, §12 |
| `04_finalize_cluster.sh` | **仅 dskna004** | 收尾：等 3 storage SERVING → user-add（token 预置）→ 6 targets → 2 链 + 链表 → FUSE 挂载 `/3fs/stage` → 512MB 冒烟 + FUSE GET_MAX + 监控验证 | §9–§11 |

集群信息速览：dskna004（10.10.44.210，mgmtd=1 / meta=100 / FUSE）；
dsksa304/305/348（10.10.44.64/65/169，storage=10001/10002/10003）；
cluster_id=`stage`；数据盘仅 nvme3n1/nvme4n1（nvme2n1 不可用，不使用）。

## 执行顺序（4 步，无任何中途暂停）

```
第 1 步  4 台节点各自:    sudo bash 01_precheck.sh
                          └─ 只读, 任何 FAIL 先解决再继续

第 2 步  仅 dskna004:     sudo bash 02_setup_meta.sh
                          └─ ssh 账户/密码在 common.sh 中 (root + 密码, sshpass 免交互)
                          └─ 结束时 STORAGE 配置已在 mgmtd 中, 存储节点可随时启动

第 3 步  3 台存储节点各自: sudo bash 03_setup_storage.sh
                          └─ 安装后直接启动 (无 --start 两段式, 无暂停点)

第 4 步  仅 dskna004:     sudo bash 04_finalize_cluster.sh
                          └─ 自动等存储节点就绪 → 建用户/targets/链 → 挂载 → 冒烟验证
```

> **SSH 凭据**：dskna004 → 3 台存储节点的推送 (02) 使用 root + 密码登录，密码内嵌在
> `common.sh` 的 `SSHPASS` 变量（可用环境变量 `SSHPASS=xxx` 覆盖），依赖 `sshpass`。
> dskna004 需安装：`apt install -y sshpass`。**部署完成后请将 deploy_scripts 目录
> 权限收紧**（`chmod -R 600`）或改用 ssh-key 后清空密码变量。

> **IB 设备过滤（dskna004 必需）**：dskna004 有 8 个活动 ConnectX-7 HCA，超过 3FS
> 硬限制 `kMaxDeviceCnt=4`（`IBDevice.h:119`），任何 3FS 进程（服务、launcher、
> admin_cli、FUSE）启动时都会 `CRITICAL: too many ibdevices ... abort`。
> 所有脚本生成的 dskna004 侧配置已带 `[ib_devices] device_filter =
> ["mlx5_0","mlx5_1","mlx5_2","mlx5_3"]`（common.sh 的 `IB_DEVICE_FILTER_META`，
> 对应 IPoIB .210–.213）。存储节点 HCA ≤2 不需要过滤。若你想换用其他 4 张卡，
> 改 `IB_DEVICE_FILTER_META` 后重跑相应脚本即可。

顺序不可调换的原因：
- 03 依赖 02 推送的 `fdb.cluster` 和上传到 mgmtd 的 STORAGE 运行配置
- 04 的 create-target 依赖 03 启动的 3 个 storage 节点注册

## 安全承诺（所有脚本遵守）

- **不重启服务器**；`sysctl fs.aio-max-nr` 在线生效；GRUB 已由你方锁定，脚本不再处理
- **只操作 3FS 自有对象**：`/opt/3fs/*`、`/var/log/3fs`、`/3fs/stage`、systemd 单元
  `mgmtd_main / meta_main / storage_main / hf3fs_fuse_main / monitor_collector_main / foundationdb`
- **不触碰**：数据盘文件内容（只建目录）、其他任何服务/进程、nvme2n1、ZFS 盘、OS 盘
- ClickHouse 只做连接与建表，**不代为启停** clickhouse-server
- 全部脚本幂等可重跑；02 的 FDB 初始化带健康检查（已初始化则跳过）

## 失败恢复 / 重跑规则

- **任何脚本失败**：修复原因后重跑同一脚本即可。
- **重置整个集群**（如 init-cluster 参数错误，指南 §13.2）：停 3FS 各服务 → 清
  `/var/lib/foundationdb/data/*` → 重跑 02（会重新 init-cluster，因
  `/opt/3fs/etc/.cluster_inited` 标记需先删除）→ 清各存储节点
  `/storage/data{3,4}/3fs/*` 下旧 target 目录 → 03 → 04。
- **04 重跑**：token 已存在则跳过 user-add；create-target 对已存在 target 会报错，
  可先 offline-target/remove-target 同 ID 后重建。
- **改 `fdp_compaction_stream_id`**（如 WAF 对照实验切 0/2）：编辑
  `common.sh` 中 `write_storage_main_toml` 的值 → 重跑 02（仅到第 8 步 set-config
  STORAGE 为止，或手动执行该条 admin_cli 命令）→ 3 台 `systemctl restart storage_main`
  → 存储节点日志确认 `[FDP] compaction stream resolved: configured=2 max=16 resolved=2`。

## 部署完成后的日常操作

```bash
# 服务状态 (4 台)
systemctl status mgmtd_main meta_main storage_main hf3fs_fuse_main monitor_collector_main

# WAF 实验 (3 台存储节点)
sudo bash 03_setup_storage.sh verify snap     # 负载前基线
#   ... 跑 LMCache KV offload 负载 ...
sudo bash 03_setup_storage.sh verify check    # 负载后: PLID1=compaction 写入, PLID2..=数据写入
#   WAF = DataUnitsWritten 差值×512KB ÷ host 写入量
```
