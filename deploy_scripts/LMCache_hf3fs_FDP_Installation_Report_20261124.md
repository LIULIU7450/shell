# LMCache hf3fs Backend (FDP write stream) Deployment and vLLM Integration Report

| Item | Content |
|---|---|
| Version | **v2** (revised 2026-11-24 18:5x) |
| Reason for revision | v1 used the host `torch 2.12.1+cu130` and skipped CUDA extensions (`NO_GPU_EXT=1`); v2 installs `torch 2.11.0+cu128` inside the venv, **fully compiles `lmcache.c_ops`**, and adds the vLLM integration instructions |
| Host | `dskna004` (3FS mgmtd + meta + FUSE client) |
| Project | `/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream` (LMCache 0.4.7 + hf3fs backend + FDP write stream) |
| Dependent cluster | `/home/smrc/lzh/3fs-main` (3FS + XFS FDP, already deployed, `250228-dev-1-999999-bdcd4843`) |
| Conclusion | **Deployment succeeded, both FDP implementation paths verified** (kernel counters 8/8 streams + NVMe `dsmgmt` PLID + data md5 all passed) |

---

## 1. Summary of Conclusions

1. **torch 2.11.0+cu128** (CUDA 12.8) is installed in the venv `/home/smrc/lzh/lmcache_3fs`, matching the only toolchain available on this machine (`nvcc 12.8`).
2. LMCache was rebuilt, **all 5 native extensions built successfully**, among which:
   - `lmcache.c_ops` (CUDA compute ops, 17.6 MB) — missing in v1, completed in this round;
   - `lmcache_hf3fs` (3FS USRBIO + FDP, 7.1 MB).
3. All three paths of the FDP write chain PASS:
   - **MP / C++ native L2 adapter** (vLLM `LMCacheMPConnector` path);
   - **in-process / Python `HF3fsConnector.sync_put`** (vLLM `LMCacheConnectorV1` path);
   - the underlying `Hf3fsClient` write path (the common lower layer of the previous two).
4. `lmcache server --l2-adapter '{"type":"hf3fs",...}'` was verified to start, and the log confirms
   `Created Hf3fs native L2 adapter` and `FDP enabled: stream_range=[3, 10]`.

---

## 2. Environment and Versions

### 2.1 Host and Cluster

| Item | Value |
|---|---|
| Host / role | dskna004 (172.16.12.210), mgmtd + meta + FUSE client |
| GPU | NVIDIA A100-SXM4-40GB, driver 595.71.05 |
| Kernel | `7.0.0-rc2` (with the `FS_IOC_WRITE_STREAM` FDP patch) |
| CUDA toolchain | `/usr/local/cuda-12.8` (`nvcc 12.8.61`); `/usr/local/cuda-13.0` has runtime libraries only, no nvcc |
| 3FS mount point | `/3fs/stage` (`hf3fs.stage`, `allow_other`) |
| 3FS token | `/opt/3fs/etc/token.txt` |
| Storage nodes | dsksa304/305/348 (172.16.18.64/65/169), data disks `nvme3n1`/`nvme4n1` (XFS) |
| XFS available write streams | `GET_MAX = 14` (hardware 16 − 2 reserved by XFS) |
| `nvme fdp status` | On this disk (PM1763) RUAMW is always 10543104 (a static value), **cannot be used for determination** |

### 2.2 Python Dependency Versions (actually effective inside the venv)

