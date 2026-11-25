# LMCache hf3fs 后端（FDP write stream）部署与 vLLM 接入报告

| 项 | 内容 |
|---|---|
| 版本 | **v2**（2026-11-24 18:5x 修订） |
| 修订原因 | v1 使用宿主 `torch 2.12.1+cu130` 且跳过 CUDA 扩展（`NO_GPU_EXT=1`）；v2 改为 venv 内安装 `torch 2.11.0+cu128`，**完整编译 `lmcache.c_ops`**，并补充 vLLM 接入方式 |
| 主机 | `dskna004`（3FS mgmtd + meta + FUSE client） |
| 项目 | `/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream`（LMCache 0.4.7 + hf3fs 后端 + FDP write stream） |
| 依赖集群 | `/home/smrc/lzh/3fs-main`（3FS + XFS FDP，已部署，`250228-dev-1-999999-bdcd4843`） |
| 结论 | **部署成功，两条 FDP 实现路径均验证通过**（内核计数 8/8 stream + NVMe `dsmgmt` PLID + 数据 md5 全通过） |

---

## 1. 结论摘要

1. venv `/home/smrc/lzh/lmcache_3fs` 中安装 **torch 2.11.0+cu128**（CUDA 12.8），与本机仅有 `nvcc 12.8` 的工具链匹配。
2. 重新编译 LMCache，**5 个原生扩展全部构建成功**，其中：
   - `lmcache.c_ops`（CUDA 计算算子，17.6 MB）——v1 缺失，本次补齐；
   - `lmcache_hf3fs`（3FS USRBIO + FDP，7.1 MB）。
3. FDP 写入链路三条路径全部 PASS：
   - **MP / C++ 原生 L2 adapter**（vLLM `LMCacheMPConnector` 路径）；
   - **in-process / Python `HF3fsConnector.sync_put`**（vLLM `LMCacheConnectorV1` 路径）；
   - 底层 `Hf3fsClient` 写路径（前两者的公共底层）。
4. `lmcache server --l2-adapter '{"type":"hf3fs",...}'` 实测可启动，日志确认
   `Created Hf3fs native L2 adapter` 且 `FDP enabled: stream_range=[3, 10]`。

---

## 2. 环境与版本

### 2.1 主机与集群

| 项 | 值 |
|---|---|
| 主机 / 角色 | dskna004（172.16.12.210），mgmtd + meta + FUSE client |
| GPU | NVIDIA A100-SXM4-40GB，驱动 595.71.05 |
| 内核 | `7.0.0-rc2`（含 `FS_IOC_WRITE_STREAM` FDP 补丁） |
| CUDA 工具链 | `/usr/local/cuda-12.8`（`nvcc 12.8.61`）；`/usr/local/cuda-13.0` 仅运行库、无 nvcc |
| 3FS 挂载点 | `/3fs/stage`（`hf3fs.stage`，`allow_other`） |
| 3FS token | `/opt/3fs/etc/token.txt` |
| 存储节点 | dsksa304/305/348（172.16.18.64/65/169），数据盘 `nvme3n1`/`nvme4n1`（XFS） |
| XFS 可用写流 | `GET_MAX = 14`（硬件 16 − XFS 保留 2） |
| `nvme fdp status` | 本盘（PM1763）RUAMW 恒为 10543104（静态值），**不可用于判定** |

### 2.2 Python 依赖版本（venv 内实际生效）

