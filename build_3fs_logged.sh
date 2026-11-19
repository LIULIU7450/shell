#!/usr/bin/env bash
# ============================================================================
# build_3fs_logged.sh —— 带完整日志与诊断包的 3fs 构建包装脚本
#
# 解决的问题：
#   1. `cmake --build build -j 32` 的输出一屏就滚没了，报错抓不到；
#   2. 2>&1 | tee 之后 $? 变成 tee 的状态，构建失败也看不出来；
#   3. 只重定向到文件又看不到进度，长时间构建会以为卡死；
#   4. 现场要来回问"你 cmake 什么版本""装没装 libdwarf"，一次打包省掉往返。
#
# 产出（默认放在 <源码目录>/build-logs/）：
#   build-<host>-<时间戳>.log      完整构建日志（含 stderr）
#   diag.txt                       环境与配置快照（cmake/编译器/rust/依赖/子模块）
#   CMakeCache.txt                 build 目录里的缓存副本
#   3fs-build-diag-<host>-<时间戳>.tgz   上面三个的打包，直接发回来
#
# 用法：
#   ./build_3fs_logged.sh                     # 当前目录是 3fs 源码根，-j $(nproc)
#   ./build_3fs_logged.sh /opt/src/3fs -j 32
#   ./build_3fs_logged.sh -k -j 32            # -k: 一次收集全部错误，不提前中断
#   ./build_3fs_logged.sh -n                  # --dry-run: 只打印将要执行的命令
# ============================================================================

set -uo pipefail          # 注意：故意不开 -e，构建失败要自己接住退出码

PROG=$(basename "$0")

SRC_DIR="."
BUILD_DIR=""
JOBS=""
KEEP_GOING=0
OUT_DIR=""
DRY_RUN=0

usage() {
  cat <<EOF
用法: $PROG [选项] [源码目录]

  -b, --build-dir DIR   指定 build 目录（默认 <源码目录>/build）
  -j, --jobs N          并行度（默认 \$(nproc)）
  -k, --keep-going      失败后继续编译，尽量一次收集全部错误（make/ninja 的 -k 0）
  -o, --out-dir DIR     日志与诊断包输出目录（默认 <源码目录>/build-logs）
  -n, --dry-run         只打印将要执行的命令，不实际构建
  -h, --help            显示本帮助

示例:
  $PROG                      # 在 3fs 源码根直接跑
  $PROG /opt/src/3fs -j 32   # 指定源码目录与并行度
  $PROG -k -j 32             # 一次抓全部错误
EOF
}

die() { echo "$PROG: $*" >&2; exit 2; }

