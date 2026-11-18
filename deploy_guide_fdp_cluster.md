# LMCache + 3FS FDP 集群部署与 WAF 验证指南

**目标集群**：dsksa304 / dsksa305 / dsksa348（存储）+ dskna004（GPU 客户端）
**目标**：通过 NVMe FDP（Flexible Data Placement）write stream 分流，降低 LMCache+3FS 场景的写放大（WAF）
**适用版本**：
- 3fs fork：`github.samsungds.net/zihao01-liu/3fs`，部署 commit `bdcd484348fb0ef121d5002fe1e60fa00c0d0e3e`（功能起点 `cc017b841c3e`）
- LMCache fork：`github.samsungds.net/zihao01-liu/LMCache_3FS`，部署 commit `132d73378ceb6a687e15fe205635b0a43e9ec639`（功能起点 `2a2d800f1c9e`）
- 内核源码基线：`/home/lzh/linux`，HEAD `440aad66398d`（7.0.0-rc2 + Samsung FDP write stream 补丁）

**配套交付物**（与本指南同目录 `/home/lzh/max_lab/shell/`）：

| 文件 | 运行位置 | 用途 |
|---|---|---|
| `fdp_preflight.py` | 三台存储节点 | **Step 0** FDP 能力验收（部署闸门，必须最先跑） |
| `usrbio_stream_bench.py` | dskna004 | **Step 7/8** USRBIO 定向写验证与 WAF 实验 |

---

## 0. 必读：头号风险与安全红线

### 0.1 头号风险 —— 现场 XFS GET_MAX 异常（未闭环）

2026-11-17 的 envinfo 探测显示，**三台存储节点的 9 块 FDP 盘全部出现同一异常**：

```
/sys/block/nvmeXn1/queue/max_write_streams = 16    ← NVMe 层正常（FDP 已启用）
XFS 上 FS_IOC_WRITE_STREAM GET_MAX → max_streams = 0   ← 异常！按源码应为 16-2=14
```

而 `/home/lzh/linux` 源码的行为是：`hw_streams=16 且内部 log → XFS 预留最高 2 条流（meta=16、log=15），GET_MAX 返回 14`。
另外现场 `uname -r` 为 `7.0.0-rc2`（无 `+`），源码树构建产物 vermagic 为 `7.0.0-rc2+` —— **版本号不一致，说明现场运行内核与当前源码树不是同一份构建**。

**后果**：若该状态属实，XFS `SET` 的范围检查（`stream_id > max` 则 `-EINVAL`）会拒绝一切非 0 stream_id，LMCache 分流与 3fs compaction 分流将**全部静默失效**（写入退回默认放置区），整个 FDP 实验测不出效果。

**处置**：因此 Step 0 的 preflight 验收是**部署闸门**——先实测闭环，再决定是否需要重编内核（Step 0.4）。**不要跳过 Step 0 直接部署。**

> 注：GPU 客户端 dskna004 上 GET_MAX=0 属**正常**（它的 NVMe 都未开 FDP，`max_write_streams=0`），客户端无需内核修复——FDP ioctl 只在存储节点本地 XFS 上发生。

### 0.2 磁盘与数据安全红线（全程有效）

- **只使用** `/storage/data{2,3,4}/3fs` 子目录存放 3FS 数据；盘上已有的 ~274G 既有数据不动、不删。
- **严禁** 对任何磁盘做 `mkfs` / `wipefs` / `dd` / `blkdiscard`。
- **严禁** 触碰 `nvme1n1`（他人 ZFS 数据，304/305/348 均有）与 `nvme0n1`（系统盘）。
- 部署前后各做一次 `du -sh /storage/data{2,3,4}` 留档，确认未误伤他人数据。
- 修改内核 / 重启节点前必须获得现场负责人批准（见 Step 0.4 的 ZFS 风险说明）。

---

## 1. 现场环境结论（来自 envinfo 报告，已核实）

### 1.1 已具备
- 三台存储节点：Ubuntu 24.04.4、glibc 2.39、内核 7.0.0-rc2（含 `FS_IOC_WRITE_STREAM` 头文件）
- 每台 3 块 SAMSUNG PM1763（nvme2/3/4n1，15.36TB，4K 扇区），已 mkfs.xfs 并挂载 `/storage/data{2,3,4}`，`nvme fdp status` 显示 16 个 PLID/RUH（0–15），nvme-cli 2.8
- RDMA：IB 200G + IPoIB，存储节点 `10.10.44.64/65/169`（/21），客户端 `10.10.44.210–213`，互通正常
- 客户端 dskna004：Ubuntu 22.04.5、Python 3.10.12、torch 2.12.1、Docker、A100×8、/dev/shm 504G、/dev/fuse 正常

### 1.2 缺失（部署要补）
- 三台存储节点：无 cmake / clang-14 / rust、无 3fs 运行依赖库、无 FoundationDB、`fs.aio-max-nr=65536`、`ulimit -n=1024`、无 3fs 进程
- 客户端：无 clang / rust / uv / vllm、libfuse3 仅 3.10.5（**3fs FUSE 需要 ≥3.12**，`fuse_loop_cfg_*` 接口）

### 1.3 异常（Step 0 处理）
- 三台存储节点 XFS `GET_MAX = 0`（见 0.1）

---

## 2. 部署规划总览

### 2.1 拓扑与角色

| 节点 | 角色 | 管理 IP | RDMA (IPoIB) IP | node_id |
|---|---|---|---|---|
| dsksa304 | **mgmtd + meta + FoundationDB + storage** | 172.16.18.64 | 10.10.44.64 | mgmtd=1，meta=100，storage=10001 |
| dsksa305 | storage | 172.16.18.65 | 10.10.44.65 | storage=10002 |
| dsksa348 | storage | 172.16.18.169 | 10.10.44.169 | storage=10003 |
| dskna004 | hf3fs FUSE client + LMCache | 172.16.12.210 | 10.10.44.210–213 | — |

3 节点 × 3 盘 = 9 个 storage target；**RF=1**（每 target 一条单副本链，与已验证的 `tests/fuse/run_fdp_server.sh` 模式一致，便于干净测 WAF）。
monitor/ClickHouse 不部署（配置中 `remote_ip` 留空）。

### 2.2 端口规划

> 注意：3FS 的 `*_main.toml` 由 mgmtd 集中管理（`admin_cli set-config` 全局单份），因此 **storage 三台必须共用同一端口**；304 上 mgmtd/meta/storage 共存，端口必须错开。