| Package | Version | Note |
|---|---|---|
| Python | 3.10.12 | venv `/home/smrc/lzh/lmcache_3fs` |
| torch | **2.11.0+cu128** | installed in the venv, CUDA 12.8 |
| nvidia-cublas-cu12 | 12.8.4.1 | installed together with torch |
| nvidia-cudnn-cu12 | 9.19.0.56 | |
| nvidia-nccl-cu12 | 2.28.9 | |
| nvidia-cusparse-cu12 / cusolver / cusparselt / cufft / curand / cuda-runtime / cuda-nvrtc / nvjitlink / nvshmem / cupti / cufile / nvtx | 12.8.x / 0.7.1 / 3.4.5 | 15 cu12 packages in total |
| triton | 3.6.0 | installed together with torch |
| cupy-cuda12x | 14.2.0 | required by LMCache `LMCACHE_CUDA_MAJOR=12` |
| lmcache | 0.4.7 (editable) | points to this project's source code |
| numpy / transformers | 2.2.6 / 5.12.1 | from the host site-packages |
| openai / pyzmq / fastapi / uvicorn | 3.58.0 / 27.1.0 / 0.138.0 / 0.49.0 | required by the `lmcache` CLI |
| 3FS Python binding | `hf3fs_py_usrbio.cpython-310-x86_64-linux-gnu.so` | built from 3FS (`build/src/lib/py`), required by the Python Non-MP path |
| 3FS C library | `libhf3fs_api_shared.so` (containing `hf3fs_ior_set_write_stream`) | `/home/smrc/lzh/3fs-main/build/src/lib/api` |

Total venv size **6.8 GB** (of which torch 1.6 GB + nvidia cu12 libraries about 3.7 GB).

---

## 3. Installation and Deployment (fully reproducible)

### 3.1 Create the venv

```bash
python3 -m venv --system-site-packages /home/smrc/lzh/lmcache_3fs
source /home/smrc/lzh/lmcache_3fs/bin/activate
pip install -U pip
pip install "setuptools>=77.0.3,<81.0.0" wheel "packaging>=24.2" ninja "setuptools_scm>=8"
```

> `--system-site-packages` is used to reuse runtime dependencies already present on the host, such as `transformers/numpy/openai`;
> torch is shadowed by the cu128 version in the venv (`import torch` resolves to the venv).

### 3.2 Install the CUDA 12 build of PyTorch

```bash
pip install --no-cache-dir \
  --index-url https://download.pytorch.org/whl/cu128 \
  --extra-index-url https://pypi.org/simple \
  "torch==2.11.0+cu128"
```

Measured: 19 wheels totaling 3.67 GiB, about 2 minutes for download + install (peak download 113 MB/s).

Verification:

```bash
python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
# torch 2.11.0+cu128 12.8 True
```

### 3.3 Build LMCache (including CUDA compute extensions + hf3fs backend)

```bash
cd /home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream

export CUDA_HOME=/usr/local/cuda-12.8
export PATH=$CUDA_HOME/bin:$PATH
export BUILD_HF3FS=1                       # hf3fs native extension
export LMCACHE_CUDA_MAJOR=12               # select cu12 cupy/nixl dependencies
export TORCH_CUDA_ARCH_LIST="8.0"          # A100 sm_80, significantly shortens build time
export HF3FS_INCLUDE_DIR=/home/smrc/lzh/3fs-main/src/lib/api
export HF3FS_LIB_DIR=/home/smrc/lzh/3fs-main/build/src/lib/api
export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_LMCACHE=0.4.7   # source tree has no .git
export MAX_JOBS=48                         # 256-core machine

pip install -e . --no-build-isolation
```

Build artifacts (measured, about 2–3 minutes):

| Extension | Size | Purpose |
|---|---|---|
| `c_ops.cpython-310-x86_64-linux-gnu.so` | 17.6 MB | CUDA compute ops (KV transfer/format conversion) |
| `lmcache_hf3fs.cpython-310-x86_64-linux-gnu.so` | 7.1 MB | 3FS USRBIO connector + **FDP stream** |
| `native_storage_ops` | 4.8 MB | L2 adapter transport layer |
| `lmcache_fs` / `lmcache_redis` | 6.4 / 6.3 MB | generic backends |

Verify that the CUDA backend really loads:

```bash
$ python -c "import lmcache, lmcache.c_ops as o; print(o.__file__)"
.../lmcache/c_ops.cpython-310-x86_64-linux-gnu.so      # not python_ops_fallback
$ python -c "import lmcache.c_ops as o; print(hasattr(o,'multi_layer_kv_transfer'))"
True
```