# 取选项值时检查有没有下一个参数：`-j` 后面什么也不跟时给出人话错误，
# 而不是 bash 的 "parameter null or not set"。
need_val() {
  [[ $# -ge 2 ]] || die "选项 $1 需要一个参数（-h 看用法）"
}

# 目录必须存在，返回绝对路径；不存在时返回非 0（不能内部 exit：
# 命令替换里的 exit 只结束子 shell，外层脚本会带着空变量继续往下跑）
resolve_dir() {
  local p=$1
  [[ -d $p ]] || return 1
  ( cd "$p" && pwd )
}

# 只做绝对化，不要求目录存在（用于 build 目录：目录不在时要走"还没 configure"的提示，
# 而不是抛一句"目录不存在"就退出）
abs_dir() {
  local p=$1
  if [[ -d $p ]]; then
    ( cd "$p" && pwd )
  else
    case $p in
      /*) printf '%s\n' "$p" ;;
      *)  printf '%s\n' "$PWD/$p" ;;
    esac
  fi
}

# ------------------------------------------------------------------ 参数解析
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b|--build-dir) need_val "$@"; BUILD_DIR=$2; shift 2 ;;
    -j|--jobs)      need_val "$@"; JOBS=$2;      shift 2 ;;
    -o|--out-dir)   need_val "$@"; OUT_DIR=$2;   shift 2 ;;
    -k|--keep-going) KEEP_GOING=1; shift ;;
    -n|--dry-run)   DRY_RUN=1;     shift ;;
    -h|--help)      usage; exit 0 ;;
    --)             shift; break ;;
    -*)             usage >&2; die "未知选项: $1" ;;
    *)              SRC_DIR=$1; shift ;;
  esac
done

# ------------------------------------------------------------------ 路径与默认值
# 先算到临时变量：直接 SRC_DIR=$(...) 失败时 SRC_DIR 已被清空，报错会丢掉路径
SRC_ABS=$(resolve_dir "$SRC_DIR") || die "源码目录 不存在: $SRC_DIR"
SRC_DIR=$SRC_ABS

[[ -n $BUILD_DIR ]] || BUILD_DIR="$SRC_DIR/build"
BUILD_DIR=$(abs_dir "$BUILD_DIR")

[[ -n $JOBS ]] || JOBS=$(nproc 2>/dev/null || echo 8)
[[ $JOBS =~ ^[0-9]+$ ]] || die "-j 需要一个正整数，收到: $JOBS"

[[ -n $OUT_DIR ]] || OUT_DIR="$SRC_DIR/build-logs"
mkdir -p "$OUT_DIR" || die "无法创建输出目录: $OUT_DIR"
OUT_DIR=$(resolve_dir "$OUT_DIR") || die "输出目录不可用: $OUT_DIR"

HOST=$(hostname -s 2>/dev/null || hostname)
TS=$(date +%Y%m%d-%H%M%S)
LOG="$OUT_DIR/build-$HOST-$TS.log"
DIAG="$OUT_DIR/diag.txt"
PKG="$OUT_DIR/3fs-build-diag-$HOST-$TS.tgz"

# 没 configure 过就直说，别让 cmake --build 抛一句看不懂的 "could not load cache"
if [[ ! -f $BUILD_DIR/CMakeCache.txt ]]; then
  cat >&2 <<EOF
$PROG: $BUILD_DIR 里没有 CMakeCache.txt，说明还没 configure。

先在源码目录执行（-DSHUFFLE_METHOD 必带，缺失会直接构建失败）：
  cmake -S "$SRC_DIR" -B "$BUILD_DIR" \\
    -DCMAKE_BUILD_TYPE=RelWithDebInfo -DSHUFFLE_METHOD=g++11
然后再跑本脚本。
EOF
  exit 2
fi

# ------------------------------------------------------------------ 组装命令
BUILD_ARGS=()
if (( KEEP_GOING )); then
  # 对 Makefiles 与 Ninja 都成立：不限制失败次数，编译到不能编为止
  BUILD_ARGS+=(-- -k 0)
fi

CMD=(cmake --build "$BUILD_DIR" -j "$JOBS" "${BUILD_ARGS[@]}")

if (( DRY_RUN )); then
  echo "源码目录 : $SRC_DIR"
  echo "build    : $BUILD_DIR"
  echo "日志     : $LOG"
  echo "将执行   :"
  printf '  '; printf '%q ' "${CMD[@]}"; printf '\n'
  echo "  # 输出经 tee 写入上面的日志，屏幕只保留非进度行"
  exit 0
fi

# ------------------------------------------------------------------ 执行构建
{
  echo "# 命令   : ${CMD[*]}"
  echo "# 主机   : $HOST"
  echo "# 时间   : $(date -Is)"
  echo "# 源码   : $SRC_DIR"
  echo "# build  : $BUILD_DIR"
  echo "# 并行度 : $JOBS    keep-going: $KEEP_GOING"
  echo
} > "$LOG"

echo "==> 构建开始: ${CMD[*]}"
echo "==> 完整日志: $LOG"
echo "==> 进度行已从屏幕过滤；想看实时进度，另开终端执行: tail -f '$LOG'"
echo

# 关键点：最后一段用 { grep ... || true; } 包住。
# grep 在"一行都没匹配到"时返回 1，若不兜住，pipefail 会把整条管道判成失败，
# 构建成功也会误报；兜住之后 PIPESTATUS[0] 仍是 cmake 的真实退出码。
"${CMD[@]}" 2>&1 | tee -a "$LOG" | { grep -vE '^\[ *[0-9]+%\]|^\[[0-9]+/[0-9]+\]' || true; }
RC=${PIPESTATUS[0]}

# ------------------------------------------------------------------ 诊断信息
collect_diag() {
  {
    echo "=== host ==="
    uname -a
    echo
    echo "=== os ==="
    # shellcheck disable=SC1091
    ( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" ) || echo unknown
    echo
    echo "=== cpu / mem ==="
    echo "nproc: $(nproc 2>/dev/null)"
    free -h 2>/dev/null | head -2
    echo
    echo "=== cmake ==="
    cmake --version 2>/dev/null | head -1
    echo
    echo "=== compilers ==="
    clang-14 --version 2>/dev/null | head -1 || echo "clang-14: not found"
    clang++-14 --version 2>/dev/null | head -1 || echo "clang++-14: not found"
    g++ --version 2>/dev/null | head -1 || echo "g++: not found"
    echo
    echo "=== rust (chunk_engine 需要) ==="
    rustc --version 2>/dev/null || echo "rustc: not found"
    cargo --version 2>/dev/null || echo "cargo: not found"
    echo
    echo "=== CMakeCache 关键项 ==="
    if [[ -f $BUILD_DIR/CMakeCache.txt ]]; then
      grep -E '^(CMAKE_GENERATOR|CMAKE_BUILD_TYPE|CMAKE_C_COMPILER|CMAKE_CXX_COMPILER|CMAKE_CXX_FLAGS|CMAKE_C_COMPILER_LAUNCHER|CMAKE_CXX_COMPILER_LAUNCHER):' \
        "$BUILD_DIR/CMakeCache.txt" 2>/dev/null || echo "(缓存里没有这些条目)"
    else
      echo "(找不到 $BUILD_DIR/CMakeCache.txt)"
    fi
    echo
    echo "--- SHUFFLE_METHOD ---"
    grep -i 'shuffle' "$BUILD_DIR/CMakeCache.txt" 2>/dev/null \
      || echo "未出现在 CMakeCache 中：configure 阶段可能就没传 -DSHUFFLE_METHOD"
    echo
    echo "=== git / submodules ==="
    git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null || echo "(不是 git 仓库)"
    git -C "$SRC_DIR" submodule status 2>/dev/null | head -20
    echo
    echo "=== 常见依赖头文件 ==="
    for f in \
      /usr/include/double-conversion/double-conversion.h \
      /usr/include/libdwarf/libdwarf.h \
      /usr/include/gtest/gtest.h \
      /usr/include/lz4.h \
      /usr/include/lzma.h \
      /usr/include/unwind.h \
      /usr/include/uv.h ; do
      if [[ -e $f ]]; then echo "OK   $f"; else echo "MISS $f"; fi
    done
    echo
    echo "=== 磁盘 ==="
    df -h "$BUILD_DIR" 2>/dev/null | tail -1
  } > "$DIAG" 2>&1
}

echo
echo "==> 收集诊断信息: $DIAG"
collect_diag

cp -f "$BUILD_DIR/CMakeCache.txt" "$OUT_DIR/CMakeCache.txt" 2>/dev/null || true

if [[ -f $BUILD_DIR/CMakeCache.txt ]]; then
  tar -czf "$PKG" -C "$OUT_DIR" "$(basename "$LOG")" diag.txt CMakeCache.txt 2>/dev/null \
    || tar -czf "$PKG" -C "$OUT_DIR" "$(basename "$LOG")" diag.txt 2>/dev/null \
    || echo "!! 打包失败，直接发日志与 diag.txt 即可" >&2
fi

# ------------------------------------------------------------------ 结果
LOGSIZE=$(du -h "$LOG" 2>/dev/null | cut -f1)

if (( RC == 0 )); then
  echo
  echo "[OK] 构建成功 —— 退出码 0，日志 $LOGSIZE"
  echo "     日志: $LOG"
  exit 0
fi

echo
echo "[FAIL] 构建失败 —— 退出码 $RC，日志 $LOGSIZE"
echo "     日志: $LOG"
echo
echo "==> 错误摘要（行号可直接用于 sed -n 'N-8,N+25p' 取上下文）"
grep -nE 'error:|fatal error|FAILED|undefined reference|cannot find|No such file|not found' "$LOG" \
  | head -40 || echo "     (没匹配到典型错误关键字，请直接看日志末尾 200 行)"

echo
echo "==> 日志末尾 30 行"
tail -30 "$LOG"

if [[ -f $PKG ]]; then
  echo
  echo "==> 诊断包: $PKG ($(du -h "$PKG" | cut -f1))"
  echo "    把 .tgz 发回来，或只发上面的『错误摘要』+ diag.txt，即可定位。"
fi
exit "$RC"