| 包 | 版本 | 说明 |
|---|---|---|
| Python | 3.10.12 | venv `/home/smrc/lzh/lmcache_3fs` |
| torch | **2.11.0+cu128** | venv 内安装，CUDA 12.8 |
| nvidia-cublas-cu12 | 12.8.4.1 | 随 torch 安装 |
| nvidia-cudnn-cu12 | 9.19.0.56 | |
| nvidia-nccl-cu12 | 2.28.9 | |
| nvidia-cusparse-cu12 / cusolver / cusparselt / cufft / curand / cuda-runtime / cuda-nvrtc / nvjitlink / nvshmem / cupti / cufile / nvtx | 12.8.x / 0.7.1 / 3.4.5 | 共 15 个 cu12 包 |
| triton | 3.6.0 | 随 torch |
| cupy-cuda12x | 14.2.0 | LMCache `LMCACHE_CUDA_MAJOR=12` 依赖 |
| lmcache | 0.4.7（editable） | 指向本项目源码 |
| numpy / transformers | 2.2.6 / 5.12.1 | 来自宿主 site-packages |
| openai / pyzmq / fastapi / uvicorn | 3.58.0 / 27.1.0 / 0.138.0 / 0.49.0 | `lmcache` CLI 需要 |
| 3FS Python 绑定 | `hf3fs_py_usrbio.cpython-310-x86_64-linux-gnu.so` | 由 3FS 构建（`build/src/lib/py`），Python Non-MP 路径依赖 |
| 3FS C 库 | `libhf3fs_api_shared.so`（含 `hf3fs_ior_set_write_stream`） | `/home/smrc/lzh/3fs-main/build/src/lib/api` |

venv 总体积 **6.8 GB**（其中 torch 1.6 GB + nvidia cu12 库约 3.7 GB）。

---

## 3. 安装部署（完整可复现）

### 3.1 创建 venv

```bash
python3 -m venv --system-site-packages /home/smrc/lzh/lmcache_3fs
source /home/smrc/lzh/lmcache_3fs/bin/activate
pip install -U pip
pip install "setuptools>=77.0.3,<81.0.0" wheel "packaging>=24.2" ninja "setuptools_scm>=8"
```

> `--system-site-packages` 用于复用宿主已有的 `transformers/numpy/openai` 等运行时依赖；
> torch 会被 venv 内的 cu128 版本遮蔽（`import torch` 指向 venv）。

### 3.2 安装 CUDA 12 版 PyTorch

```bash
pip install --no-cache-dir \
  --index-url https://download.pytorch.org/whl/cu128 \
  --extra-index-url https://pypi.org/simple \
  "torch==2.11.0+cu128"
```

实测：19 个轮子共 3.67 GiB，下载 + 安装总计约 2 分钟（峰值下载 113 MB/s）。

验证：

```bash
python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
# torch 2.11.0+cu128 12.8 True
```

### 3.3 编译 LMCache（含 CUDA 计算扩展 + hf3fs 后端）

```bash
cd /home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream

export CUDA_HOME=/usr/local/cuda-12.8
export PATH=$CUDA_HOME/bin:$PATH
export BUILD_HF3FS=1                       # hf3fs 原生扩展
export LMCACHE_CUDA_MAJOR=12               # 选 cu12 版 cupy/nixl 依赖
export TORCH_CUDA_ARCH_LIST="8.0"          # A100 sm_80，显著缩短编译时间
export HF3FS_INCLUDE_DIR=/home/smrc/lzh/3fs-main/src/lib/api
export HF3FS_LIB_DIR=/home/smrc/lzh/3fs-main/build/src/lib/api
export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_LMCACHE=0.4.7   # 源码树无 .git
export MAX_JOBS=48                         # 256 核机器

pip install -e . --no-build-isolation
```

编译产物（实测约 2–3 分钟）：

| 扩展 | 大小 | 作用 |
|---|---|---|
| `c_ops.cpython-310-x86_64-linux-gnu.so` | 17.6 MB | CUDA 计算算子（KV 传输/格式转换） |
| `lmcache_hf3fs.cpython-310-x86_64-linux-gnu.so` | 7.1 MB | 3FS USRBIO 连接器 + **FDP stream** |
| `native_storage_ops` | 4.8 MB | L2 adapter 传递层 |
| `lmcache_fs` / `lmcache_redis` | 6.4 / 6.3 MB | 通用后端 |

验证 CUDA 后端真实加载：

```bash
$ python -c "import lmcache, lmcache.c_ops as o; print(o.__file__)"
.../lmcache/c_ops.cpython-310-x86_64-linux-gnu.so      # 非 python_ops_fallback
$ python -c "import lmcache.c_ops as o; print(hasattr(o,'multi_layer_kv_transfer'))"
True
```

hf3fs 扩展链接检查（rpath 直连 3FS，运行时无需 `LD_LIBRARY_PATH`）：