hf3fs extension link check (rpath points directly at 3FS, no `LD_LIBRARY_PATH` needed at runtime):

```bash
$ ldd lmcache/lmcache_hf3fs*.so | grep hf3fs
  libhf3fs_api_shared.so => /home/smrc/lzh/3fs-main/build/src/lib/api/libhf3fs_api_shared.so
```

### 3.4 Fix the Module Resolution Path (avoid being taken over by the old host lmcache)

An old `lmcache 0.4.7` exists in the host `/usr/local/lib/python3.10/dist-packages`;
the finder of the editable install sits at the end of `sys.meta_path`, so `PathFinder` hits the host package first:

```bash
echo "/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream" \
  > /home/smrc/lzh/lmcache_3fs/lib/python3.10/site-packages/00-lmcache-src.pth
```

```bash
$ python -c "import lmcache; print(lmcache.__file__)"
/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream/lmcache/__init__.py
```

### 3.5 Complete the CLI Dependencies

The `lmcache` CLI imports the bench command (which depends on `openai`); if missing, `lmcache server` fails to start:

```bash
pip install openai
$ lmcache server --help | grep l2-adapter
  [--l2-adapter JSON] [--http-host HTTP_HOST]
```

### 3.6 Installation Self-Check List

| Check | Expectation |
|---|---|
| `import torch` | 2.11.0+cu128 / CUDA 12.8 / `is_available()=True` |
| `lmcache.c_ops` | real extension (not fallback), containing `multi_layer_kv_transfer` |
| `lmcache.lmcache_hf3fs` | exposes `LMCacheHf3fsClient`, constructor includes parameters such as `use_fdp` |
| `from hf3fs_fuse.io import ...` | succeeds (requires `PYTHONPATH`, see §5.2) |
| `lmcache server --l2-adapter` | the parameter exists |
| `Hf3fsL2AdapterConfig.from_dict({...use_fdp:true...})` | validation passes (stream ≤ 255) |

---

## 4. Comparison of the Principles of the Two hf3fs Implementations

| Dimension | **Implementation A: Python Non-MP (`HF3fsConnector`)** | **Implementation B: C++ native (`LMCacheHf3fsClient`)** |
|---|---|---|
| Files | `lmcache/v1/storage_backend/connector/hf3fs_connector.py` | `csrc/storage_backends/hf3fs/connector.cpp` + `hf3fs_l2_adapter.py` |
| Runtime form | LMCache **in-process** (runs inside the vLLM process) | **MP standalone service** (`lmcache server`), vLLM connects over ZMQ |
| 3FS interface | `hf3fs_fuse.io` + `hf3fs_py_usrbio` (Python bindings shipped with 3FS) | directly links `libhf3fs_api_shared.so` (pybind wrapper) |
| stream computation | `start + MD5(key.to_string())[:8] % N` (inside `sync_put`) | `start + MD5(first key of batch)[:8] % N` (inside `NativeConnectorL2Adapter`) |
| FDP issuance | `ior_write.set_write_stream(stream_id)` (Python binding) | `hf3fs_ior_set_write_stream(&conn.write_ior, stream_id)` (C++) |
| hint source | can only be `CacheEngineKey` | `fdp_hint_source` can be `request_id` / `user_id` |
| Extra dependencies | requires `PYTHONPATH` pointing to the 3FS source + build artifacts | none (built-in via rpath) |
| Performance | limited by GIL / Python serialization, single-file synchronous writes | multiple worker threads, batch submission, GIL-free |
| Applicability | quick single-machine verification, single instance | production, multi-instance shared cache, requires lookup/key buffer/eviction |

Both share the same FDP parameter semantics:

| Parameter | Meaning | Recommended in this environment |
|---|---|---|
| `use_fdp` | whether to enable FDP steering | `true` |
| `fdp_stream_number` | number of streams | `8` |
| `start_fdp_stream_id` | starting stream | `3` (1 is left idle, 2 is compaction) |
| `fdp_hint_source` | implementation B only: `request_id` / `user_id` | `request_id` |

