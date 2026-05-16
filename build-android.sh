#!/usr/bin/env bash
#
# 交叉编译 curl for Android (静态库 + 动态库)
# 使用 NDK 自带的 CMake toolchain，不依赖外部 SSL 库（纯 HTTP 版本）
# 如需 HTTPS 支持，请取消下方 OpenSSL / mbedTLS 相关注释并指定路径
#
set -euo pipefail

# ── 配置 ─────────────────────────────────────────────
ANDROID_NDK="${ANDROID_NDK:-$HOME/Library/Android/sdk/ndk/27.3.13750724}"
TOOLCHAIN="$ANDROID_NDK/build/cmake/android.toolchain.cmake"
ANDROID_PLATFORM=24          # 最低 API 级别
SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${BUILD_DIR:-$SOURCE_DIR/build}"
INSTALL_PREFIX="${OUT_DIR:-$SOURCE_DIR/android-output}"

# 构建控制：
# - CLEAN=1            先清理 BUILD_ROOT 和 INSTALL_PREFIX
# - BUILD_STATIC=0/1   是否构建全静态二进制/静态 libcurl
# - BUILD_SHARED=0/1   是否构建动态 libcurl + 动态链接 curl
# - DO_INSTALL=0/1     是否执行 cmake --install（不安装则只在 build 目录有产物）
# - STRIP_OUTPUTS=0/1  安装后是否自动 strip curl
CLEAN="${CLEAN:-0}"
BUILD_STATIC="${BUILD_STATIC:-1}"
BUILD_SHARED="${BUILD_SHARED:-1}"
DO_INSTALL="${DO_INSTALL:-1}"
STRIP_OUTPUTS="${STRIP_OUTPUTS:-1}"

# 要编译的 ABI 列表（可按需裁剪）
# 可用环境变量覆盖：ANDROID_ABIS="arm64-v8a x86_64"
if [[ -n "${ANDROID_ABIS:-}" ]]; then
  IFS=' ' read -r -a ABIS <<< "${ANDROID_ABIS}"
else
  ABIS=("arm64-v8a" "armeabi-v7a" "x86_64" "x86")
fi

# 全静态 curl 在 Android 上常见 DNS 解析不可用（依赖 netd/binder）。
# 启用 c-ares 可让 curl 使用其 DNS 解析器，并支持运行时传入 --dns-servers。
# 关闭：CURL_STATIC_USE_ARES=0
CURL_STATIC_USE_ARES="${CURL_STATIC_USE_ARES:-1}"

# （可选）为静态 + c-ares 变体写入默认 DNS servers（编译期）。
# 这样运行时不传 --dns-servers 也能解析域名。
# 示例：CURL_ARES_DEFAULT_SERVERS="223.5.5.5,223.6.6.6"
CURL_ARES_DEFAULT_SERVERS="${CURL_ARES_DEFAULT_SERVERS:-}"

# 为 c-ares 打开 DEBUGF 日志。
# 启用：CARES_DEBUGBUILD=1
CARES_DEBUGBUILD="${CARES_DEBUGBUILD:-0}"

# c-ares 源码目录（可选）。未指定时：优先使用 ../c-ares；否则会在 build/deps 下 clone。
CARES_SRC="${CARES_SRC:-}"

if [[ "$CLEAN" == "1" ]]; then
  echo "Cleaning: $BUILD_ROOT and $INSTALL_PREFIX"
  rm -rf "$BUILD_ROOT" "$INSTALL_PREFIX"
fi

arch_dir_for_abi() {
  local abi="$1"
  case "$abi" in
    arm64-v8a)   echo "aarch64-linux-android" ;;
    armeabi-v7a) echo "arm-linux-androideabi" ;;
    x86_64)      echo "x86_64-linux-android" ;;
    x86)         echo "i686-linux-android" ;;
    *)           echo "" ;;
  esac
}

