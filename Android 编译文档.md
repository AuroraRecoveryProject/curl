# curl Android 交叉编译文档

## 环境信息

| 项目 | 值 |
|------|-----|
| NDK 版本 | 27.3.13750724 |
| NDK 路径 | `/Users/Laurie/Library/Android/sdk/ndk/27.3.13750724` |
| 最低 API | 24 (Android 7.0) |
| 构建系统 | CMake + NDK Toolchain |
| 主机架构 | darwin-x86_64 (macOS) |
| curl 版本 | 8.20.0-DEV |

## 快速开始

### 最简用法（只编 arm64-v8a 全静态版）

```bash
ANDROID_ABIS="arm64-v8a" BUILD_SHARED=0 bash build-android.sh
```

### 全部 ABI + 静态/动态都编

```bash
bash build-android.sh
```

### 全静态（带默认 DNS）+ 每次清理旧产物

```bash
ANDROID_ABIS="arm64-v8a" BUILD_SHARED=0 CLEAN=1 \
  CURL_ARES_DEFAULT_SERVERS="223.5.5.5" bash build-android.sh
```

## 所有环境变量开关

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ANDROID_ABIS` | `arm64-v8a armeabi-v7a x86_64 x86` | 空格分隔的 ABI 列表 |
| `ANDROID_NDK` | `$HOME/Library/Android/sdk/ndk/27.3.13750724` | NDK 根目录，可覆盖默认路径 |
| `BUILD_STATIC` | `1` | 是否构建全静态版 |
| `BUILD_SHARED` | `1` | 是否构建动态版 |
| `CLEAN` | `0` | 为 1 时先清空 build 和 output 目录 |
| `DO_INSTALL` | `1` | 为 0 时不执行 cmake --install，产物留在 build 目录 |
| `CURL_STATIC_USE_ARES` | `1` | 静态版是否启用 c-ares DNS 解析 |
| `CURL_ARES_DEFAULT_SERVERS` | 空 | 编译期写死默认 DNS 服务器（如 `223.5.5.5`） |
| `CARES_DEBUGBUILD` | `0` | 为 1 时给 c-ares 追加 `-DDEBUGBUILD` 打开 DEBUGF |
| `CARES_C_FLAGS` | 空 | 额外传给 c-ares 的 `CMAKE_C_FLAGS` |
| `CARES_SRC` | 空 | c-ares 源码目录（空则自动 clone） |
| `BUILD_DIR` | `build` | CMake 构建目录 |
| `OUT_DIR` | `android-output` | 最终产物安装目录 |

## 目录结构

```
build/                          ← CMake 构建中间文件
├── deps/c-ares/                ← c-ares 编译缓存
│   ├── arm64-v8a/
│   ├── armeabi-v7a/
│   ├── x86_64/
│   └── x86/
├── arm64-v8a/
│   ├── static/                 ← 静态版 CMake 构建树
│   └── shared/                 ← 动态版 CMake 构建树
└── ...