FDP stream numbering convention: `0` default placement, `1` reserved, `2` 3FS compaction, `3..14` business
(`GET_MAX=14`; USRBIO upper limit 255).

---

## 5. How the Two hf3fs Implementations Integrate with vLLM

### 5.1 Overview Comparison

| Dimension | **Mode A: in-process** | **Mode B: MP (recommended)** |
|---|---|---|
| vLLM connector | `LMCacheConnectorV1` | `LMCacheMPConnector` |
| LMCache process | same process as vLLM (inside the engine) | separate `lmcache server` process |
| hf3fs implementation | Python `HF3fsConnector` (implementation A) | C++ `Hf3fsL2Adapter` (implementation B) |
| Configuration entry | `LMCACHE_CONFIG_FILE=<yaml>` | `lmcache server --l2-adapter '<JSON>'` |
| vLLM-side parameters | only specify the connector name | requires `lmcache.mp.host/port` |
| Ports | none (in-process) | ZMQ 5555 / HTTP 8080 |
| Multi-instance shared cache | ❌ | ✅ |
| Observability/management API | limited | HTTP `/metrics`, `lmcache describe`, etc. |
| Requires `PYTHONPATH` | ✅ (3FS Python bindings) | ❌ |

> The two modes are **mutually exclusive**: when choosing MP, do not configure a remote backend via `LMCACHE_CONFIG_FILE` on the vLLM side;
> when choosing in-process, do not start `lmcache server`.

---

### 5.2 Mode A: in-process (`LMCacheConnectorV1` + Python `HF3fsConnector`)

#### 5.2.1 Prerequisite: make the 3FS Python bindings importable in the vLLM process

```bash
export PYTHONPATH=/home/smrc/lzh/3fs-main:/home/smrc/lzh/3fs-main/build/src/lib/py:$PYTHONPATH
# verify
python -c "from hf3fs_fuse.io import make_ioring; print('ok')"
```

#### 5.2.2 LMCache configuration file `3fs-inprocess-fdp.yaml`

```yaml
# ---- basics ----
chunk_size: 256                 # must align with vLLM block_size (vLLM default 256)
local_cpu: False                # use only the remote 3FS backend

# ---- remote backend: hf3fs plugin ----
remote_storage_plugins: ["hf3fs.primary"]

# ---- FDP (must be at the top level! placing it in extra_config has no effect) ----
use_fdp: true
fdp_stream_number: 8
start_fdp_stream_id: 3          # 1 idle / 2 compaction / 3..14 business

extra_config:
  # base_path must be a subdirectory of mount_point, multiple paths separated by commas
  remote_storage_plugin.hf3fs.primary.base_path: "/3fs/stage/lmcache_kv/d1,/3fs/stage/lmcache_kv/d2"
  hf3fs_mount_point: "/3fs/stage"
  hf3fs_iov_size: 209715200       # 100MB ~ 2GB
  hf3fs_ior_entries: 256          # 128 ~ 1024
  hf3fs_io_depth: 0               # -128 ~ 128
  hf3fs_numa_id: -1
  hf3fs_io_thread_num: 4          # 2 ~ 16
  save_chunk_meta: true           # default true; mutually exclusive with O_DIRECT
```

#### 5.2.3 Start vLLM

```bash
export LMCACHE_CONFIG_FILE=/path/to/3fs-inprocess-fdp.yaml
export PYTHONPATH=/home/smrc/lzh/3fs-main:/home/smrc/lzh/3fs-main/build/src/lib/py:$PYTHONPATH

vllm serve <MODEL> --port 8000 \
  --kv-transfer-config \
  '{"kv_connector":"LMCacheConnectorV1","kv_role":"kv_both"}'
```

Newer vLLM versions can also use the native KV offloading parameters (equivalent entry point):

