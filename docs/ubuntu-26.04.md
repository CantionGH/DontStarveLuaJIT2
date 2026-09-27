# Ubuntu 26.04 专用服务器兼容性修复

## 现象和定位

安装脚本显示成功、服务器能加载 mod，但 `print(jit)` 报：

```text
variable 'jit' is not declared
```

“加载了 Lua mod”不等于“成功替换了游戏的 Lua VM”。本次针对 V3.0.0
在 Ubuntu 26.04 / glibc 2.43 的实际排查，发现了注入链路中的多个独立问题。
启动器和动态加载器的 stderr 应与游戏日志一起收集。

### 1. Frida Gum 共享库要求可执行栈

```text
libfrida-gum.so: cannot enable executable stack as shared object requires: Invalid argument
[ds-bootstrap] stub: failed to load real Injector
```

发行包中的 `libfrida-gum.so` 带有 `GNU_STACK RWE`。Linux 共享壳链接增加
`-Wl,-z,noexecstack`，重新编译后应为 `GNU_STACK RW`。这不禁止 LuaJIT
在独立的代码内存区域生成机器码。

Linux 链接选项同时计入共享壳缓存 fingerprint，避免复用修复前要求可执行栈的库。

Frida 源码构建同时支持 `CMAKE_BUILD_PARALLEL_LEVEL`，未指定时最多使用
两个编译任务，避免内存较小的构建机一次启动过多编译任务。

### 2. POSIX chdir 启动钩子失败

```text
[ds-bootstrap] loaded Injector: .../libInjector.so
[ds-bootstrap] stub: HookStartupEntry returned false
```

在测试环境中，对 `chdir` 调用 `gum_interceptor_replace_fast` 返回失败，
普通 `gum_interceptor_replace` 则成功。POSIX 启动入口改用普通接口，
同时检查返回码和原函数指针，并在失败时打印返回码。Windows 启动入口保留
原有 fast hook。

### 3. Nucleus 构建缺少 ELF loader

```text
ERROR: no binary loader available for non-raw type
nucleus_analyze_file(lua51) failed: nucleus load_binary failed: .../liblua51.so
```

此前找不到 BFD 时仅给出警告，仍会产出 raw-only Nucleus，直到首次生成
signature 才失败。现在配置阶段同时要求 BFD 库和 `bfd.h`，并为 Nucleus
设置头文件路径，缺失时直接停止配置。

Linux release workflow 同步安装 `binutils-dev`，确保 CI 也构建带 ELF loader 的产物。

Ubuntu 可安装 `binutils-dev`。用户态解包开发包时，也可以传入
`-DBFD_INCLUDE_DIR=...` 和 `-DBFD_LIBRARY=...`，两者必须匹配。

### 4. 云主机的 Tracy 初始化失败

```text
Tracy Profiler initialization failure: CPU doesn't support invariant TSC.
```

仅设置 `EnableTracy=off` 不会阻止共享库的初始化。Linux vcpkg triplet 为
Tracy 本身设置 `TRACY_TIMER_FALLBACK=ON`，对应 profiler 插件也使用相同
计时器宏。这样无需假定云 CPU 暴露 invariant TSC，也无需设置忽略检查的
运行时环境变量。

最初服务器验证使用单独构建的 fallback Tracy runtime；本次提交将相同的
构建选项固化到 vcpkg，避免常规 `cmake --install` 再次打包默认 TSC runtime。
提交前已重新执行 vcpkg 配置/构建，确认 Debug 和 Release 的 Tracy
`CMakeCache.txt` 均为 `TRACY_TIMER_FALLBACK:BOOL=ON`，核心原生目标重新编译通过。

### 5. Linux Lua 注册表读取 Windows-only 插件

Linux 包不包含 `plugin_render_shadow/modinfo.lua`，但 Lua 注册表原先会
无条件打开它，导致 mod 初始化中断，连带阻止 JIT runtime 配置的执行。
现在在非 Windows 环境跳过该包；保留没有 `IsWin32` 的宿主测试环境行为。

modmain 使用 `xpcall` 输出实际异常及 traceback，然后重新抛出异常，不把
初始化失败伪装成成功。