patch_cares_android_sysconfig() {
  local cares_src="$1"
  local sysconfig_file="$cares_src/src/lib/ares_sysconfig.c"

  if [[ ! -f "$sysconfig_file" ]]; then
    echo "c-ares: missing sysconfig source: $sysconfig_file" >&2
    return 1
  fi

  if perl -0ne 'exit(index($_, "#elif defined(ANDROID) || defined(__ANDROID__)\n  status = ares_init_sysconfig_files(channel, &sysconfig, ARES_TRUE);") >= 0 ? 0 : 1)' "$sysconfig_file"; then
    echo "c-ares: android sysconfig already patched for resolv.conf"
    return 0
  fi

  if ! perl -0ne 'exit(index($_, "#elif defined(ANDROID) || defined(__ANDROID__)\n  status = ares_init_sysconfig_android(channel, &sysconfig);") >= 0 ? 0 : 1)' "$sysconfig_file"; then
    echo "c-ares: unexpected android sysconfig branch in $sysconfig_file" >&2
    return 1
  fi

  perl -0pi -e 's@#elif defined\(ANDROID\) \|\| defined\(__ANDROID__\)\n  status = ares_init_sysconfig_android\(channel, &sysconfig\);@#elif defined(ANDROID) || defined(__ANDROID__)\n  status = ares_init_sysconfig_files(channel, &sysconfig, ARES_TRUE);@' "$sysconfig_file"

  echo "c-ares: patched android sysconfig to use resolv.conf files"
}

resolve_cares_src() {
  if [[ -n "$CARES_SRC" ]]; then
    echo "$CARES_SRC"
  elif [[ -f "$SOURCE_DIR/../c-ares/CMakeLists.txt" ]]; then
    echo "$SOURCE_DIR/../c-ares"
  elif [[ -f "$BUILD_ROOT/deps/c-ares-src/CMakeLists.txt" ]]; then
    echo "$BUILD_ROOT/deps/c-ares-src"
  else
    mkdir -p "$BUILD_ROOT/deps"
    echo "c-ares: cloning into $BUILD_ROOT/deps/c-ares-src" >&2
    git clone --depth 1 https://github.com/c-ares/c-ares.git "$BUILD_ROOT/deps/c-ares-src" >&2
    echo "$BUILD_ROOT/deps/c-ares-src"
  fi
}

ensure_cares_static() {
  local abi="$1"
  local cares_root="$BUILD_ROOT/deps/c-ares/$abi"
  local cares_build="$cares_root/build"
  local cares_install="$cares_root/install"
  local cares_patch_stamp="$cares_root/.android_sysconfig_files_patch"
  local cares_c_flags="${CARES_C_FLAGS:-}"

  local cares_src
  cares_src="$(resolve_cares_src)"

  if [[ ! -f "$cares_src/CMakeLists.txt" ]]; then
    echo "c-ares: invalid CARES_SRC: $cares_src" >&2
    return 1
  fi

  patch_cares_android_sysconfig "$cares_src"

  if [[ -f "$cares_install/lib/libcares.a" && -f "$cares_install/include/ares.h" && -f "$cares_patch_stamp" ]]; then
    echo "c-ares: reuse $abi (${cares_install})"
    return 0
  fi

  rm -rf "$cares_build" "$cares_install" "$cares_patch_stamp"
  mkdir -p "$cares_root"

  if [[ "$CARES_DEBUGBUILD" == "1" ]]; then
    if [[ -n "$cares_c_flags" ]]; then
      cares_c_flags="$cares_c_flags -DDEBUGBUILD"
    else
      cares_c_flags="-DDEBUGBUILD"
    fi
  fi

  cmake -S "$cares_src" -B "$cares_build" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-${ANDROID_PLATFORM}" \
    -DCMAKE_INSTALL_PREFIX="$cares_install" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$cares_c_flags" \
    -DCARES_STATIC=ON \
    -DCARES_SHARED=OFF \
    -DCARES_BUILD_TOOLS=OFF \
    -DCARES_BUILD_TESTS=OFF

  cmake --build "$cares_build" -j "$(sysctl -n hw.ncpu)"
  cmake --install "$cares_build"
  : > "$cares_patch_stamp"
}