```bash
vllm serve <MODEL> \
  --kv-offloading-backend lmcache \
  --kv-offloading-size 64 \
  --disable-hybrid-kv-cache-manager      # this flag is mandatory
```

#### 5.2.4 How to confirm it takes effect

| Location | Expected output |
|---|---|
| vLLM log | `Create 3FSClient_<pid>_<tid> instance success`, `Initialized FSConnector with base paths ...` |
| LMCache log (DEBUG) | `FDP enabled: stream_range=[3, 10]`, `FDP stream_id=<n> (hint=..., range=[3,10])` |
| Storage node | `dmesg` shows `write with stream 3..10` |

---

### 5.3 Mode B: MP mode (`LMCacheMPConnector` + C++ `Hf3fsL2Adapter`, recommended)

#### 5.3.1 Start the LMCache server (with the hf3fs L2 adapter)

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

Measured startup log (verified on this machine):

```
[LMCache HF3FS] Buffer disabled
Created Hf3fs native L2 adapter: /3fs/stage/lmcache_mp_test (workers=2, paths=1)
NativeConnectorL2Adapter FDP enabled: stream_range=[3, 10], hint_source=request_id
LMCache ZMQ cache server is running on tcp://localhost:5555
INFO: Uvicorn running on http://0.0.0.0:8080
```

> `--l1-size-gb` / `--eviction-policy` are required; `--l2-adapter` may appear repeatedly (cascaded multi-level L2).
> Ports: ZMQ **5555** (vLLM connection), HTTP **8080** (management/metrics).

#### 5.3.2 Start vLLM

```bash
# vLLM < 0.20.0: LMCacheMPConnector resolves to the vLLM built-in implementation, just use the name
vllm serve <MODEL> --port 8000 \
  --kv-transfer-config \
  '{"kv_connector":"LMCacheMPConnector","kv_role":"kv_both",
    "kv_connector_extra_config":{"lmcache.mp.host":"127.0.0.1","lmcache.mp.port":5555}}'

# vLLM >= 0.20.0: explicitly point to the implementation shipped with LMCache (protocol updates are more timely)
vllm serve <MODEL> --port 8000 \
  --kv-transfer-config \
  '{"kv_connector":"LMCacheMPConnector",
    "kv_connector_module_path":"lmcache.integration.vllm.lmcache_mp_connector",
    "kv_role":"kv_both",
    "kv_connector_extra_config":{"lmcache.mp.host":"127.0.0.1","lmcache.mp.port":5555}}'
```

| vLLM version | `kv_connector` resolution target | Whether `kv_connector_module_path` is needed |
|---|---|---|
| < 0.20.0 | vLLM built-in `vllm.distributed.kv_transfer.kv_connector.v1.LMCacheMPConnector` | not supported |
| ≥ 0.20.0 | still built-in by default; with module_path it uses `lmcache.integration.vllm.lmcache_mp_connector` | recommended |

#### 5.3.3 `--l2-adapter` Parameter Table (`Hf3fsL2AdapterConfig`)

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | str | — | fixed `"hf3fs"` |
| `mount_point` | str | required | 3FS mount point, e.g. `/3fs/stage` |
| `base_paths` | str | required | comma-separated, must be subdirectories of `mount_point` |
| `num_workers` | int | 4 | number of C++ I/O threads |
| `ior_entries` | int | 256 | concurrency limit per Ior, `[128,1024]` |
| `io_depth` | int | 0 | batch submission depth, `[-128,128]` |
| `numa_id` | int | -1 | `-1` = current NUMA |
| `iov_size` | int | 209715200 | per-thread I/O buffer, `[100MB,2GB]` |
| `enable_key_buffer` | bool | true | in-memory key table (speeds up exists, mind consistency when multiple instances share a directory) |
| `max_capacity_gb` | float | 0 | declared L2 capacity, used by LRU/isolation eviction; 0 = not participating |
| `use_fdp` | bool | false | **enable FDP** |
| `fdp_stream_number` | int | 8 | number of streams |
| `start_fdp_stream_id` | int | 1 | starting stream (3 in this environment) |
| `fdp_hint_source` | str | `request_id` | `request_id` or `user_id` (automatically falls back with a warning if no user_id) |