android-output/                 ← 最终产物
├── arm64-v8a/
│   ├── static/
│   │   ├── bin/curl            ← 全静态 curl 可执行文件
│   │   └── lib/libcurl.a       ← 静态库
│   └── shared/
│       ├── bin/curl            ← 动态链接 curl 可执行文件
│       └── lib/libcurl.so      ← 动态库
└── ...
```

## CMake 构建参数说明

### 通用参数

| 参数 | 值 | 说明 |
|------|-----|------|
| `-DCMAKE_TOOLCHAIN_FILE` | NDK android.toolchain.cmake | Android 交叉编译工具链 |
| `-DANDROID_ABI` | arm64-v8a 等 | 目标 ABI |
| `-DANDROID_PLATFORM` | android-24 | 最低 API 级别 |
| `-DCMAKE_BUILD_TYPE` | Release | 发布版优化 |
| `-DBUILD_CURL_EXE` | ON | 生成 curl 可执行文件 |
| `-DCURL_ENABLE_SSL` | OFF | 不启用 SSL（纯 HTTP） |
| `-DCURL_DISABLE_LDAP` | ON | 禁用 LDAP |
| `-DCURL_DISABLE_LDAPS` | ON | 禁用 LDAPS |
| `-DCURL_USE_LIBPSL` | OFF | 禁用 libpsl |
| `-DCURL_USE_PKGCONFIG` | OFF | 禁用 pkg-config 查找 |

### 静态版额外参数

| 参数 | 说明 |
|------|------|
| `-DBUILD_SHARED_LIBS=OFF` | 不编 .so |
| `-DBUILD_STATIC_LIBS=ON` | 编 .a |
| `-DBUILD_STATIC_CURL=ON` | 静态链接 curl 自身 |
| `-DCMAKE_FIND_LIBRARY_SUFFIXES=".a"` | 强制 CMake 只找 .a |
| `-DCMAKE_EXE_LINKER_FLAGS="-static"` | 全静态链接 |
| `-DZLIB_LIBRARY=<sysroot>/libz.a` | 显式指定静态 zlib |
| `-DZLIB_INCLUDE_DIR=<sysroot>/include` | zlib 头文件路径 |
| `-DENABLE_THREADED_RESOLVER=OFF` | 关线程 DNS（冲突） |
| `-DENABLE_ARES=ON` | 当 `CURL_STATIC_USE_ARES=1` 时启用 c-ares |
| `-DCARES_USE_STATIC_LIBS=ON` | c-ares 静态链接 |
| `-DCARES_INCLUDE_DIR=<path>/include` | c-ares 头文件 |
| `-DCARES_LIBRARY=<path>/libcares.a` | c-ares 静态库 |
| `-DCMAKE_C_FLAGS=-DCURL_DEFAULT_DNS_SERVERS="..."` | 当设置 `CURL_ARES_DEFAULT_SERVERS` 时写入默认 DNS |

补充说明：

1. 静态版只有在 `CURL_STATIC_USE_ARES=1` 时才会启用 c-ares。
2. 如果 `CURL_STATIC_USE_ARES=0`，脚本会显式传 `-DENABLE_ARES=OFF`。
3. 动态版当前固定传 `-DENABLE_ARES=OFF`，不会启用 c-ares。

### NDK sysroot 中 zlib 的 ABI 路径映射

| ABI | zlib 路径 |
|-----|-----------|
| arm64-v8a | `.../sysroot/usr/lib/aarch64-linux-android/libz.a` |
| armeabi-v7a | `.../sysroot/usr/lib/arm-linux-androideabi/libz.a` |
| x86_64 | `.../sysroot/usr/lib/x86_64-linux-android/libz.a` |
| x86 | `.../sysroot/usr/lib/i686-linux-android/libz.a` |

## 关于全静态 curl 与 DNS 解析

### 问题根因

Android 的 DNS 解析走 `getaddrinfo()` → `netd` binder 服务。全静态链接 (`-static`) 的二进制无法使用这套机制，c-ares 是异步 DNS 解析库，curl 启用它后不再依赖系统 DNS，而是通过 c-ares 自己的 DNS 协议实现进行域名解析。

### 解决方案

1. **运行时指定 DNS**：`curl --dns-servers 223.5.5.5 http://example.com/`
2. **编译期写死默认 DNS**：构建时设 `CURL_ARES_DEFAULT_SERVERS="223.5.5.5"`
3. **设备端创建 resolv.conf**：`echo "nameserver 223.5.5.5" > /etc/resolv.conf`

### 源码改动