```bash
$ ldd lmcache/lmcache_hf3fs*.so | grep hf3fs
  libhf3fs_api_shared.so => /home/smrc/lzh/3fs-main/build/src/lib/api/libhf3fs_api_shared.so
```

### 3.4 修正模块解析路径（避免被宿主旧 lmcache 抢占）

宿主 `/usr/local/lib/python3.10/dist-packages` 里存在旧的 `lmcache 0.4.7`，
editable 安装的 finder 位于 `sys.meta_path` 末尾，会被 `PathFinder` 先命中宿主包：

```bash
echo "/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream" \
  > /home/smrc/lzh/lmcache_3fs/lib/python3.10/site-packages/00-lmcache-src.pth
```

```bash
$ python -c "import lmcache; print(lmcache.__file__)"
/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream/lmcache/__init__.py
```

### 3.5 补齐 CLI 依赖

`lmcache` CLI 会 import bench 命令（依赖 `openai`），缺失会导致 `lmcache server` 无法启动：

```bash
pip install openai
$ lmcache server --help | grep l2-adapter
  [--l2-adapter JSON] [--http-host HTTP_HOST]
```

### 3.6 安装自检清单

| 检查 | 期望 |
|---|---|
| `import torch` | 2.11.0+cu128 / CUDA 12.8 / `is_available()=True` |
| `lmcache.c_ops` | 真实扩展（非 fallback），含 `multi_layer_kv_transfer` |
| `lmcache.lmcache_hf3fs` | 暴露 `LMCacheHf3fsClient`，构造含 `use_fdp` 等参数 |
| `from hf3fs_fuse.io import ...` | 成功（需 `PYTHONPATH`，见 §5.2） |
| `lmcache server --l2-adapter` | 参数存在 |
| `Hf3fsL2AdapterConfig.from_dict({...use_fdp:true...})` | 校验通过（stream ≤ 255） |

---

## 4. hf3fs 两种实现的原理对比

| 维度 | **实现 A：Python Non-MP（`HF3fsConnector`）** | **实现 B：C++ 原生（`LMCacheHf3fsClient`）** |
|---|---|---|
| 文件 | `lmcache/v1/storage_backend/connector/hf3fs_connector.py` | `csrc/storage_backends/hf3fs/connector.cpp` + `hf3fs_l2_adapter.py` |
| 运行形态 | LMCache **in-process**（跑在 vLLM 进程内） | **MP 独立服务**（`lmcache server`），vLLM 通过 ZMQ 连接 |
| 3FS 接口 | `hf3fs_fuse.io` + `hf3fs_py_usrbio`（3FS 自带 Python 绑定） | 直接链接 `libhf3fs_api_shared.so`（pybind 封装） |
| stream 计算 | `start + MD5(key.to_string())[:8] % N`（`sync_put` 内） | `start + MD5(批首 key)[:8] % N`（`NativeConnectorL2Adapter` 内） |
| FDP 下发 | `ior_write.set_write_stream(stream_id)`（Python 绑定） | `hf3fs_ior_set_write_stream(&conn.write_ior, stream_id)`（C++） |
| hint 来源 | 只能是 `CacheEngineKey` | `fdp_hint_source` 可选 `request_id` / `user_id` |
| 额外依赖 | 需 `PYTHONPATH` 指向 3FS 源码 + 编译产物 | 无需（rpath 内建） |
| 性能 | 受 GIL / Python 序列化限制，单文件同步写 | 多 worker 线程、批量提交、GIL-free |
| 适用 | 单机快速验证、单实例 | 生产、多实例共享缓存、需要 lookup/key buffer/eviction |

两者共用 FDP 参数语义：

| 参数 | 含义 | 本环境建议 |
|---|---|---|
| `use_fdp` | 是否启用 FDP 分流 | `true` |
| `fdp_stream_number` | stream 个数 | `8` |
| `start_fdp_stream_id` | 起始 stream | `3`（1 空置、2 为 compaction） |
| `fdp_hint_source` | 仅实现 B：`request_id` / `user_id` | `request_id` |