Upper-bound validation: `start + number - 1 ≤ 255` (USRBIO), and it should be `≤ 14` (the `GET_MAX` of this environment).

---

### 5.4 Key Differences Between the Two Modes (configuration highlights)

| Concern | Mode A (in-process) | Mode B (MP) |
|---|---|---|
| Where FDP parameters go | YAML **top level** | inside the `--l2-adapter` JSON |
| stream computation hint | `CacheEngineKey.to_string()` | first key string of the batch (`model@kv_rank@hash`) |
| `fdp_hint_source` | not supported | supports `request_id`/`user_id` |
| Chunk size | `chunk_size` consistent with vLLM `block_size` | `--chunk-size` consistent with vLLM `block_size` |
| Directory requirement | `base_path` must already exist | `base_paths` must already exist (otherwise configuration validation fails) |
| Runtime dependency | `PYTHONPATH` points to the 3FS source + `build/src/lib/py` | only the LMCache environment is needed |
| Cache sharing | exclusive to each vLLM instance | multiple instances share the same L2 |

---

### 5.5 Common Pitfalls

1. **`use_fdp` placed under `extra_config` has no effect** (the `docs/.../3fs.rst` example writes it that way, which is verified to be ineffective); it must be at the YAML top level.
2. **Do not use streams 1 / 2**: 1 is left idle, 2 is 3FS compaction; mixing them pollutes WAF observation.
3. `fdp_stream_number + start - 1` must not exceed `GET_MAX=14`, otherwise writes degrade to default placement (without any error).
4. Forgetting `PYTHONPATH` in mode A → `ModuleNotFoundError: No module named 'hf3fs_fuse'`.
5. Forgetting `--l1-size-gb` in mode B → startup fails immediately with a missing parameter error.
6. Inconsistent `block_size` / `chunk-size` between vLLM and the LMCache server → lookup always misses.
7. With `enable_key_buffer=true` and multiple servers sharing the same `base_paths`, the key tables of the instances are not aware of each other, lowering cross-instance hit rate; disable it or partition the paths.
8. `nvme fdp status` is invalid on this disk; for troubleshooting look at the kernel counters (§7).

---

## 6. Verification

### 6.1 Verification Methods

| Method | Layer | Description |
|---|---|---|
| `write with stream N` in `dmesg` | XFS / block layer | **primary criterion**, proves the bio carries stream N |
| `dsmgmt` of the tracepoint `nvme:nvme_setup_cmd` | NVMe command | `dsmgmt=(stream-1)<<16` → proves translation into PLID |
| file md5 read-back | application | proves FDP does not affect the data content |
| `nvme fdp status` RUAMW | device | ❌ static value on this disk, unusable |

### 6.2 Verification Scripts

| Script | Path covered |
|---|---|
| `verify_hf3fs_fdp_stream.py` | Phase A: C++ native L2 adapter (mode B); Phase B: `Hf3fsClient` lower layer |
| `verify_hf3fs_inprocess_fdp.py` | **`HF3fsConnector.sync_put`** (the real entry point of mode A) |
| `verify_fdp_nvme_plid.py` | NVMe command-level `dsmgmt` / PLID |

### 6.3 Results: C++ Native (Mode B, Phase A, 8 × 16 MB)

| stream | Kernel count (sum of 3 nodes) | Verdict |
|---|---|---|
| 3 / 4 / 6 / 7 / 8 / 9 / 10 | 384 | PASS |
| 5 | 368 | PASS |

128 entries per stream per node (16 MB × 3 replicas / 128 KB ≈ 384). Streams not expected (except 2, 15, 16) are empty.

### 6.4 Results: Python Non-MP Lower Layer (Phase B, 8 × 16 MB)

| stream | Kernel count | Verdict |
|---|---|---|
| 3 / 4 / 5 / 6 / 8 / 9 / 10 | 384 | PASS |
| 7 | 376 | PASS |