### 6. Linux 插件引用不存在的 Windows native API

`network.sim` 和 `sim.lagcomp` 的部分 API 只在 Windows 实现，但模块初始化
原先无条件注册这些符号，Linux 下因此 `dlopen` 失败。注册代码现在与实现
一样受 `_WIN32` 条件约束。模块仍能注册 schema 和功能门控；此修复不表示
这两项 Windows-only 功能已在 Linux 实现。

## 构建

使用仓库的 submodule 和 CMake preset，避免混用不同版本的 Injector、插件
和依赖库：

```bash
sudo apt-get install build-essential git cmake ninja-build python3 pkg-config \
    binutils-dev curl zip unzip tar
git submodule update --init --recursive
./vcpkg/bootstrap-vcpkg.sh -disableMetrics
export CMAKE_BUILD_PARALLEL_LEVEL=6
export VCPKG_MAX_CONCURRENCY=6
python3 tools/setup_frida_gum.py
cmake --preset ninja-multi-vcpkg
cmake --build builds/ninja-multi-vcpkg --config RelWithDebInfo --parallel 6
cmake --install builds/ninja-multi-vcpkg --config RelWithDebInfo
```

正式测试的 CMake 为 3.31.6，Ninja 为 1.11.1，编译器为 GCC 15.2；其他工具
版本需要按实际构建结果处理。游戏目录通过 `tools/update_steam_paths.py`
生成的 `cmake/GameDir.cmake` 配置，安装之前应核对目标游戏路径。

此前已配置过缺少 BFD 的构建目录时，应重新运行 CMake 配置再编译。
Tracy triplet 改动会使 vcpkg 重新计算包 ABI 并构建所需依赖。

`Mod/` 是安装产物根目录。按照 README 将其部署到服务器 mod 目录，再执行
`install_linux.sh` 安装游戏目录内的 stub。真实 Injector、插件和依赖留在
mod 目录内。不要只替换 profiler 插件而继续使用旧的 Tracy runtime。

```bash
readelf -lW Mod/deps/libfrida-gum.so
```

检查 `GNU_STACK` 应是 `RW`，没有 `E`。

## 验收记录

2026-09-27，在本地 Ubuntu 26.04.1 x86_64 编译，并在 Ubuntu 26.04 x86_64 /
glibc 2.43 的 DST 747465 dedicated server 上测试。

验收标准是运行到 `Sim paused`，且 `jit.status()` 的首个返回值为 `true`。
使用部署前存档的独立副本、相同 mod 配置及独立 Workshop 缓存；最终测试：

| 检查项 | Master | Caves |
| --- | --- | --- |
| 启动钩子 | `HookStartupEntry OK` | `HookStartupEntry OK` |
| 游戏 VM | LuaJIT 2.1.1787374928 | LuaJIT 2.1.1787374928 |
| Workshop mod 数量 | 19 | 19 |
| `Sim paused` | 00:00:27 | 00:00:29 |
| `jit.status()` | true | true |
| 实际 JIT traces | 1522 | 1112 |

两分片连接成功；`loadstring` 创建的热循环求和校验通过。此前还验证了
`HookStartupEntry` 和其原始 `chdir` trampoline 的实际调用。
这是约 90 秒的启动、mod 加载、分片连接和 JIT 验证，不是多人长时间压力测试。

控制台复核命令：

```lua
print(jit)
print(jit.version)
print(jit.status())
```

首次为 DST 747465 生成 signature 时，`luaL_loadstring` / `luaL_loadbuffer`
记录了保留 offset=0 的诊断；后续 VM 替换和 `loadstring` 执行校验通过。
这不能解释为所有函数签名都已匹配。

另有一次复测遇到 `blueprint.lua:201` 拼接缺失名称的 Lua 错误。干净存档副本
复测通过，但该间歇性错误与 LuaJIT 的因果关系尚未确定。其他游戏/mod 错误
另做原版 Lua 对照：在相同存档副本和 mod 配置下，绕过注入 wrapper、清除
`LD_PRELOAD`，运行原始 `_x64_1` 可执行文件。`jit.off()` 仍使用 LuaJIT VM，
不能作为原版 Lua 对照。