FDP stream 编号约定：`0` 默认放置、`1` 保留、`2` 3FS compaction、`3..14` 业务
（`GET_MAX=14`；USRBIO 上限 255）。

---

## 5. hf3fs 两种实现如何接入 vLLM

### 5.1 总览对比

| 维度 | **方式 A：in-process** | **方式 B：MP（推荐）** |
|---|---|---|
| vLLM connector | `LMCacheConnectorV1` | `LMCacheMPConnector` |
| LMCache 进程 | 与 vLLM 同进程（引擎内） | 独立 `lmcache server` 进程 |
| hf3fs 实现 | Python `HF3fsConnector`（实现 A） | C++ `Hf3fsL2Adapter`（实现 B） |
| 配置入口 | `LMCACHE_CONFIG_FILE=<yaml>` | `lmcache server --l2-adapter '<JSON>'` |
| vLLM 侧参数 | 只指定 connector 名 | 需 `lmcache.mp.host/port` |
| 端口 | 无（进程内） | ZMQ 5555 / HTTP 8080 |
| 多实例共享缓存 | ❌ | ✅ |
| 观测/管理 API | 有限 | HTTP `/metrics`、`lmcache describe` 等 |
| 需要 `PYTHONPATH` | ✅（3FS Python 绑定） | ❌ |

> 两种方式**互斥**：选择 MP 时，vLLM 侧不要再配 `LMCACHE_CONFIG_FILE` 的远程后端；
> 选择 in-process 时不要启动 `lmcache server`。

---

### 5.2 方式 A：in-process（`LMCacheConnectorV1` + Python `HF3fsConnector`）

#### 5.2.1 前置：让 vLLM 进程能 import 3FS Python 绑定

```bash
export PYTHONPATH=/home/smrc/lzh/3fs-main:/home/smrc/lzh/3fs-main/build/src/lib/py:$PYTHONPATH
# 校验
python -c "from hf3fs_fuse.io import make_ioring; print('ok')"
```

#### 5.2.2 LMCache 配置文件 `3fs-inprocess-fdp.yaml`

```yaml
# ---- 基础 ----
chunk_size: 256                 # 必须与 vLLM block_size 对齐（vLLM 默认 256）
local_cpu: False                # 只用远程 3FS 后端

# ---- 远程后端：hf3fs 插件 ----
remote_storage_plugins: ["hf3fs.primary"]

# ---- FDP（务必写在顶层！写在 extra_config 里不生效）----
use_fdp: true
fdp_stream_number: 8
start_fdp_stream_id: 3          # 1 空置 / 2 compaction / 3..14 业务

extra_config:
  # base_path 必须是 mount_point 子目录，可逗号分隔多个
  remote_storage_plugin.hf3fs.primary.base_path: "/3fs/stage/lmcache_kv/d1,/3fs/stage/lmcache_kv/d2"
  hf3fs_mount_point: "/3fs/stage"
  hf3fs_iov_size: 209715200       # 100MB ~ 2GB
  hf3fs_ior_entries: 256          # 128 ~ 1024
  hf3fs_io_depth: 0               # -128 ~ 128
  hf3fs_numa_id: -1
  hf3fs_io_thread_num: 4          # 2 ~ 16
  save_chunk_meta: true           # 默认 true；与 O_DIRECT 互斥
```

#### 5.2.3 启动 vLLM

```bash
export LMCACHE_CONFIG_FILE=/path/to/3fs-inprocess-fdp.yaml
export PYTHONPATH=/home/smrc/lzh/3fs-main:/home/smrc/lzh/3fs-main/build/src/lib/py:$PYTHONPATH

vllm serve <MODEL> --port 8000 \
  --kv-transfer-config \
  '{"kv_connector":"LMCacheConnectorV1","kv_role":"kv_both"}'
```

vLLM 新版也可用原生 KV offloading 参数（等价入口）：

```bash
vllm serve <MODEL> \
  --kv-offloading-backend lmcache \
  --kv-offloading-size 64 \
  --disable-hybrid-kv-cache-manager      # 该 flag 必带
```

#### 5.2.4 生效判断

