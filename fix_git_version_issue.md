# 3fs 构建失败修复指南：GitVersion 问题（压缩包场景）

## 问题背景

### 症状

在目标机 `dskna004` 上执行 `cmake --build build -j 32` 时，构建在 1% 进度失败：

```
fatal: not a git repository (or any of the parent directories): .git
date: invalid date '@'
CMake Error at /home/smrc/lzh/3fs-main/cmake/GitVersion.cmake:21 (LIST):
  LIST GET given empty list
gmake[2]: *** [src/common/CMakeFiles/AlwaysCheckGit.dir/build.make:70: src/common/CMakeFiles/AlwaysCheckGit] Error 1
```

### 根因

目标机上的 3fs 源码是从公司内部 git 网页下载的**压缩包**，本身不带 `.git/` 目录。

3fs 的 `cmake/GitVersion.cmake` 脚本假设源码一定在 git 仓库里，执行时会：
1. 调用 `git rev-parse`、`git log`、`git describe` 提取 commit hash、时间戳、tag
2. 把这些信息写入 `build/git-state.txt` 和 `build/src/common/utils/VersionInfo.cc`
3. 后续构建读取这些文件生成版本信息

压缩包场景下，所有 git 命令都失败，变量全是空的，导致：
- `date -d @` 收到空参数 → `invalid date '@'`
- `file(STRINGS ...)` 读到空文件 → `LIST GET given empty list`
- cmake 报错退出 → 构建失败

---

## 方案 B：手动创建 git-state.txt 和 VersionInfo.cc

**优点**：
- 不需要改 cmake 代码
- 不需要重新打包源码
- 3-5 分钟即可完成，立即恢复构建

**缺点**：
- 版本信息是占位符（不影响功能，只影响 `hf3fs --version` 等命令输出）

---

## 详细操作步骤

### Step 1：登录目标机

```bash
# 从本机或跳板机 ssh 到 dskna004
ssh dskna004
# 或者
ssh 172.16.12.210
```

### Step 2：进入源码目录

```bash
cd /home/smrc/lzh/3fs-main
```

### Step 3：创建 git-state.txt

```bash
# 确保 build 目录存在（如果之前 configure 过，这个目录已经有了）
mkdir -p build

# 创建 git-state.txt，内容为任意非空占位符
echo "PACKAGED_SOURCE" > build/git-state.txt

# 验证文件已创建
cat build/git-state.txt
# 应该输出：PACKAGED_SOURCE
```

### Step 4：创建 VersionInfo.cc

```bash
# 创建目标目录
mkdir -p build/src/common/utils

# 创建 VersionInfo.cc 文件
cat > build/src/common/utils/VersionInfo.cc <<'EOF'
#include "common/utils/VersionInfo.h"

const char* BUILD_GIT_HASH = "packaged";
const char* BUILD_GIT_HASH_FULL = "packaged";
const char* BUILD_DATE = "20261119";
const char* BUILD_TAG = "250228";
const char* BUILD_TAG_SEQ_NUM = "1";
const char* BUILD_ON_RELEASE_BRANCH = "false";
const char* BUILD_PIPELINE_ID = "999999";
EOF

# 验证文件已创建
cat build/src/common/utils/VersionInfo.cc
```

### Step 5：确认文件权限

```bash
# 确保文件可读
chmod 644 build/git-state.txt
chmod 644 build/src/common/utils/VersionInfo.cc

# 检查文件状态
ls -la build/git-state.txt build/src/common/utils/VersionInfo.cc
```

### Step 6：重新构建

```bash
# 进入 build 目录
cd build

# 重新执行构建，日志输出到文件
cmake --build . -j 32 2>&1 | tee build-$(hostname -s)-$(date +%Y%m%d-%H%M%S).log

# 获取退出码（重要！）
echo "退出码：${PIPESTATUS[0]}"
```

### Step 7：判定构建结果

| 退出码 | 含义 | 下一步 |
|---|---|---|
| 0 | 构建成功 | 继续部署流程 |
| 1-127 | 构建失败（编译/链接错误） | 查看日志中的 `error:` 行，发回日志分析 |
| 128+ | 系统级错误（磁盘满、内存不足等） | 检查 `df -h`、`free -h` |

---

## 验证方法

### 验证 1：检查构建进度

```bash
# 查看日志末尾
tail -30 build/build-*.log

# 查看进度行
grep -oE '^\[ *[0-9]+%\]' build/build-*.log | tail -5

# 如果看到 [100%] Built target all，说明成功了
```

