# Pizza

Linux / Windows 桌面磁盘规划工具，使用 Zig 0.17.0 和 zig-webui。Linux 动态链接系统
libblockdev，Windows 使用 zigwin32 与系统存储 API；不会携带维护系统的运行库，也不会链接 storage。

三个仓库的边界：

| 仓库         | 内容                                                      |
| ------------ | --------------------------------------------------------- |
| pizza-bundle | 固定版本的维护基础运行环境、内核和模块                    |
| pizza-maint  | PID1、维护界面、storage、离线编译与事务恢复；维护公共协议 |
| pizza        | 桌面查询与规划、libblockdev 宿主执行、重启接管和报告导入  |

当前处于拆仓实施阶段。宿主查询、规划、单程序特权通道和基本执行代码已经接入；
Linux/Windows 维护构建已接通准备、完整重启接管和完成收据导入，并通过隔离 VM 验收。
所有产品构建均消费固定版本和内容哈希的维护镜像，不再提供无镜像构建。
当前覆盖范围不代表所有文件系统或真实硬件均已通过，详见验收文档。

## 构建与测试

Linux 需要系统 libblockdev 3 的开发和运行文件、GLib/GObject、libblkid、pkg-config，
以及 .zigversion 指定的 Zig。zig-webui 与 libblockdev API 源码使用 build.zig.zon
固定 URL 和内容哈希获取；当前 libblockdev 的运行库和插件仍由系统提供。
文件系统工具按操作需求探测，不自动安装。
`config/toolchain.json` 保留 CI 使用的 Zig 下载地址和 SHA-256，版本与 `.zigversion` 一致。
维护基础镜像的发布配置由 `pizza-maint` 管理。`build.zig.zon` 的 `pizza_maintenance`
固定其 UKI 发布包；构建自动获取镜像、编入 SHA-256 并安装到可执行文件旁的 `maint.efi`。
缺失或不符合块对齐要求的镜像会使构建失败，不需要传入镜像路径。
`build/linux.zig` 统一管理系统头文件的 `addTranslateC` 导入与 GTK 构建补丁，
磁盘清单、操作编排与特权会话由 Zig 实现。
文件系统检查、容量查询与调整直接调用 libblockdev，应用负责执行顺序和会话管理。

```sh
zig build
zig build check
zig build test-domain
zig build test
zig build test-host-image
node --test ui/partition/test/*.test.mjs
zig-out/bin/pizza inventory
zig build run
zig-out/bin/pizza serve 4173
```