| 位置 | 期望输出 |
|---|---|
| vLLM 日志 | `Create 3FSClient_<pid>_<tid> instance success`、`Initialized FSConnector with base paths ...` |
| LMCache 日志（DEBUG） | `FDP enabled: stream_range=[3, 10]`、`FDP stream_id=<n> (hint=..., range=[3,10])` |
| 存储节点 | `dmesg` 出现 `write with stream 3..10` |

---

### 5.3 方式 B：MP 模式（`LMCacheMPConnector` + C++ `Hf3fsL2Adapter`，推荐）

#### 5.3.1 启动 LMCache server（带 hf3fs L2 adapter）

```bash
lmcache server \
  --host 0.0.0.0 --port 5555 \
  --http-host 0.0.0.0 --http-port 8080 \
  --chunk-size 256 \
  --l1-size-gb 64 --eviction-policy LRU \
  --l2-adapter '{
    "type": "hf3fs",
    "mount_point": "/3fs/stage",
    "base_paths": "/3fs/stage/lmcache_kv/d1,/3fs/stage/lmcache_kv/d2",
    "num_workers": 4,
    "ior_entries": 256,
    "io_depth": 0,
    "numa_id": -1,
    "iov_size": 209715200,
    "enable_key_buffer": true,
    "max_capacity_gb": 1024,
    "use_fdp": true,
    "fdp_stream_number": 8,
    "start_fdp_stream_id": 3,
    "fdp_hint_source": "request_id"
  }'
```

实测启动日志（本机验证）：

```
[LMCache HF3FS] Buffer disabled
Created Hf3fs native L2 adapter: /3fs/stage/lmcache_mp_test (workers=2, paths=1)
NativeConnectorL2Adapter FDP enabled: stream_range=[3, 10], hint_source=request_id
LMCache ZMQ cache server is running on tcp://localhost:5555
INFO: Uvicorn running on http://0.0.0.0:8080
```

> `--l1-size-gb` / `--eviction-policy` 为必填；`--l2-adapter` 可重复出现（级联多级 L2）。
> 端口：ZMQ **5555**（vLLM 连接）、HTTP **8080**（管理/指标）。

#### 5.3.2 启动 vLLM

```bash
# vLLM < 0.20.0：LMCacheMPConnector 解析到 vLLM 内置实现，直接写名字即可
vllm serve <MODEL> --port 8000 \
  --kv-transfer-config \
  '{"kv_connector":"LMCacheMPConnector","kv_role":"kv_both",
    "kv_connector_extra_config":{"lmcache.mp.host":"127.0.0.1","lmcache.mp.port":5555}}'

# vLLM >= 0.20.0：建议显式指向 LMCache 自带实现（协议更新更及时）
vllm serve <MODEL> --port 8000 \
  --kv-transfer-config \
  '{"kv_connector":"LMCacheMPConnector",
    "kv_connector_module_path":"lmcache.integration.vllm.lmcache_mp_connector",
    "kv_role":"kv_both",
    "kv_connector_extra_config":{"lmcache.mp.host":"127.0.0.1","lmcache.mp.port":5555}}'
```

| vLLM 版本 | `kv_connector` 解析目标 | 是否需要 `kv_connector_module_path` |
|---|---|---|
| < 0.20.0 | vLLM 内置 `vllm.distributed.kv_transfer.kv_connector.v1.LMCacheMPConnector` | 不支持 |
| ≥ 0.20.0 | 默认仍是内置；加 module_path 后使用 `lmcache.integration.vllm.lmcache_mp_connector` | 建议加 |

#### 5.3.3 `--l2-adapter` 参数表（`Hf3fsL2AdapterConfig`）

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `type` | str | — | 固定 `"hf3fs"` |
| `mount_point` | str | 必填 | 3FS 挂载点，如 `/3fs/stage` |
| `base_paths` | str | 必填 | 逗号分隔，必须是 `mount_point` 子目录 |
| `num_workers` | int | 4 | C++ I/O 线程数 |
| `ior_entries` | int | 256 | 每个 Ior 并发上限，`[128,1024]` |
| `io_depth` | int | 0 | 批量提交深度，`[-128,128]` |
| `numa_id` | int | -1 | `-1` = 当前 NUMA |
| `iov_size` | int | 209715200 | 每线程 I/O 缓冲，`[100MB,2GB]` |
| `enable_key_buffer` | bool | true | 内存 key 表（加速 exists，多实例共享目录时注意一致性） |
| `max_capacity_gb` | float | 0 | 声明的 L2 容量，供 LRU/隔离淘汰；0 = 不参与 |
| `use_fdp` | bool | false | **开启 FDP** |
| `fdp_stream_number` | int | 8 | stream 个数 |
| `start_fdp_stream_id` | int | 1 | 起始 stream（本环境用 3） |
| `fdp_hint_source` | str | `request_id` | `request_id` 或 `user_id`（无 user_id 自动回退并告警） |