### 验证 2：检查是否还有 git 错误

```bash
# 如果日志里还有 "not a git repository"，说明文件没放对位置
grep -n "not a git" build/build-*.log

# 如果还有 "LIST GET given empty list"，说明 git-state.txt 内容为空
grep -n "LIST GET" build/build-*.log
```

### 验证 3：检查生成的二进制

```bash
# 如果构建成功，检查生成的 hf3fs 二进制
ls -la build/bin/hf3fs 2>/dev/null || ls -la build/src/bin/hf3fs 2>/dev/null

# 尝试运行（可能需要 LD_LIBRARY_PATH）
./build/bin/hf3fs --version 2>/dev/null || echo "二进制未生成或需要库路径"
```

---

## 常见问题

### Q1: `mkdir: cannot create directory 'build': Permission denied`

**原因**：当前用户没有写权限。

**解决**：
```bash
# 检查目录所有者
ls -ld /home/smrc/lzh/3fs-main

# 如果是 root 或其他用户，用 sudo 或切换用户
sudo chown -R $USER:$USER /home/smrc/lzh/3fs-main
# 或者
su - smrc
```

### Q2: `cmake: command not found`

**原因**：cmake 未安装或不在 PATH 中。

**解决**：
```bash
# 检查 cmake 位置
which cmake || echo "cmake not found"

# 如果已安装但不在 PATH
/usr/bin/cmake --build build -j 32 2>&1 | tee build.log
```

### Q3: 构建到 50%+ 后失败，日志里有 `error:`

**原因**：GitVersion 问题已解决，但遇到真正的编译错误（缺依赖、代码问题等）。

**解决**：
```bash
# 提取错误摘要
grep -nE 'error:|fatal error|FAILED' build/build-*.log | head -20

# 发回错误日志分析
```

### Q4: 构建成功后运行 hf3fs 报 `libxxx.so: cannot open shared object file`

**原因**：运行时库不在 LD_LIBRARY_PATH 中。

**解决**：
```bash
# 设置库路径（根据实际安装位置调整）
export LD_LIBRARY_PATH=/home/smrc/lzh/3fs-main/build/lib:$LD_LIBRARY_PATH

# 或者用 ldconfig 注册
sudo ldconfig /home/smrc/lzh/3fs-main/build/lib
```

---

## 附录：VersionInfo.cc 字段说明

| 字段 | 用途 | 占位值 |
|---|---|---|
| `BUILD_GIT_HASH` |  abbreviated commit hash（8 位） | `packaged` |
| `BUILD_GIT_HASH_FULL` | full commit hash（40 位） | `packaged` |
| `BUILD_DATE` | 构建日期（YYYYMMDD） | `20261119` |
| `BUILD_TAG` | git tag | `250228` |
| `BUILD_TAG_SEQ_NUM` | tag 后的序号 | `1` |
| `BUILD_ON_RELEASE_BRANCH` | 是否在 release 分支 | `false` |
| `BUILD_PIPELINE_ID` | CI 流水线 ID | `999999` |

这些字段只影响版本信息输出，不影响 3fs 功能。如果需要准确的版本信息，请在有 git 仓库的机器上打包源码。

---

## 文件清单

修复完成后，build 目录下会多出这两个文件：

```
build/
├── git-state.txt                          # 1 行，commit hash 占位符
└── src/common/utils/
    └── VersionInfo.cc                     # C++ 源文件，版本信息常量
```

构建成功后，`VersionInfo.cc` 会被编译进 `libversion-info.a` 或主二进制中。

---

## 回滚方法

如果修复后遇到其他问题，想回到原始状态：

```bash
cd /home/smrc/lzh/3fs-main

# 删除手动创建的文件
rm -f build/git-state.txt
rm -f build/src/common/utils/VersionInfo.cc

# 如果需要重新 configure（比如换了编译器）
rm -rf build
cmake -S . -B build [你的 configure 参数]
```

---

## 联系支持

如果按本指南操作后仍无法解决，请提供以下信息：

1. `build/git-state.txt` 内容：`cat build/git-state.txt`
2. `build/src/common/utils/VersionInfo.cc` 内容：`cat build/src/common/utils/VersionInfo.cc`
3. 构建日志末尾 50 行：`tail -50 build/build-*.log`
4. 退出码：`echo $?`（在构建命令后立即执行）