| 服务 | 节点 | RDMA listener | TCP listener |
|---|---|---|---|
| mgmtd | 304 | **8000**（默认） | **9000**（默认） |
| meta | 304 | **8001**（默认） | **9001**（默认） |
| storage（三台统一） | 304/305/348 | **8010**（要改） | **9010**（要改） |
| FoundationDB | 304 | — | **4500**（IPoIB `10.10.44.64:4500`） |

### 2.3 FDP stream 分配规划（本部署的核心）

每盘 16 条硬件流。按内核行为：XFS 自动预留最高两条（meta=16→PLID 15，log=15→PLID 14），用户可 `SET` 的 id 范围 0–14；**stream_id `s` 写入对应 `nvme fdp status` 的 `Placement Identifier s-1`**（`plids[stream_id-1]`）。

| stream_id | → PLID | 用途 | 配置项 |
|---|---|---|---|
| 0 | 0 | 默认放置（不 SET 的写入） | — |
| 1 | 1 | 预留 | — |
| **2** | 1 | **3fs compaction 搬迁拷贝** | storage `[server.targets] fdp_compaction_stream_id = 2` |
| **3–10** | 2–9 | **LMCache KV cache 分流**（MD5(request_id)%8 + 3） | LMCache `start_fdp_stream_id: 3` + `fdp_stream_number: 8` |
| 15 | 14 | XFS log（内核自用，勿动） | — |
| 16 | 15 | XFS meta（内核自用，勿动） | — |

### 2.4 集群标识与路径

| 项 | 值 |
|---|---|
| 3FS cluster_id | `fdp` |
| FDB cluster 文件 | `fdp:fdp@10.10.44.64:4500` |
| FUSE 挂载点 | `/3fs/fdp` |
| LMCache base_path | `/3fs/fdp/lmcache` |
| 安装目录（全部节点） | `/opt/3fs/{bin,etc,lib}`，日志 `/var/log/3fs` |
| FDB 数据（仅 304） | `/opt/3fs/fdb/{data,log}` |

---

## Step 0 —— FDP 能力验收（部署闸门）

**在三台存储节点上分别执行。** 不需要任何 3FS 组件。

### 0.1 内核指纹核对

本机（源码基线）参照值：

```
源码树 HEAD        : 440aad66398d8a62276eed338225b9b700850d93 (2026-07-16, "ldiskfs: Apply ldiskfs patch")
xfs.ko srcversion  : 6424D595C1CA23140AF553B
xfs.ko vermagic    : 7.0.0-rc2+ SMP preempt mod_unload modversions
GET_MAX 预期值     : max_write_streams - 2 = 14
```

现场每台存储节点执行：

```bash
uname -a
cat /sys/module/xfs/srcversion 2>/dev/null || echo "xfs 为内置或无法读取"
modinfo xfs 2>/dev/null | grep -E '^(version|vermagic|srcversion)'
grep -E 'CONFIG_LOCALVERSION|CONFIG_MODVERSIONS' /boot/config-$(uname -r) 2>/dev/null
# 若现场存在内核源码目录，核对版本：
cd /home/lzh/linux 2>/dev/null && git rev-parse HEAD && git status --porcelain | head -3
```

对照：`srcversion` 与基线不一致，或 `uname -r` 不带 `+`，即证明运行内核不是当前源码构建 → 大概率就是 GET_MAX=0 的根因。

### 0.2 运行 preflight（验收脚本）

把 `fdp_preflight.py` 拷到每台存储节点（任意目录），执行：

```bash
sudo python3 fdp_preflight.py                 # 全部 XFS 挂载点: GET_MAX/SET/GET + 写 8GiB + RUAMW 对比
sudo python3 fdp_preflight.py --baseline      # 追加 stream=0 对照组（看默认放置分布）
python3  fdp_preflight.py -g 0                # 只做 ioctl 探测（不写入，不 root 也能看到 GET_MAX/SET 结果）
```

脚本会自动：发现 XFS 挂载点 → 打印内核指纹 → `GET_MAX`/`SET(3)`/`GET` 回读 → 按 3fs chunk engine 同款路径（`open → ioctl SET fd → pwrite → fsync`）写 8GiB → 对比 `nvme fdp status` 各 PLID 的 RUAMW → 输出 PASS/FAIL 判定。测试文件自动清理。

### 0.3 判定与行动表

| 脚本结果 | 结论 | 行动 |
|---|---|---|
| **A. GET_MAX=14 + SET OK + RUAMW 精确路由** | 与源码基线一致，链路完全健康 | ✅ 直接进 Step 1 |
| **B. GET_MAX=0 + SET EINVAL** | 运行内核 XFS 逻辑与源码不符（envinfo 异常属实），全链路失效 | ❌ 执行 Step 0.4 修内核 |
| **C. GET_MAX=0 但 SET OK + RUAMW 路由正确** | SET 路径可用：LMCache USRBIO 分流可用；但 3fs compaction 依赖 GET_MAX 做范围检查会静默回退 0 | ⚠️ 可先部署测 LMCache 分流，compaction 分流需 Step 0.4 修内核后才有 |
| **D. GET_MAX ENOTTY** | 运行内核无 `FS_IOC_WRITE_STREAM` | ❌ 执行 Step 0.4 |
| **E. SET OK 但 RUAMW 集中在默认 PLID** | stream 打标在内核中被丢弃 | ❌ 执行 Step 0.4 |

三台节点结论可能不同，**逐台记录**（每台跑一次，保存输出）。

### 0.4 内核修复流程（仅当判定为 B/D/E，或 C 想要 compaction 分流）

> ⚠️ **高风险操作，需现场负责人书面批准**。三台存储节点都要做（FDP 盘都在存储节点）；客户端 dskna004 不需要。
> ⚠️ **ZFS 风险**：304/305/348 的 nvme1n1 上有他人 ZFS 池。若现场 ZFS 模块是 dkms/独立编译，自编内核无对应 `zfs.ko`，重启后该池将无法 import（zfs-mount 报错）。升级前：`lsmod | grep zfs; zpool status` 确认 ZFS 使用状态，**与该数据的使用方协调好再动**。
> GRUB 菜单保留有 `6.8.0-149-generic` / `7.0.0-43-generic` 等旧内核，可随时回退。

1. **取源码**：若现场没有 `/home/lzh/linux`，从本机打包传过去（约 2–3GB，含构建状态）：
   ```bash
   # 本机执行
   tar -czf linux-440aad66398d.tar.gz -C /home/lzh linux
   # 传到存储节点后解压: tar -xzf linux-440aad66398d.tar.gz -C /home/lzh
   ```