后端测试使用 Zig 的 test、std.testing 和 std.process；不需要 Python。
`test-domain` 单独编译业务层测试，不导入系统 C API 或 WebUI，也不链接 libblockdev。
源码职责及依赖方向见 [core/README.md](core/README.md)。
CLI 参数由 clap 解析；`zig fetch` 将依赖固定在 `build.zig.zon` 的提交和内容哈希上。使用 `pizza --help` 或 `pizza serve --help` 查看用法。
`test-host-image` 使用系统 libblockdev 和 e2fsprogs，只格式化临时普通文件镜像，
验证格式化、标签、写入拒绝和磁盘锁，不需要 root，也不代表 VM 分区更新验收通过。
Windows 的 `zig build test-windows-image -Dwindows-lld=true` 需要管理员会话及系统加密状态
检测提供程序，仅操作测试新建的临时 VHDX，验证真实缩扩容、卷标签和格式化；详见
[Windows 验收入口](docs/windows-backend.md#虚拟磁盘验收)。
Linux 宿主控制 Windows 来宾机的完整重启测试器见
[Windows VM 测试](test/windows-vm/README.md)：使用本地缓存的基础盘、独立系统盘覆盖层和
测试盘，覆盖维护接管、Accept/Undo、报告导入和 QEMU 强杀恢复；通过串口测试服务运行，无需网卡或 SSH。
Linux 主系统的同类验收见 [Linux VM 测试](test/linux-vm/README.md)，覆盖 systemd/UEFI、
512/4096 字节扇区、真实 FAT32 ESP 暂存、ext4 移动和五种完成/断电恢复场景。
前端模型及执行状态测试使用 Node。`pizza serve [端口]` 直接由同一 Zig 程序提供本地页面与
WebUI 通信，无需 Python；桌面窗口与浏览器使用相同的查询、提权、验证和执行入口。
它只监听回环地址，启用 WebUI cookie 和单客户端限制，不开放远程执行服务。
直接运行 `pizza` 打开独立的原生 WebView 窗口，不带浏览器地址栏或标签栏。
Linux 使用系统 GTK 3 和 WebKitGTK 4.1；缺少运行库时报告错误，不自动启动系统浏览器。
`pizza serve` 则只启动服务，需要在浏览器中访问输出的网址。

Zig 编译步骤默认启用 incremental；Windows 使用 Zig 的 `Coff.zig` 链接器，
Linux 使用 `Elf2.zig`，均不使用 LLD。Windows 可通过 `-Dwindows-lld=true`
显式切换到兼容 GNU CRT、WebUI 和系统导入库的 LLD 构建，此时关闭增量编译。
当前固定工具链使用 LLVM 配合原生 COFF 链接 Windows GNU 目标时，即使移除 WebUI 和
zigwin32 的最小程序仍会出现未解析符号；关闭增量编译也不能解决。当前已验证的 Windows
完整构建使用 LLD；默认原生 COFF 配置仍无法完成链接。复现及后端组合见
[Windows 构建说明](docs/windows-backend.md#链接器核查)。
开发监听入口同时启用 `-fincremental --watch`：

```sh
zig build dev
# 监听源码变化并重跑业务层测试
zig build dev -- test-domain
# 等价的直接调用；还可附加 -Dtarget、-Doptimize 等构建参数
zig build -fincremental --watch
```

开发时直接运行当前构建，不需要复制到系统目录：

```sh
zig build run
# 或浏览器预览
zig build run -- serve 4182
```

软件安装、升级与卸载交给包管理器或平台安装包；Pizza 不提供自安装或自更新命令。
`zig build` 默认只把产物暂存到项目 `zig-out`，打包工具可设置输出前缀收集文件。
例如 `DESTDIR=PACKAGE_ROOT zig build -Doptimize=safe --prefix /usr` 会将可执行文件、
`packaging/linux/pizza.desktop` 桌面入口和图标暂存到包目录，不复制系统运行库或文件系统工具。
发行包需要声明上文列出的系统依赖，具体包名按发行版选择。
安装与分发配置按平台放在 [packaging](packaging/README.md)，生成的发行包不提交到源码仓库。
普通模式拒绝作为 root 启动 UI。点击“Authorize and read partitions”时，程序通过
系统工具请求授权，按当前可执行文件的绝对路径启动同一程序的特权模式：

```text
run0 --pipe --chdir=/ /absolute/path/to/pizza privileged-exec
```

Linux 使用 `if / else if` 检查工具是否可执行，顺序为 `run0 → pkexec → kdesudo`，
调用第一个存在的工具。后两者参考 [microsoft/vscode-sudo-prompt](https://github.com/microsoft/vscode-sudo-prompt)
的 Linux 路线。在现有原生进程中直接传递参数，不引入 Node.js 运行时。
用户取消授权后直接返回，不切换其他工具重复提示。授权代理负责显示密码确认框。

开发目录和包管理器安装的程序使用同一流程，不要求程序属于 root，也不要求系统前缀。
如果正在运行的程序已被重新构建替换，需要重启该窗口后再授权。
读取完整分区表的授权仅用于查询；实际执行仍需要确认计划。
不通过用户 PATH 查找自身，不提供独立 helper。需要 run0、pkexec 或 kdesudo，以及 polkit
和可用的授权代理。特权进程使用受控工具 PATH、校验 IPC 对端、验证计划摘要，
并按用户隔离持久会话记录。已经开始的步骤不因页面退出而被强制终止。
宿主执行没有统一 Undo；失败后报告实际布局，不自动重试。
执行由后台会话持有，页面查询进度；取消只停止后续步骤，已开始的写入会完成并核对结果。
页面重新打开后可重连，丢失执行回复时按原计划摘要查找会话，不能自动重发执行。
执行结束可下载包含实际布局和步骤计数的 JSON 报告。

Linux 窗口启动时会在 GTK 初始化线程中将本进程的 `hintfull` 调为 `hintslight`，
避免 WebKit Skia 后端的字形间距问题。其他 hinting 样式保持原样，不写入桌面字体配置。
NVIDIA/Wayland 环境下，程序为自身设置 `__NV_DISABLE_EXPLICIT_SYNC=1`，
规避 [WebKit bug 280210](https://bugs.webkit.org/show_bug.cgi?id=280210)，保留 DMA-BUF。
已有的 `__NV_DISABLE_EXPLICIT_SYNC` 值优先；也可显式设置
`WEBKIT_DISABLE_DMABUF_RENDERER=1` 使用共享内存回退。X11 会话不应用该 NVIDIA 设置。

## 协议与维护验收

`pizza_maintenance` 固定维护系统 v0.5.1 的发布 URL 和 Zig 内容哈希，包内包含块对齐
UKI、内核、initramfs 和独立 v4 协议（Zig/JS/TS 绑定与内容清单）。宿主始终消费同一发布
包内的镜像和协议；协议版本不匹配直接拒绝，不转换旧草稿。
`zig build` 和 `zig build check` 将前端绑定安装到 `zig-out/share/pizza/protocol`；
仅运行前端测试或开发预览时，也可先执行 `zig build protocol-bindings`。
`zig build maintenance-files` 将完整维护发布内容安装到 `zig-out/share/pizza/maintenance`，
供隔离 VM 验收使用；常规安装只携带宿主需要的 `bin/maint.efi`。
容量和偏移使用十进制字符串传输、BigInt 编辑，显示最多两位小数。

维护仓库提供 `zig build protocol-package` 导出协议，以及以下 Zig 验收入口：
`check`、`check-proto`、`test-session`、`test-maint-session-image`、
`test-storage-unit`、`test-filesystems`、`test-storage-crash`。
跨进程维护测试只使用临时普通镜像文件，覆盖恢复、撤销、接受后关闭撤销和清理。
完整 UEFI/OVMF 重启验收仍须另行完成，不能以这些镜像测试替代。

历史设计记录保留在 docs；其中旧协议及旧切换方式不代表现行接口。