上限校验：`start + number - 1 ≤ 255`（USRBIO），且应 `≤ 14`（本环境 `GET_MAX`）。

---

### 5.4 两种方式的关键差异（配置要点）

| 关注点 | 方式 A（in-process） | 方式 B（MP） |
|---|---|---|
| FDP 参数写在 | YAML **顶层** | `--l2-adapter` JSON 内 |
| stream 计算 hint | `CacheEngineKey.to_string()` | 批首 key 字符串（`model@kv_rank@hash`） |
| `fdp_hint_source` | 不支持 | 支持 `request_id`/`user_id` |
| chunk 大小 | `chunk_size` 与 vLLM `block_size` 一致 | `--chunk-size` 与 vLLM `block_size` 一致 |
| 目录要求 | `base_path` 必须已存在 | `base_paths` 必须已存在（否则配置校验报错） |
| 运行依赖 | `PYTHONPATH` 指 3FS 源码 + `build/src/lib/py` | 仅需 LMCache 环境 |
| 缓存共享 | 每 vLLM 实例独享 | 多实例共享同一 L2 |

---

### 5.5 常见坑

1. **`use_fdp` 写在 `extra_config` 下不生效**（`docs/.../3fs.rst` 示例如此写，实测无效），必须放 YAML 顶层。
2. **stream 1 / 2 不要用**：1 空置、2 是 3FS compaction，混用会污染 WAF 观测。
3. `fdp_stream_number + start - 1` 不要超过 `GET_MAX=14`，否则写入退化为默认放置（不报错）。
4. 方式 A 忘记 `PYTHONPATH` → `ModuleNotFoundError: No module named 'hf3fs_fuse'`。
5. 方式 B 忘记 `--l1-size-gb` → 启动直接报参数缺失。
6. vLLM 与 LMCache server 的 `block_size` / `chunk-size` 不一致 → lookup 永远 miss。
7. `enable_key_buffer=true` 且多个 server 共用同一 `base_paths` 时，各实例的 key 表不会互相感知，跨实例命中率下降；可关闭或分区。
8. `nvme fdp status` 在本盘无效，排障请看内核计数（§7）。

---

## 6. 验证

### 6.1 判定手段

| 手段 | 层级 | 说明 |
|---|---|---|
| `dmesg` 中 `write with stream N` | XFS / 块层 | **主判据**，证明 bio 带 stream N |
| tracepoint `nvme:nvme_setup_cmd` 的 `dsmgmt` | NVMe 命令 | `dsmgmt=(stream-1)<<16` → 证明翻译为 PLID |
| 文件 md5 回读 | 应用 | 证明 FDP 不影响数据内容 |
| `nvme fdp status` RUAMW | 设备 | ❌ 本盘静态值，不可用 |

### 6.2 验证脚本

| 脚本 | 覆盖路径 |
|---|---|
| `verify_hf3fs_fdp_stream.py` | Phase A：C++ 原生 L2 adapter（方式 B）；Phase B：`Hf3fsClient` 底层 |
| `verify_hf3fs_inprocess_fdp.py` | **`HF3fsConnector.sync_put`**（方式 A 的真实入口） |
| `verify_fdp_nvme_plid.py` | NVMe 命令级 `dsmgmt` / PLID |

### 6.3 结果：C++ 原生（方式 B，Phase A，8 × 16 MB）

| stream | 内核计数（3 节点合计） | 判定 |
|---|---|---|
| 3 / 4 / 6 / 7 / 8 / 9 / 10 | 384 | PASS |
| 5 | 368 | PASS |