# ── 函数 ─────────────────────────────────────────────
build_one() {
  local abi="$1"
  local lib_type="$2"   # STATIC 或 SHARED
  local variant
  variant="$(echo "$lib_type" | tr '[:upper:]' '[:lower:]')"
  local build_dir="$BUILD_ROOT/$abi/$variant"
  local prefix="$INSTALL_PREFIX/$abi/$variant"

  echo "========================================"
  echo "  Building: $abi  ($lib_type)"
  echo "========================================"

  local extra_flags=()
  local threaded_resolver=ON
  if [[ "$lib_type" == "STATIC" ]]; then
    local shared=OFF static=ON static_curl=ON
    threaded_resolver=OFF
    # ABI → sysroot 子目录映射
    local arch_dir
    arch_dir="$(arch_dir_for_abi "$abi")"
    if [[ -z "$arch_dir" ]]; then
      echo "Unsupported ABI: $abi" >&2
      return 1
    fi
    local sysroot="$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot"
    # 全静态链接：强制 .a、-static、显式指向 static zlib
    extra_flags+=(
      -DCMAKE_FIND_LIBRARY_SUFFIXES=".a"
      -DCMAKE_EXE_LINKER_FLAGS="-static"
      -DZLIB_LIBRARY="$sysroot/usr/lib/$arch_dir/libz.a"
      -DZLIB_INCLUDE_DIR="$sysroot/usr/include"
    )

    if [[ "${CURL_STATIC_USE_ARES}" != "0" ]]; then
      ensure_cares_static "$abi"
      local cares_install="$BUILD_ROOT/deps/c-ares/$abi/install"
      extra_flags+=(
        -DENABLE_ARES=ON
        -DCARES_USE_STATIC_LIBS=ON
        -DCARES_INCLUDE_DIR="$cares_install/include"
        -DCARES_LIBRARY="$cares_install/lib/libcares.a"
      )

      if [[ -n "${CURL_ARES_DEFAULT_SERVERS}" ]]; then
        extra_flags+=(
          -DCMAKE_C_FLAGS=-DCURL_DEFAULT_DNS_SERVERS=\\\"${CURL_ARES_DEFAULT_SERVERS}\\\"
        )
      fi
    else
      extra_flags+=(
        -DENABLE_ARES=OFF
      )
    fi
  else
    local shared=ON static=OFF static_curl=OFF
    threaded_resolver=ON
    extra_flags+=(
      -DENABLE_ARES=OFF
    )
  fi

  cmake -S "$SOURCE_DIR" -B "$build_dir" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$abi" \
    -DANDROID_PLATFORM="android-${ANDROID_PLATFORM}" \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=$shared \
    -DBUILD_STATIC_LIBS=$static \
    -DBUILD_STATIC_CURL=$static_curl \
    -DBUILD_CURL_EXE=ON \
    -DCURL_ENABLE_SSL=OFF \
    -DENABLE_THREADED_RESOLVER=$threaded_resolver \
    -DCURL_DISABLE_LDAP=ON \
    -DCURL_DISABLE_LDAPS=ON \
    -DCURL_USE_LIBPSL=OFF \
    -DCURL_USE_PKGCONFIG=OFF \
    "${extra_flags[@]}"

  cmake --build "$build_dir" -j "$(sysctl -n hw.ncpu)"
  if [[ "$DO_INSTALL" == "1" ]]; then
    cmake --install "$build_dir"
    if [[ "$STRIP_OUTPUTS" == "1" && -f "$prefix/bin/curl" ]]; then
      "$ANDROID_NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip" --strip-all "$prefix/bin/curl"
    fi
  fi
}

# ── 主流程 ─────────────────────────────────────────────
echo "NDK:       $ANDROID_NDK"
echo "Toolchain: $TOOLCHAIN"
echo "Platform:  android-${ANDROID_PLATFORM}"
echo "ABIs:      ${ABIS[*]}"
echo ""

for abi in "${ABIS[@]}"; do
  if [[ "$BUILD_STATIC" == "1" ]]; then
    build_one "$abi" "STATIC"
  fi
  if [[ "$BUILD_SHARED" == "1" ]]; then
    build_one "$abi" "SHARED"
  fi
done

echo ""
echo "========================================="
echo "  构建完成！产物位于: $INSTALL_PREFIX"
echo "========================================="
echo ""
echo "目录结构："
if [[ "$DO_INSTALL" == "1" ]]; then
  find "$INSTALL_PREFIX" -maxdepth 4 -type f \( -name '*.a' -o -name '*.so' -o -name 'curl' \) | sort
else
  echo "DO_INSTALL=0：未安装到 $INSTALL_PREFIX，产物在 $BUILD_ROOT 下的各 build 目录里。"
fi