2. **核对**：`cd /home/lzh/linux && git rev-parse HEAD` 应为 `440aad66398d...`。
3. **编译**（任一台 24.04 机器或本机；源码树自带已验证的 `.config`）：
   ```bash
   cd /home/lzh/linux
   make -j$(nproc)                                   # 产出 bzImage + 全部模块（含 xfs.ko）
   make INSTALL_MOD_PATH=/tmp/modroot modules_install
   ```
4. **分发与安装**（三台存储节点）：
   ```bash
   # 构建机上打模块包
   tar -czf mods-7.0.0-rc2+.tar.gz -C /tmp/modroot/lib/modules 7.0.0-rc2+
   # 每台节点上：
   tar -xzf mods-7.0.0-rc2+.tar.gz -C /lib/modules/
   cp arch/x86/boot/bzImage /boot/vmlinuz-7.0.0-rc2+     # 从构建机拷 bzImage/System.map/.config
   cp System.map /boot/System.map-7.0.0-rc2+
   cp .config /boot/config-7.0.0-rc2+
   update-grub
   ```
5. **确认 GRUB 默认引导 `7.0.0-rc2+` 后 reboot**；`uname -r` 验证；`zpool status` 确认 ZFS 池状态并告知相关方。
6. **重跑 Step 0.2**，三台全部达到判定 A 才继续 Step 1。

---

## Step 1 —— 代码获取（两条路线任选）

### 路线 A（推荐）：本机打包传输（离线友好，submodule 已就绪）

```bash
# 本机执行（/home/lzh/max_lab 下两个 repo 已 clone 且 submodule 完整）
cd /home/lzh/max_lab
tar -czf 3fs-src-bdcd484.tar.gz \
  --exclude='.git' --exclude='build' --exclude='.codegraph' --exclude='.comet' \
  --exclude='docs/openspec' 3fs/
tar -czf LMCache_3FS-src-132d7337.tar.gz \
  --exclude='.git' --exclude='.venv' --exclude='.comet' --exclude='openspec' \
  --exclude='.pytest_cache' --exclude='*.egg-info' LMCache_3FS/
sha256sum 3fs-src-bdcd484.tar.gz LMCache_3FS-src-132d7337.tar.gz
```

传到现场后（目标机网络不通，需 U 盘/中转机）解压：

```bash
mkdir -p /opt/src && tar -xzf 3fs-src-bdcd484.tar.gz -C /opt/src
tar -xzf LMCache_3FS-src-132d7337.tar.gz -C /opt/src
```

### 路线 B（备选）：现场直接 clone

> 前提：现场能访问 `github.samsungds.net`（GHE）**以及公网 github.com**（3fs 的 submodule 指向公网仓库）——内网环境大概率拉不动 submodule，所以路线 A 是主推。

```bash
# PAT 向 lzh 索取（不要写进任何文档/脚本）
git clone https://<PAT>@github.samsungds.net/zihao01-liu/3fs.git /opt/src/3fs
cd /opt/src/3fs && git checkout bdcd484348fb0ef121d5002fe1e60fa00c0d0e3e
git submodule update --init --recursive
./patches/apply.sh                      # 给 rocksdb/folly 打补丁, 幂等

git clone https://<PAT>@github.samsungds.net/zihao01-liu/LMCache_3FS.git /opt/src/LMCache_3FS
cd /opt/src/LMCache_3FS && git checkout 132d73378ceb6a687e15fe205635b0a43e9ec639
```

路线 A 传过去后同样要在每棵源码树上执行一次 `./patches/apply.sh`（幂等，重复执行无害）。

---

## Step 2 —— 构建与分发

### 2.1 构建矩阵（为什么这样分）

| 产物 | 运行节点 OS | 构建环境 | 原因 |
|---|---|---|---|
| mgmtd_main / meta_main / storage_main / admin_cli | 24.04（glibc 2.39） | **本机（24.04）直接构建** | 版本一致，直接兼容 |
| hf3fs_fuse_main | **22.04**（glibc 2.35） | **docker ubuntu:22.04 构建** | glibc 只向后兼容，24.04 产物在 22.04 跑不起来 |
| hf3fs_py_usrbio wheel（cp310） | 22.04 py3.10 | docker ubuntu:22.04 构建 | CPython 扩展 ABI 绑定 cp310，本机 24.04 是 py3.12 |
| lmcache.lmcache_hf3fs（cp310） | 22.04 py3.10 | **现场 dskna004 编译** | 扩展编译要 torch 头文件，dskna004 已有 torch 2.12.1 |
| libfuse3 ≥ 3.12 | 22.04 | docker 内源码编 3.16.1 | 22.04 apt 只有 3.10.5，3fs FUSE 用到 `fuse_loop_cfg_*`（3.12+） |
| FoundationDB 7.3.63 | 304（24.04） | 本机直接拷 `fdbserver/fdbcli/libfdb_c.so` | 依赖极少（liblzma/libz/libc），已验证 |

### 2.2 服务端 bundle（本机 24.04 构建）

```bash
cd /home/lzh/max_lab/3fs
git submodule update --init --recursive
./patches/apply.sh

# 本机依赖已就绪（cmake/clang-14/rust/boost 等均已安装）；全新机器参照 README 的 22.04 apt 列表
cmake -S . -B build \
  -DCMAKE_CXX_COMPILER=clang++-14 -DCMAKE_C_COMPILER=clang-14 \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DSHUFFLE_METHOD=g++11
cmake --build build -j 32

# 打服务端 bundle（FoundationDB 从本机已装的 7.3.63 直接取）
mkdir -p server-bundle/{bin,lib,fdb,configs}
cp build/bin/{mgmtd_main,meta_main,storage_main,admin_cli} server-bundle/bin/
cp build/src/lib/api/libhf3fs_api_shared.so server-bundle/lib/
cp /usr/sbin/fdbserver /usr/bin/fdbcli /usr/lib/libfdb_c.so server-bundle/fdb/
cp -r configs server-bundle/
tar -czf server-bundle-24.04.tar.gz server-bundle/
sha256sum server-bundle-24.04.tar.gz
```

### 2.3 客户端 bundle（本机 docker ubuntu:22.04 构建）

在本机执行（容器需要能访问 apt 源与外网，本机 docker 环境满足；若受限，把下面 wget 的源码包提前下好挂进容器）：

```bash
# 1) 起 22.04 构建容器（源码与输出目录挂载进来）
docker run -it --name fdp22build -v /opt/src:/opt/src -v /root/out:/out ubuntu:22.04 bash
```

容器内（完整序列，一次粘贴执行）：

```bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get install -y \
  cmake libuv1-dev liblz4-dev liblzma-dev libdouble-conversion-dev libdwarf-dev \
  libunwind-dev libaio-dev libgflags-dev libgoogle-glog-dev libgtest-dev libgmock-dev \
  clang-14 clang++-14 lld-14 libgoogle-perftools-dev google-perftools libssl-dev \
  libclang-rt-14-dev libboost-all-dev build-essential \
  python3.10-dev python3-pip wget git curl meson ninja-build pkg-config
curl -sSf https://sh.rustup.rs | sh -s -- -y && . "$HOME/.cargo/env"

# 2) libfuse3 3.16.1（22.04 自带 3.10.5 不够）
cd /root && wget -q https://github.com/libfuse/libfuse/releases/download/fuse-3.16.1/fuse-3.16.1.tar.gz
tar -xzf fuse-3.16.1.tar.gz && cd fuse-3.16.1
mkdir build && meson setup build --prefix=/usr/local && ninja -C build && ninja -C build install
ldconfig

# 3) 构建 3fs（客户端目标 + 共享库）
cd /opt/src/3fs && ./patches/apply.sh
cmake -S . -B build \
  -DCMAKE_CXX_COMPILER=clang++-14 -DCMAKE_C_COMPILER=clang-14 \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo -DSHUFFLE_METHOD=g++11
cmake --build build -j$(nproc) --target hf3fs_fuse_main hf3fs_api_shared

# 4) hf3fs_py_usrbio wheel（cp310）
export CMAKE_ARGS="-DSHUFFLE_METHOD=g++11 -DCMAKE_CXX_COMPILER=clang++-14 -DCMAKE_C_COMPILER=clang-14"
mkdir -p /out/wheels && pip wheel . -w /out/wheels --no-build-isolation

# 5) 收集 client bundle
mkdir -p /out/client-bundle/{bin,lib,include,wheels}
cp build/bin/hf3fs_fuse_main /out/client-bundle/bin/
cp build/src/lib/api/libhf3fs_api_shared.so /out/client-bundle/lib/
cp /usr/local/lib/x86_64-linux-gnu/libfuse3.so.3.16.1 /out/client-bundle/lib/
cp /usr/local/bin/fusermount3 /out/client-bundle/bin/
cp src/lib/api/*.h /out/client-bundle/include/          # hf3fs_usrbio.h 等, 供 LMCache 扩展编译
cp /out/wheels/hf3fs_py_usrbio-*.whl /out/client-bundle/wheels/
```

退出容器后本机继续：

```bash
# 6) LMCache 离线依赖 wheels（py3.10 / manylinux2014；排除 torch——现场系统已有）
cd /home/lzh/max_lab/LMCache_3FS
uv export --no-dev --no-emit-project -o /tmp/lmc-req.txt
grep -viE '^(torch|nvidia-|triton)' /tmp/lmc-req.txt > /tmp/lmc-req-notorch.txt
mkdir -p /root/out/client-bundle/wheels
python3 -m pip download -r /tmp/lmc-req-notorch.txt \
  -d /root/out/client-bundle/wheels \
  --only-binary=:all: --python-version 3.10 --platform manylinux2014_x86_64
python3 -m pip download setuptools wheel ninja packaging \
  -d /root/out/client-bundle/wheels --only-binary=:all: --python-version 3.10

tar -czf client-bundle-22.04.tar.gz -C /root/out client-bundle
sha256sum client-bundle-22.04.tar.gz
```

### 2.4 分发与落地校验

传输物清单（U 盘/中转）：`server-bundle-24.04.tar.gz` → 三台存储节点；`client-bundle-22.04.tar.gz`、`3fs-src-*.tar.gz`（或整树）、`LMCache_3FS-src-*.tar.gz` → dskna004；`fdp_preflight.py` → 三台存储节点（Step 0 已用）。

落地校验（每台）：

```bash
sha256sum -c sha256.txt                       # 传输完整性
mkdir -p /opt/3fs && tar -xzf server-bundle-24.04.tar.gz -C /opt/3fs --strip-components=1
# 服务端二进制自检（24.04 节点）：
ldd /opt/3fs/bin/storage_main | grep "not found"     # 应无输出
# 客户端二进制自检（dskna004, 22.04）：
ldd /opt/3fs/bin/hf3fs_fuse_main | grep "not found"  # 应无输出
objdump -T /opt/3fs/bin/hf3fs_fuse_main | grep -oE 'GLIBC_2\.[0-9]+' | sort -u
#  ↑ 最高只能到 GLIBC_2.35（22.04 容器构建保证了这一点）；出现 2.36+ 说明用错 bundle
```

### 2.5 备选：现场构建（若无法在本机预制）

在**任一台 24.04 存储节点**（建议 304）安装全套 dev 依赖后按 2.2 相同命令构建服务端 bundle；在 **dskna004** 用 2.3 的容器内序列（或直接本机构建，它本身就是 22.04，但缺 clang-14/rust/meson，需 apt 或离线包补齐）构建客户端产物。apt 不可达时该路线不可行——回到主路线。

---

## Step 3 —— 存储节点系统准备（dsksa304 / 305 / 348 三台都做）

```bash
# 0) 数据留档（安全红线）
du -sh /storage/data{2,3,4} | tee /root/du_before_$(date +%F).log

# 1) 目录
mkdir -p /storage/data2/3fs /storage/data3/3fs /storage/data4/3fs   # 只建子目录, 不碰既有数据
mkdir -p /var/log/3fs

# 2) 内核参数（3fs 要求）
cat > /etc/sysctl.d/99-3fs.conf <<'EOF'
fs.aio-max-nr = 67108864
EOF
sysctl --system

# 3) fd 上限
cat > /etc/security/limits.d/99-3fs.conf <<'EOF'
*  soft  nofile  1048576
*  hard  nofile  1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
# 本次手动启动用 ulimit -n 1048576（见 Step 4 启动命令）；持久化对 systemd 服务生效

# 4) FDB 动态库（bundle 里带了 7.3.63）
cp /opt/3fs/fdb/libfdb_c.so /opt/3fs/lib/ && ldconfig
ldd /opt/3fs/fdb/fdbserver | grep "not found"   # 应无输出
```

**仅 304** 再做 FoundationDB 初始化：

```bash
mkdir -p /opt/3fs/fdb/{data,log}
echo 'fdp:fdp@10.10.44.64:4500' > /opt/3fs/etc/fdb.cluster
chmod 644 /opt/3fs/etc/fdb.cluster

nohup /opt/3fs/fdb/fdbserver -p auto:4500 \
  -d /opt/3fs/fdb/data -L /opt/3fs/fdb/log -C /opt/3fs/etc/fdb.cluster \
  > /var/log/3fs/fdbserver.stdout 2>&1 &

sleep 5
/opt/3fs/fdb/fdbcli -C /opt/3fs/etc/fdb.cluster --exec "configure new memory single"
/opt/3fs/fdb/fdbcli -C /opt/3fs/etc/fdb.cluster --exec "status minimal"   # 应为 available
```