### 6.5 Results: `HF3fsConnector.sync_put` (Real Entry Point of Mode A, 8 × 16 MB)

```
stream   3: 376  [PASS]     stream   7: 384  [PASS]
stream   4: 384  [PASS]     stream   8: 384  [PASS]
stream   5: 376  [PASS]     stream   9: 376  [PASS]
stream   6: 384  [PASS]     stream  10: 384  [PASS]
Result: PASS
```

### 6.6 Results: NVMe Command Level (dsmgmt / PLID, dsksa304)

| Client stream | Observed dsmgmt | PLID | NVMe write command count | Verdict |
|---|---|---|---|---|
| 3 | `131072` (`0x20000`) | 2 | 128 | PASS |
| 12 | `720896` (`0xb0000`) | 11 | 128 | PASS |

Background reference: stream 2 (compaction) → dsmgmt 65536 (PLID 1); XFS reserved stream 15 → 917504 (PLID 14).

### 6.7 Data Integrity

The 8 KV files of Phase A (16 MB each), the 8 files of Phase B, and the 8 files of mode A
**all have matching md5** (`md5_ok=True`).

### 6.8 Overall Verdict

```
C++ native L2 adapter (MP)        : PASS
Python HF3fsConnector (in-proc)   : PASS
Hf3fsClient lower layer           : PASS
NVMe dsmgmt/PLID                  : PASS
Data integrity                    : PASS
```

Verification log: `verify_fdp_run_20261124_r2.log` (primary verification).

---

## 7. Operations and Troubleshooting

```bash
# client side: FUSE ioctl probe (GET_MAX is fixed at 255 at the FUSE layer; the real upper bound is on the storage side)
python - <<'EOF'
import fcntl, os, struct
HF = (3 << 30) | (16 << 16) | (0x68 << 8) | 16
fd = os.open("/3fs/stage/.fdp_probe", os.O_RDWR | os.O_CREAT, 0o644)
for op, sid in ((1, 0), (4, 3), (2, 0)):
    print(op, struct.unpack("IIII", fcntl.ioctl(fd, HF, struct.pack("IIII", op, sid, 0, 0))))
os.close(fd); os.unlink("/3fs/stage/.fdp_probe")
EOF

# storage side: real-time stream counters
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  echo "== $ip"
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip \
    "dmesg | grep -o 'write with stream [0-9]*' | sed 's/.*stream //' | sort -n | uniq -c"
done

# storage side: keep only recent logs, so compaction noise does not drown the signal
sshpass -p '!@345Qwert' ssh root@172.16.18.64 "dmesg -w | grep --line-buffered 'write with stream' | grep -v 'stream 2'"
```

| Symptom | Troubleshooting |
|---|---|
| Counts appear only on stream 2 | business streams not in effect: check whether `use_fdp` is at the top level / whether the JSON carries `use_fdp` |
| Writes succeed but there is no stream count at all | `start+number-1 > GET_MAX(14)`, degraded to default placement |
| `ModuleNotFoundError: hf3fs_fuse` | mode A is missing `PYTHONPATH` |
| `lmcache server` fails to start | missing `openai` (CLI dependency) or `--l1-size-gb` not provided |
| 3FS write `Input/output error` | `stripeSize > number of chains`, unrelated to this feature (see 3FS Deployment Manual §1.3) |

---

## 8. Cleanup and Rollback

```bash
# stop background capture & delete test data (the verification scripts already handle most of this)
for ip in 172.16.18.64 172.16.18.65 172.16.18.169; do
  sshpass -p '!@345Qwert' ssh -o StrictHostKeyChecking=no root@$ip \
    'pkill -9 -f "[d]mesg"; pkill -9 -f "[t]race_pipe"; rm -f /tmp/fdp_watch.log /tmp/nvme_trace.log'
done
rm -rf /3fs/stage/lmcache_fdp_verify /3fs/stage/lmcache_mp_test /3fs/stage/lmcache_kv

# roll back the whole venv
rm -rf /home/smrc/lzh/lmcache_3fs
rm -f /home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream/lmcache/*.so
```