在 [lib/asyn-ares.c](lib/asyn-ares.c#L655) 中，当用户未通过 `CURLOPT_DNS_SERVERS`（即 `--dns-servers`）指定 DNS 时，回退到编译期宏 `CURL_DEFAULT_DNS_SERVERS` 定义的默认值。

核心逻辑：

```c
// lib/asyn-ares.c 第 655-658 行
#ifdef CURL_DEFAULT_DNS_SERVERS
      if(!servers)
        servers = CURL_DEFAULT_DNS_SERVERS;
#endif
```

### 验证 DNS 可用

```bash
# 推送全静态版到设备
adb push android-output/arm64-v8a/static/bin/curl /tmp/curl
adb shell chmod +x /tmp/curl
adb shell '/tmp/curl http://www.baidu.com/ -v'

# 写入 resolv.conf（如果设备允许）
adb shell 'echo "nameserver 223.5.5.5" > /etc/resolv.conf'

# 带 --dns-servers 测试
adb shell '/tmp/curl --dns-servers 223.5.5.5 http://www.baidu.com/ -o /dev/null -sS -v 2>&1 | head -80'
```

当前验证结论：

1. 当前静态版 curl 已包含 c-ares，因此 `--dns-servers` 可正常使用。
2. 在当前链路下，显式指定 DNS server 后，请求可以正常进行。
3. 不显式指定 DNS 时，是否可解析仍取决于 c-ares 自动发现链路是否拿到 nameserver。

## 编译产物验证

```bash
# 确认是全静态链接
file android-output/arm64-v8a/static/bin/curl
# 输出应包含: statically linked

# 确认无动态节
$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf -d \
  android-output/arm64-v8a/static/bin/curl
# 输出应为空
```

## c-ares 自动构建流程

脚本内置的 `ensure_cares_static()` 函数处理：

1. **优先复用**：检查 `build/deps/c-ares/<abi>/install/` 下已有产物
2. **显式源码目录**：若设置了 `CARES_SRC`，直接使用该目录
3. **本地源码兜底**：未设置 `CARES_SRC` 时，优先检查 `../c-ares/`
4. **构建缓存源码兜底**：若 `build/deps/c-ares-src/` 已存在，则直接复用
5. **自动 clone**：都没有时自动 `git clone --depth 1` 到 `build/deps/c-ares-src/`
6. **调试日志开关**：若 `CARES_DEBUGBUILD=1`，会在 c-ares 的 `CMAKE_C_FLAGS` 中追加 `-DDEBUGBUILD`

c-ares CMake 参数：

| 参数 | 值 | 说明 |
|------|-----|------|
| `CARES_STATIC` | ON | 构建静态库 |
| `CARES_SHARED` | OFF | 不构建动态库 |
| `CARES_BUILD_TOOLS` | OFF | 不编译工具 |
| `CARES_BUILD_TESTS` | OFF | 不编译测试 |

如果 `DO_INSTALL=0`，脚本不会执行 `cmake --install`，最终产物只会留在 `build/` 下各自的构建目录里，而不会安装到 `android-output/`。

## 构建时间线

1. 初始需求：Android 交叉编译 curl（静态+动态）
2. 发现问题：静态链接的 curl 二进制仍动态依赖 libcurl.so → 加 `-static` + 显式指定静态 zlib
3. 安装冲突：STATIC/SHARED 共用同一安装路径互相覆盖 → 分目录安装 `{abi}/{static,shared}/`
4. DNS 不可用：全静态 curl 在 Android 上无法解析域名 → 集成 c-ares DNS 解析库
5. 自动 DNS：每次运行需手动 `--dns-servers` 不方便 → 源码加 `CURL_DEFAULT_DNS_SERVERS` 编译期宏

## c-ares 作用

不包含 cares 的输出

```bash
➜  curl git:(master) ✗ adb shell '/tmp/curl --dns-servers 223.5.5.5 http://www.baidu.com/ -v'
curl: option --dns-servers: the installed libcurl version does not support this
curl: try 'curl --help' or 'curl --manual' for more information
```

没有 --dns-servers 支持，无法指定 DNS server，且 Android 上全静态链接的二进制无法使用系统 DNS 解析机制，因此无法解析域名。

c-ares 在当前构建中的作用是接管 curl 的异步 DNS 解析。

当前已经验证：

1. 启用 c-ares 的静态版 curl 支持 `--dns-servers`。
2. 运行命令 `adb shell '/tmp/curl --dns-servers 223.5.5.5 http://www.baidu.com/ -o /dev/null -sS -v 2>&1 | head -80'` 可以正常工作。
3. 这说明当 c-ares 能拿到显式指定的 DNS server 时，当前二进制的 HTTP 请求链路是正常的。
4. 当前剩余问题不在 curl 主体功能，而在“未显式指定 DNS 时，Android 自动发现 nameserver 的链路失败”。
5. 这一行为与当前脚本一致：静态版默认启用 c-ares，动态版默认不启用 c-ares。