> `configure new memory single`：单副本内存库，测试规模足够（meta 元数据量小）。若后续要长期跑可改 `ssd single`。

---

## Step 4 —— 集群初始化（mgmtd/meta 在 304；storage 三台）

### 4.1 修改配置文件（304 的 /opt/3fs/etc 下）

以下只列**必改项**，其余保持 bundle 默认。

**admin_cli.toml**
```toml
cluster_id = 'fdp'

[fdb]
clusterFile = '/opt/3fs/etc/fdb.cluster'

# 文件内 [mgmtd_client] 段（约 130 行）：
[mgmtd_client]
mgmtd_server_addresses = [ 'RDMA://10.10.44.64:8000' ]
```

**mgmtd_main_app.toml**
```toml
allow_empty_node_id = true
node_id = 1
```

**mgmtd_main_launcher.toml**
```toml
allow_dev_version = true
cluster_id = 'fdp'

[fdb]
clusterFile = '/opt/3fs/etc/fdb.cluster'
```

**mgmtd_main.toml**：两处 `listen_port` 保持 **8000**（RDMA 组）/ **9000**（TCP 组）默认；`[common.monitor.reporters.monitor_collector] remote_ip = ""` 留空。

**meta_main_app.toml**
```toml
allow_empty_node_id = true
node_id = 100
```

**meta_main_launcher.toml**
```toml
cluster_id = 'fdp'

[mgmtd_client]
mgmtd_server_addresses = [ 'RDMA://10.10.44.64:8000' ]
```