> This time the old `lmcache` in the host `site-packages` was not modified, and the 3FS configuration was not changed
> (`fdp_compaction_stream_id` remains 2).

---

## 9. Appendix

### 9.1 One-Click Reproduction

```bash
# 1) venv + torch cu128
python3 -m venv --system-site-packages /home/smrc/lzh/lmcache_3fs
source /home/smrc/lzh/lmcache_3fs/bin/activate
pip install -U pip
pip install "setuptools>=77.0.3,<81.0.0" wheel ninja "setuptools_scm>=8"
pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu128 \
  --extra-index-url https://pypi.org/simple "torch==2.11.0+cu128"
pip install openai

# 2) build (c_ops + hf3fs)
cd /home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream
export CUDA_HOME=/usr/local/cuda-12.8 PATH=/usr/local/cuda-12.8/bin:$PATH
export BUILD_HF3FS=1 LMCACHE_CUDA_MAJOR=12 TORCH_CUDA_ARCH_LIST=8.0 MAX_JOBS=48
export HF3FS_INCLUDE_DIR=/home/smrc/lzh/3fs-main/src/lib/api
export HF3FS_LIB_DIR=/home/smrc/lzh/3fs-main/build/src/lib/api
export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_LMCACHE=0.4.7
pip install -e . --no-build-isolation

# 3) module path fix
echo "/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream" \
  > /home/smrc/lzh/lmcache_3fs/lib/python3.10/site-packages/00-lmcache-src.pth

# 4) verification
python /home/smrc/lzh/shell/deploy_scripts/verify_hf3fs_fdp_stream.py --data-mb 16
python /home/smrc/lzh/shell/deploy_scripts/verify_hf3fs_inprocess_fdp.py --data-mb 16
python /home/smrc/lzh/shell/deploy_scripts/verify_fdp_nvme_plid.py --stream 3 --size-mb 16 --hosts 172.16.18.64
```

### 9.2 File List

```
/home/smrc/lzh/lmcache_3fs/                                      # venv (6.8 GB, py3.10.12, torch 2.11.0+cu128)
/home/smrc/lzh/lmcache_3fs/lib/python3.10/site-packages/00-lmcache-src.pth
/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream/lmcache/c_ops*.so            # 17.6 MB
/home/smrc/lzh/LMCache_3FS-comet-hf3fs-fdp-write-stream/lmcache/lmcache_hf3fs*.so    # 7.1 MB
/home/smrc/lzh/shell/deploy_scripts/verify_hf3fs_fdp_stream.py
/home/smrc/lzh/shell/deploy_scripts/verify_hf3fs_inprocess_fdp.py
/home/smrc/lzh/shell/deploy_scripts/verify_fdp_nvme_plid.py
/home/smrc/lzh/shell/deploy_scripts/verify_fdp_run_20261124_r2.log
/home/smrc/lzh/shell/deploy_scripts/LMCache_hf3fs_FDP_安装报告_20261124.md
```

### 9.3 Differences from the v1 Report

| Item | v1 | v2 (this report) |
|---|---|---|
| torch | host 2.12.1+cu130 | 2.11.0+cu128 inside the venv |
| `lmcache.c_ops` | not built (Python fallback) | **built and loaded** |
| CUDA toolchain | unused (version mismatch) | nvcc 12.8 + sm_80 |
| Verification paths | C++ native + `Hf3fsClient` | adds **`HF3fsConnector.sync_put`** (the real in-process entry point) |
| vLLM integration | not covered | **§5 fully covers both modes** |

---

**End of report**. Current state: the `lmcache_3fs` venv now contains the complete LMCache (including CUDA ops and the hf3fs FDP backend);
the two implementations can respectively interface with vLLM's in-process / MP deployment forms, and KV cache writes correctly land on FDP streams 3..10 (PLID 2..9).