每节点单 stream 128 条（16 MB × 3 副本 / 128 KB ≈ 384）。未被预期 stream（除 2、15、16）为空。

### 6.4 结果：Python Non-MP 底层（Phase B，8 × 16 MB）

| stream | 内核计数 | 判定 |
|---|---|---|
| 3 / 4 / 5 / 6 / 8 / 9 / 10 | 384 | PASS |
| 7 | 376 | PASS |

### 6.5 结果：`HF3fsConnector.sync_put`（方式 A 真实入口，8 × 16 MB）

```
stream   3: 376  [PASS]     stream   7: 384  [PASS]
stream   4: 384  [PASS]     stream   8: 384  [PASS]
stream   5: 376  [PASS]     stream   9: 376  [PASS]
stream   6: 384  [PASS]     stream  10: 384  [PASS]
结果: PASS
```

### 6.6 结果：NVMe 命令级（dsmgmt / PLID，dsksa304）

| 客户端 stream | 观测 dsmgmt | PLID | NVMe 写命令数 | 判定 |
|---|---|---|---|---|
| 3 | `131072` (`0x20000`) | 2 | 128 | PASS |
| 12 | `720896` (`0xb0000`) | 11 | 128 | PASS |

背景参照：stream 2（compaction）→ dsmgmt 65536（PLID 1）；XFS 保留流 15 → 917504（PLID 14）。

### 6.7 数据完整性

Phase A 的 8 个 KV 文件（16 MB/个）、Phase B 的 8 个文件、方式 A 的 8 个文件
**md5 全部匹配**（`md5_ok=True`）。

### 6.8 总判定

```
C++ 原生 L2 adapter (MP)        : PASS
Python HF3fsConnector (in-proc) : PASS
HF3fsClient 底层                : PASS
NVMe dsmgmt/PLID                : PASS
数据完整性                      : PASS
```

验证日志：`verify_fdp_run_20261124_r2.log`（主验证）。

---

## 7. 运维与排障

```bash
# 客户端：FUSE ioctl 探测（GET_MAX 在 FUSE 层固定 255，真实上限在存储侧）
python - <<'EOF'
import fcntl, os, struct
HF = (3 << 30) | (16 << 16) | (0x68 << 8) | 16
fd = os.open("/3fs/stage/.fdp_probe", os.O_RDWR | os.O_CREAT, 0o644)
for op, sid in ((1, 0), (4, 3), (2, 0)):
    print(op, struct.unpack("IIII", fcntl.ioctl(fd, HF, struct.pack("IIII", op, sid, 0, 0))))
os.close(fd); os.unlink("/3fs/stage/.fdp_probe")
EOF

# 存储侧：实时 stream 计数
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  echo "== $ip"
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip \
    "dmesg | grep -o 'write with stream [0-9]*' | sed 's/.*stream //' | sort -n | uniq -c"
done

# 存储侧：只保留最近日志，避免 compaction 噪声淹没
sshpass -p '!@345Qwert' ssh root@172.16.18.64 "dmesg -w | grep --line-buffered 'write with stream' | grep -v 'stream 2'"
```

| 现象 | 排查 |
|---|---|
| 计数只出现在 stream 2 | 业务 stream 未生效：检查 `use_fdp` 是否在顶层 / JSON 是否带 `use_fdp` |
| 写入成功但无任何 stream 计数 | `start+number-1 > GET_MAX(14)`，退化为默认放置 |
| `ModuleNotFoundError: hf3fs_fuse` | 方式 A 缺 `PYTHONPATH` |
| `lmcache server` 起不来 | 缺 `openai`（CLI 依赖）或 `--l1-size-gb` 未给 |
| 3FS 写 `Input/output error` | `stripeSize > 链数`，与本功能无关（见 3FS 部署手册 §1.3） |

---

## 8. 清理与回滚