**meta_main.toml**：`listen_port` 保持 **8001**/**9001** 默认；`[server.mgmtd_client] mgmtd_server_addresses = [ 'RDMA://10.10.44.64:8000' ]`；`[server.fdb] clusterFile = '/opt/3fs/etc/fdb.cluster'`；monitor `remote_ip = ""`。

**storage_main_app.toml** —— 三台各一份（304/305/348 分别）：
```toml
# /opt/3fs/etc/storage_main_app_10001.toml
allow_empty_node_id = true
node_id = 10001
# 305 上: storage_main_app_10002.toml → node_id = 10002
# 348 上: storage_main_app_10003.toml → node_id = 10003
```

**storage_main_launcher.toml**（三台相同）
```toml
cluster_id = 'fdp'

[mgmtd_client]
mgmtd_server_addresses = [ 'RDMA://10.10.44.64:8000' ]
```

**storage_main.toml**（全局单份，由 mgmtd 下发；三台 target 路径一致所以可共用）
```toml
# 第一个 [[server.base.groups]]（network_type='RDMA'，services=['StorageSerde']）的 listener：
[server.base.groups.listener]
listen_port = 8010          # 原默认 8000，避开本机 mgmtd

# 第二个 [[server.base.groups]]（network_type='TCP'，services=['Core']）的 listener：
[server.base.groups.listener]
listen_port = 9010          # 原默认 9000，避开本机 mgmtd TCP

[server.mgmtd]
mgmtd_server_addresses = [ 'RDMA://10.10.44.64:8000' ]

[server.targets]
allow_disk_without_uuid = true
create_engine_path = true
# ★ FDP: compaction 搬迁拷贝写入 stream 2（对应 PLID 1）。默认被注释关闭，必须取消注释
fdp_compaction_stream_id = 2
target_paths = [ '/storage/data2/3fs', '/storage/data3/3fs', '/storage/data4/3fs' ]

# monitor 段 remote_ip = "" 留空
```

> `target_paths` 数组下标即后续 `create-target --disk-index` 的取值：0→data2，1→data3，2→data4。

### 4.2 启动与初始化命令序列（全部在 304 执行，除注明外）

```bash
ulimit -n 1048576
CLI="/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml"

# 1) 初始化集群（chain table id=1, chunk size=1MiB, file strip size=16 —— 官方默认）
$CLI "init-cluster --mgmtd /opt/3fs/etc/mgmtd_main.toml 1 1048576 16"

# 2) 启动 mgmtd
nohup /opt/3fs/bin/mgmtd_main \
  --app_cfg /opt/3fs/etc/mgmtd_main_app.toml \
  --launcher_cfg /opt/3fs/etc/mgmtd_main_launcher.toml \
  --cfg /opt/3fs/etc/mgmtd_main.toml \
  >> /var/log/3fs/mgmtd_main.stdout 2>&1 &
sleep 5 && $CLI "list-nodes"        # 应看到 mgmtd node 1 (SERVICE_MGMTD)

# 3) 上传 meta 配置并启动 meta
$CLI "set-config --type META --file /opt/3fs/etc/meta_main.toml"
nohup /opt/3fs/bin/meta_main \
  --app_cfg /opt/3fs/etc/meta_main_app.toml \
  --launcher_cfg /opt/3fs/etc/meta_main_launcher.toml \
  --cfg /opt/3fs/etc/meta_main.toml \
  >> /var/log/3fs/meta_main.stdout 2>&1 &
sleep 5 && $CLI "list-nodes"        # 应增加 meta node 100

# 4) 上传 storage 配置（三台共用这份）
$CLI "set-config --type STORAGE --file /opt/3fs/etc/storage_main.toml"

# 5) 三台分别启动 storage（注意各自 node_id 的 app_cfg）
# 304:
nohup /opt/3fs/bin/storage_main \
  --app_cfg /opt/3fs/etc/storage_main_app_10001.toml \
  --launcher_cfg /opt/3fs/etc/storage_main_launcher.toml \
  --cfg /opt/3fs/etc/storage_main.toml \
  >> /var/log/3fs/storage_main.stdout 2>&1 &
# 305 / 348 上同样命令，app_cfg 分别换成 _10002 / _10003
#   （305/348 需先从 304 同步 /opt/3fs/{bin,lib,etc} 与 fdb.cluster——storage 不连 FDB，
#    但 etc 目录保持一致最省事；token.txt 之后再同步）

sleep 10 && $CLI "list-nodes"       # 应看到 10001/10002/10003 三个 storage, 均 healthy

# 6) 创建 admin 用户（token 记录到文件）
$CLI "user-add --root --admin 0 root" | tee /opt/3fs/etc/token_add.log
# 命令输出里形如 "token: <TOKEN>"，把它写入：
# echo -n '<TOKEN>' > /opt/3fs/etc/token.txt && chmod 600 /opt/3fs/etc/token.txt

TOK="--config.user_info.token $(</opt/3fs/etc/token.txt)"

# 7) 创建 9 个 target（RF=1：chain_id=target_id）+ 上传链表
cd /opt/3fs/etc
printf 'ChainId,TargetId\n' > chains.csv
printf 'ChainId\n' > chain-table.csv
for spec in "10001 0" "10001 1" "10001 2" "10002 0" "10002 1" "10002 2" "10003 0" "10003 1" "10003 2"; do
  set -- $spec; nid=$1; did=$2
  tid=$(printf '%d%02d001' $nid $did)          # 如 1000101001
  $CLI $TOK "create-target --node-id $nid --disk-index $did --target-id $tid --chain-id $tid --use-new-chunk-engine"
  echo "$tid,$tid" >> chains.csv
  echo "$tid" >> chain-table.csv
done
$CLI $TOK "upload-chains /opt/3fs/etc/chains.csv"
$CLI $TOK "upload-chain-table --desc 'fdp-rf1-per-target' 1 /opt/3fs/etc/chain-table.csv"
$CLI "list-chains" && $CLI "list-chain-tables"   # 9 条 AVAIL 链 + chain table 1
```

> `--use-new-chunk-engine` 必须带：FDP compaction 分流实现在新 chunk engine 里。
> 排障：任何一步失败，先看 `/var/log/3fs/*.log` 与 nohup stdout，参照附录 B。

---

## Step 5 —— FUSE 客户端（dskna004）

```bash
# 1) 解 bundle（client-bundle-22.04.tar.gz → /opt/3fs）
mkdir -p /opt/3fs && tar -xzf client-bundle-22.04.tar.gz -C /opt/3fs --strip-components=1
# FUSE 的 main/app 配置模板从 server-bundle 的 configs 里取（同一中转介质上有）：
tar -xzf server-bundle-24.04.tar.gz -C /tmp --strip-components=2 server-bundle/configs/hf3fs_fuse_main.toml server-bundle/configs/hf3fs_fuse_main_app.toml
mv /tmp/hf3fs_fuse_main.toml /tmp/hf3fs_fuse_main_app.toml /opt/3fs/etc/

# 2) 从 304 同步 token
# scp/中转: 304:/opt/3fs/etc/token.txt → /opt/3fs/etc/token.txt (chmod 600)

# 3) 写 launcher 配置
cat > /opt/3fs/etc/hf3fs_fuse_main_launcher.toml <<'EOF'
allow_dev_version = true
cluster_id = 'fdp'
mountpoint = '/3fs/fdp'
token_file = '/opt/3fs/etc/token.txt'

[mgmtd_client]
mgmtd_server_addresses = [ 'RDMA://10.10.44.64:8000' ]
EOF

# 4) 客户端 main.toml 先在 304 上上传全局 FUSE 配置：
#    304: $CLI "set-config --type FUSE --file /opt/3fs/etc/hf3fs_fuse_main.toml"
#    （该文件内确认: [mgmtd] mgmtd_server_addresses 与 monitor remote_ip = ""）

# 5) 挂载
mkdir -p /3fs/fdp
ulimit -n 1048576
export LD_LIBRARY_PATH=/opt/3fs/lib          # libfuse3.so.3.16.1 + libhf3fs_api_shared.so
nohup /opt/3fs/bin/hf3fs_fuse_main \
  --app_cfg /opt/3fs/etc/hf3fs_fuse_main_app.toml \
  --launcher_cfg /opt/3fs/etc/hf3fs_fuse_main_launcher.toml \
  --cfg /opt/3fs/etc/hf3fs_fuse_main.toml \
  >> /var/log/3fs/hf3fs_fuse_main.stdout 2>&1 &

# 6) 验证
mount | grep 3fs                    # 应看到 hf3fs_fuse on /3fs/fdp
df -h /3fs/fdp                      # 容量 ≈ 9 盘可用空间之和（RF=1）
echo hello > /3fs/fdp/smoke.txt && cat /3fs/fdp/smoke.txt && rm /3fs/fdp/smoke.txt
```

---

## Step 6 —— LMCache 安装与配置（dskna004）

```bash
# 1) 解源码
mkdir -p /opt/src && tar -xzf 3fs-src-bdcd484.tar.gz -C /opt/src
tar -xzf LMCache_3FS-src-132d7337.tar.gz -C /opt/src

# 2) venv：继承系统 torch 2.12.1（避免离线装 2GB+ 的 torch wheel）
python3 -m venv --system-site-packages /opt/lmcache-venv
source /opt/lmcache-venv/bin/activate
# 若提示缺 ensurepip/venv：apt install python3.10-venv（内网源）或用 bundle wheels 先装 virtualenv

# 3) 离线安装依赖 + hf3fs_py_usrbio
pip install --no-index --find-links=/opt/3fs/wheels \
  setuptools wheel ninja packaging
pip install --no-index --find-links=/opt/3fs/wheels hf3fs_py_usrbio

# 4) 编译安装 LMCache（含原生 hf3fs 扩展, cp310）
#    -e 安装时 pip 会自动从 wheels 目录解析 LMCache 的运行依赖;
#    若报缺包且 wheels 里没有, 回本机用 2.3 节第 6 步的命令补下载该包再传过来
cd /opt/src/LMCache_3FS
export BUILD_HF3FS=1 NO_GPU_EXT=1
export HF3FS_INCLUDE_DIR=/opt/3fs/include       # hf3fs_usrbio.h 等头文件
export HF3FS_LIB_DIR=/opt/3fs/lib               # libhf3fs_api_shared.so (22.04 构建)
export LD_LIBRARY_PATH=/opt/3fs/lib
pip install --no-index --find-links=/opt/3fs/wheels -e . --no-build-isolation

# 5) 冒烟验证
python3 -c "import lmcache; print(lmcache.__version__)"
python3 -c "from lmcache.lmcache_hf3fs import Hf3fsConnector; print('native ext OK')"
python3 -c "import hf3fs_fuse.io as io; print('hf3fs_fuse OK')"
```

**LMCache 配置** `/opt/lmcache-venv/lmcache-3fs-fdp.yaml`：

```yaml
chunk_size: 256
local_cpu: false
remote_storage_plugins: ["hf3fs.primary"]

extra_config:
  remote_storage_plugin.hf3fs.primary.base_path: "/3fs/fdp/lmcache"
  hf3fs_mount_point: "/3fs/fdp"
  hf3fs_iov_size: 209715200        # USRBIO iov 共享内存, 200MB
  hf3fs_ior_entries: 128
  hf3fs_io_depth: 64
  hf3fs_io_thread_num: 8

# ---- FDP write stream 分流（顶层配置项）----
use_fdp: true
fdp_stream_number: 8               # 使用 stream 3..10（对应 PLID 2..9）
start_fdp_stream_id: 3
```

使用方式（无 vllm 的最小验证 / 有 vllm 的正式接入二选一）：

```bash
# 最小验证（直接驱动 engine 写 KV）：
export LMCACHE_CONFIG_FILE=/opt/lmcache-venv/lmcache-3fs-fdp.yaml
export LD_LIBRARY_PATH=/opt/3fs/lib
mkdir -p /3fs/fdp/lmcache
python3 - <<'EOF'
from lmcache.v1 import LMCacheEngine, LMCacheEngineBuilder
from lmcache.v1.config import LMCacheEngineConfig
cfg = LMCacheEngineConfig.from_file("/opt/lmcache-venv/lmcache-3fs-fdp.yaml")
# 具体构造 API 以 tests/e2e / tests/v1 现有用例为准; 启动后写 KV 并观察下述日志
EOF

# 有 vllm 时：vllm serve ... --kv-transfer-config with LMCache (参照 LMCache 官方 vllm 集成文档)
```

观察 LMCache 日志（INFO 级）：`FDP enabled: stream_range=[3, 10]`、写入时 `FDP stream_id=N (hint=<request_id>…)`。

---

## Step 7 —— 端到端 FDP 验证

按顺序做 4 项，全部通过才算部署成功。

**① USRBIO 定向写（dskna004）** —— 走与 LMCache 完全相同的 `set_write_stream` 路径：

```bash
source /opt/lmcache-venv/bin/activate && export LD_LIBRARY_PATH=/opt/3fs/lib
python3 usrbio_stream_bench.py --dir /3fs/fdp/bench --mode fixed --start 3 --gb 2 --files 3
# 期望输出: 3 个文件 × 2GiB 全部写完; 提示期望 PLID = 2
```

**② 存储节点看日志 + RUAMW（三台都查，RF=1 下写入会落到其中某台的某盘）**：

```bash
grep -h "FDP_DEBUG" /var/log/3fs/storage_main.log | tail -20
#   期望: [FDP_DEBUG] USRBIO_IOR_SET_STREAM: ior stream_id=3
#         [FDP_DEBUG] SERVER_WRITE: received streamId=3, chunkId=...
#         [FDP_DEBUG] CHUNK_ENGINE_UPDATE: streamId=3, ...

nvme fdp status /dev/nvme2n1 | grep -A2 "Placement Identifier 2"   # 以及 nvme3n1/nvme4n1
#   期望: PLID 2 的 RUAMW 明显下降（2GiB×文件数 ÷ 4KiB ≈ 150 万 LBA/文件）
#   对照: PLID 0 变化很小, PLID 14/15 有少量 XFS 日志/元数据写入（正常）
```

**③ LMCache 分流验证**：按 Step 6 最小验证写入若干不同 `request_id` 的 KV → 客户端日志 `FDP stream_id=N` 分布在 3–10 → 存储端 RUAMW 在 PLID 2–9 多个桶同时下降。

**④ compaction 分流验证**（需要 Step 0 判定为 A/C 才有意义）：

```bash
# 触发 churn: 多轮写入+删除（bench 的 md5 模式, 每轮删除）
python3 usrbio_stream_bench.py --dir /3fs/fdp/bench --mode md5 --start 3 --streams 8 \
  --gb 1 --files 16 --rounds 4 --delete-each-round
# 存储端观察:
grep -h "CHUNK_ENGINE_UPDATE\|CHUNK_ENGINE_GET_MAX" /var/log/3fs/storage_main.log | tail
#   期望: compaction 搬迁日志 streamId=2; nvme fdp status PLID 1 RUAMW 下降
```

---

## Step 8 —— WAF 实验与数据采样

**原理**：WAF = SSD NAND 写入量 ÷ host 写入量。用 `nvme smart-log` 的 `Data Units Written`（单位 512,000 字节）做 NAND 侧累计值；host 侧写入量取实验工具输出。FDP 分流把 KV 写入分散到 8 个介质区（PLID 2–9），减少 reclaim 时的整区搬移，预期降低 WAF 或改善 GC 行为。

### 8.1 采样方法（存储节点）

```bash
# 采样函数（每台存储节点、每块 FDP 盘各记一条）
sample_waf() {
  local dev=$1 tag=$2
  local duw=$(nvme smart-log $dev | awk -F': *' '/Data Units Written/{print $2}' | tr -d ',')
  echo "$(date +%s) $dev $tag DUW=$duw" >> /root/waf_samples.log
  nvme fdp status $dev | grep -E "Placement Identifier|RUAMW" | \
    awk -v t="$(date +%s)" '{print t, $0}' >> /root/waf_ruamw.log
}
for d in /dev/nvme2n1 /dev/nvme3n1 /dev/nvme4n1; do sample_waf $d R0-idle; done
```

### 8.2 实验流程（dskna004 驱动，存储节点采样）

| 轮次 | 负载（usrbio_stream_bench.py） | 目的 |
|---|---|---|
| R0 | 无（空转采样） | 基线：确认无后台写入干扰 |
| R1 baseline | `--mode zero --gb 32 --files 16 --rounds 4`（共 2TiB host 写入，全部默认放置） | 无 FDP 分流的 WAF |
| R2 fdp | `--mode md5 --start 3 --streams 8 --gb 32 --files 16 --rounds 4`（同量，分流到 PLID 2–9） | FDP 分流后的 WAF |
| R3 churn（可选） | 加 `--delete-each-round`、减小单文件并加轮数 | 叠加 compaction/回收压力后的对比 |

每轮前后在三台节点跑 `sample_waf`，计算：

```
WAF(轮) = Σ9盘 ΔDUW × 512000 ÷ 该轮 host 写入总字节
```

记录表模板（每轮一行）：`轮次 | host 写入(GB) | ΣΔDUW | WAF | RUAMW 分布摘要（PLID 0..15 各自 Δ）`

### 8.3 注意事项

- 实验期间请既有数据使用方暂停对 `/storage/data{2,3,4}` 的读写，否则 DUW 会被污染；实验后 `du -sh` 与 0 节留档对比。
- RF=1 下 host 写入 ≈ 落盘写入，无副本放大，适合干净对比。
- 若 R2 相对 R1 WAF 无改善，先检查 RUAMW 分布：数据若集中在 PLID 0 说明分流没生效（回 Step 7 排障），若分散但 WAF 持平则说明该 workload 本身顺序性好、FDP 收益有限，可加大 churn（R3）再看。

---

## 附录 A —— 速查表

| 项 | 值 |
|---|---|
| mgmtd | 304, node_id=1, RDMA 8000 / TCP 9000, `RDMA://10.10.44.64:8000` |
| meta | 304, node_id=100, RDMA 8001 / TCP 9001 |
| storage | 304=10001, 305=10002, 348=10003; RDMA 8010 / TCP 9010 |
| FDB | 304, `fdp:fdp@10.10.44.64:4500`, memory single |
| targets | target_id = `node_id×100000 + disk_index×1000 + 1`（如 1000100001/1000101001/1000102001…1000302001），disk-index 0/1/2 → data2/3/4 |
| chains | RF=1, chain_id=target_id, chain table 1 |
| cluster_id | `fdp`（所有 launcher + admin_cli 一致） |
| FUSE | dskna004 `/3fs/fdp`, token `/opt/3fs/etc/token.txt` |
| FDP 规划 | compaction=2（PLID 1）；LMCache 3–10（PLID 2–9）；XFS 自留 15/16（PLID 14/15） |
| 日志 | `/var/log/3fs/*.log`；FDP 链路关键词 `FDP_DEBUG` |
| 3fs 源码 | `/opt/src/3fs`（commit bdcd484） |
| LMCache 源码 | `/opt/src/LMCache_3FS`（commit 132d7337） |
| 配置上传 | `admin_cli set-config --type {META,STORAGE,FUSE} --file ...`（改 `*_main.toml` 后必须重新上传） |

常用 admin_cli：

```bash
CLI="/opt/3fs/bin/admin_cli -cfg /opt/3fs/etc/admin_cli.toml"
TOK="--config.user_info.token $(</opt/3fs/etc/token.txt)"
$CLI "list-nodes"; $CLI "list-chains"; $CLI "list-chain-tables"
$CLI "help init-cluster"
```

## 附录 B —— 排障表

| 现象 | 原因 | 处置 |
|---|---|---|
| preflight `GET_MAX = 0` | 运行内核与源码不一致（见 0.1） | 按 Step 0.4 重编内核；判定 C 时 LMCache 分流仍可用但 compaction 分流失效 |
| preflight `GET_MAX ENOTTY` | 内核无该 ioctl | 同上，必须重编 |
| `SET` 返回 EINVAL | `stream_id > GET_MAX`（常见于 GET_MAX=0） | 修内核；确认规划 id ≤ 14 |
| SET OK 但 RUAMW 集中 PLID 0 | stream 在内核块层被丢弃 | 内核版本问题 → Step 0.4 |
| storage_main 起不来，日志 `SHUFFLE_METHOD` | cmake 未带该参数 | 重新 cmake，`-DSHUFFLE_METHOD=g++11`（新旧集群不可混用不同 method） |
| `GLIBC_2.3X not found`（22.04 跑服务端包） | 拿错 bundle：24.04 产物跑在 22.04 | 客户端一律用 client-bundle-22.04 |
| FUSE 起不来，`fuse_loop_cfg_*` undefined | libfuse3 < 3.12 | 确认 `LD_LIBRARY_PATH=/opt/3fs/lib` 且其中有 3.16.1 |
| `hf3fs_fuse.io` import 失败 | 未装 hf3fs_py_usrbio 或 ABI 不符 | 装 client-bundle 里 cp310 wheel；`pip show hf3fs_py_usrbio` |
| `lmcache.lmcache_hf3fs` 编译失败 | 头文件/库路径错 | `HF3FS_INCLUDE_DIR=/opt/3fs/include`、`HF3FS_LIB_DIR=/opt/3fs/lib`；ldd 编出的 .so 应无 not found |
| 客户端连不上 mgmtd | RDMA 不通 / 地址写错 | 地址必须是 IPoIB IP `10.10.44.64`；`ibstat`、`ping 10.10.44.64`；确认 client `ibp...` 口 up |
| admin_cli 报 token 无效 | token 未带 / 文件有空格 | `--config.user_info.token $(<.../token.txt)`；token 文件不要带引号换行 |
| `init-cluster` 后 mgmtd 起不来 | mgmtd_main.toml 有错 | 修配置后**必须清空 FDB 数据重跑** `init-cluster`（官方 FAQ） |
| create-target 失败 "target already exists" | 旧部署残留 | 检查 `/storage/dataX/3fs` 下是否已有 target 目录；确认后仅清理 `3fs` 子目录内容（**不要动子目录以外的数据**） |
| list-nodes 里 storage 不 healthy | target_paths 无权限/路径不存在、aio 不足 | 确认 `/storage/data{2,3,4}/3fs` 已建、`fs.aio-max-nr=67108864`、`ulimit -n` |
| 写入慢/超时 | ulimit、/dev/shm（client iov）不足 | client `/dev/shm` 504G 足够；确认 `hf3fs_iov_size` ≤ shm |
| compaction 日志无 streamId=2 | GET_MAX 探测回退 0（判定 C）或配置未生效 | `grep fdp_compaction_stream_id` 确认配置已 set-config 且 storage **重启过**（该项启动时加载） |
| RUAMW 对不上写入量 | 其他进程并发写同盘 | `du`、`lsof /storage/dataX` 排查；与既有数据使用方协调 |
| 节点时间偏差大 | 3fs 对时间敏感 | `timedatectl` / `chronyc sources` 校验 NTP |

## 附录 C —— 现场执行开场说明（可直接粘贴给现场执行者/现场 AI agent）

> 你将在一个 4 节点测试集群上部署 LMCache + 3FS 的 FDP write stream 功能并测量 WAF。节点与角色：dsksa304（172.16.18.64，mgmtd+meta+FoundationDB+storage）、dsksa305（172.16.18.65，storage）、dsksa348（172.16.18.169，storage）、dskna004（172.16.12.210，FUSE client + LMCache）。请严格按照《deploy_guide_fdp_cluster.md》执行，顺序：Step 0 FDP 能力验收（每台存储节点跑 fdp_preflight.py，**结果是部署闸门**）→ Step 1 代码获取 → Step 2 构建分发 → Step 3 系统准备 → Step 4 集群初始化 → Step 5 FUSE 挂载 → Step 6 LMCache 安装 → Step 7 端到端验证 → Step 8 WAF 实验。
> 安全红线：只在 /storage/data{2,3,4}/3fs 子目录写数据；严禁 mkfs/wipefs/dd/blkdiscard 任何磁盘；严禁触碰 nvme1n1（他人 ZFS 数据）和 nvme0n1（系统盘）；每步前后 du -sh 留档；修改内核或重启节点前必须获得现场负责人批准。
> 交付要求：Step 0 三台节点的 preflight 输出全文、Step 7 的 FDP_DEBUG 日志与 RUAMW 对比、Step 8 每轮的 smart-log DUW 采样记录，均按节点存档发回。