```bash
# 停止后台抓取 & 删除测试数据（验证脚本已自动处理大部分）
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip \
    'pkill -9 -f "[d]mesg"; pkill -9 -f "[t]race_pipe"; rm -f /tmp/fdp_watch.log /tmp/nvme_trace.log'
done
rm -rf /3fs/stage/lmcache_fdp_verify /3fs/stage/lmcache_mp_test /3fs/stage/lmcache_kv

# 回滚整个 venv
rm -rf /home/smrc/lzh/lmcache_3fs
rm -f /home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream/lmcache/*.so
```

> 本次未修改宿主 `site-packages` 中的旧 `lmcache`，未改动 3FS 配置
> （`fdp_compaction_stream_id` 仍为 2）。

---

## 9. 附录

### 9.1 一键复现

```bash
# 1) venv + torch cu128
python3 -m venv --system-site-packages /home/smrc/lzh/lmcache_3fs
source /home/smrc/lzh/lmcache_3fs/bin/activate
pip install -U pip
pip install "setuptools>=77.0.3,<81.0.0" wheel ninja "setuptools_scm>=8"
pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu128 \
  --extra-index-url https://pypi.org/simple "torch==2.11.0+cu128"
pip install openai

# 2) 编译（c_ops + hf3fs）
cd /home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream
export CUDA_HOME=/usr/local/cuda-12.8 PATH=/usr/local/cuda-12.8/bin:$PATH
export BUILD_HF3FS=1 LMCACHE_CUDA_MAJOR=12 TORCH_CUDA_ARCH_LIST=8.0 MAX_JOBS=48
export HF3FS_INCLUDE_DIR=/home/smrc/lzh/3fs-main/src/lib/api
export HF3FS_LIB_DIR=/home/smrc/lzh/3fs-main/build/src/lib/api
export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_LMCACHE=0.4.7
pip install -e . --no-build-isolation

# 3) 模块路径修正
echo "/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream" \
  > /home/smrc/lzh/lmcache_3fs/lib/python3.10/site-packages/00-lmcache-src.pth

# 4) 验证
python /home/smrc/lzh/shell/deploy_scripts/verify_hf3fs_fdp_stream.py --data-mb 16
python /home/smrc/lzh/shell/deploy_scripts/verify_hf3fs_inprocess_fdp.py --data-mb 16
python /home/smrc/lzh/shell/deploy_scripts/verify_fdp_nvme_plid.py --stream 3 --size-mb 16 --hosts 172.16.18.64
```

### 9.2 文件清单

```
/home/smrc/lzh/lmcache_3fs/                                      # venv（6.8 GB, py3.10.12, torch 2.11.0+cu128）
/home/smrc/lzh/lmcache_3fs/lib/python3.10/site-packages/00-lmcache-src.pth
/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream/lmcache/c_ops*.so            # 17.6 MB
/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream/lmcache/lmcache_hf3fs*.so    # 7.1 MB
/home/smrc/lzh/shell/deploy_scripts/verify_hf3fs_fdp_stream.py
/home/smrc/lzh/shell/deploy_scripts/verify_hf3fs_inprocess_fdp.py
/home/smrc/lzh/shell/deploy_scripts/verify_fdp_nvme_plid.py
/home/smrc/lzh/shell/deploy_scripts/verify_fdp_run_20261124_r2.log
/home/smrc/lzh/shell/deploy_scripts/LMCache_hf3fs_FDP_安装报告_20261124.md
```

### 9.3 与 v1 报告的差异

| 项 | v1 | v2（本报告） |
|---|---|---|
| torch | 宿主 2.12.1+cu130 | venv 内 2.11.0+cu128 |
| `lmcache.c_ops` | 未构建（回退 Python） | **已构建并加载** |
| CUDA 工具链 | 未使用（版本不匹配） | nvcc 12.8 + sm_80 |
| 验证路径 | C++ 原生 + `Hf3fsClient` | 增加 **`HF3fsConnector.sync_put`**（in-process 真实入口） |
| vLLM 接入 | 未覆盖 | **§5 完整覆盖两种方式** |

---

**报告结束**。当前状态：`lmcache_3fs` venv 内已具备完整 LMCache（含 CUDA 算子与 hf3fs FDP 后端），
两种实现分别可对接 vLLM 的 in-process / MP 部署形态，KV cache 写入可准确落到 FDP stream 3..10（PLID 2..9）。
