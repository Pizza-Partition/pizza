# Pizza transition

按 [启动切换 spec](docs/superpowers/specs/2026-10-13-pizza-transition-design.md)
建立的工程与测试基础设施。使用 **Zig 0.18.0-dev.146+35accc06e**。
默认目标是 x86-64 基线、Linux 4.18；PID 1 与宿主工具静态构建；普通维护应用动态链接 glibc，并在运行时加载 WPE。

第三方运行环境由独立仓库 [pizza-bundle](https://github.com/Pizza-Partition/pizza-bundle)
通过 pacman 与 patchelf 构建，隔离测试通过后发布 GitHub Release 和 Sigstore attestation。
本仓库通过 `config/bundle/release.json` 固定归档摘要、仓库 ID、tag 与 commit，使用
GitHub CLI 验证发布 workflow 与来源，然后向基础 initramfs 追加当前构建的程序和界面。
内核固定为 Linux 7.2.11（7.2.11-arch1-1），同时携带匹配模块；镜像构建不依赖宿主安装同版本内核。
无需安装宿主 WPE；依赖包管理、ELF 重定位和运行环境审计都属于 pizza-bundle。

```bash
zig build deps
zig build runtime-deps
zig build bundle -Doptimize=safe
zig build image -Doptimize=safe
zig build fmt
zig build fmt-check
zig build doctor
zig build all
zig build test
KERNEL=/boot/vmlinuz-linux zig build test-smoke
zig build -Doptimize=safe
```

构建入口先检查系统 `npm` 和 `node` 是否可用，缺失时提示安装并配置 PATH。
`zig build deps` 使用 `ui/package-lock.json` 执行 `npm ci`。
`zig build all` 构建核心程序、前端和完整 bundle；普通 `zig build` 安装核心程序与工程工具。
协议生成、bundle 校验、镜像打包和 VM 测试均使用 Zig，命令行参数使用锁定的 `zig-clap`。
`zig build tools -- COMMAND [ARGS]` 可直接运行工具命令；安装后的入口为
`zig-out/bin/pizza-tools`。核心工具使用 Zig；发布产物下载、attestation 验证和组装由 Node 调用 GitHub CLI、
patchelf 与 GNU tar/cpio 完成。

测试入口位于 `test/main.zig`，由 `zig build test-smoke`、`test-maintenance`、
`test-journal`、`test-matrix` 分别运行。`zig build test-runners` 安装可选宿主测试入口与
journal 夹具。`zig build test-bridge` 在具备 WPE 的宿主运行真实 panel 原生桥接自检；
也可用 `test-maintenance -- --bridge` 在 RAM 维护镜像内验证完整闭包。

`zig build bootstrap-zig -- --destination /tmp/pizza-toolchains` 下载 SHA-256
固定的官方 nightly；该入口需要已有可编译本项目的 Zig。CI 的首次引导使用已有
Node 下载并校验同一锁文件。开发环境应使用 `config/toolchain.json` 指定的版本。
`-Doptimize` 可选 `debug`、`safe`、`fast`、`small`。

工程分工：

| 路径                       | 用途                                                        |
| -------------------------- | ----------------------------------------------------------- |
| `core/proto/contract.json` | 协议唯一来源：类型、bridge 通道和方法、版本、日志布局       |
| `core/transition/`         | build / transition / report 的核心模块边界                  |
| `core/init/`               | 静态 PID 1：RAM 初始化、模块加载、应用监护及子进程回收      |
| `core/maint/`              | 维护业务、执行器、journal 与供界面读取的业务后端            |
| `ui/partition/`            | 正常系统中的分区任务交互与规划，尚未实现                    |
| `ui/execution/gui/`        | initramfs 执行 GUI：网页、WPE 宿主与 JS/native 消息处理     |
| `ui/execution/tui/`        | initramfs 执行 TUI：libvaxis 仪表盘与串口文本输出           |
| `build/bundle/`            | 消费可信运行环境，加入 Pizza 程序和界面                     |
| `core/bundle/`             | 运行环境路径与布局契约                                      |
| `core/initramfs/`          | newc/gzip 归档、基础层合并及模块单元测试                    |
| `tools/`                   | 工程命令行接口：参数解析、调用模块 API、结果输出            |
| `core/utils/`              | 通用的文件操作、子进程和 JSON 校验                          |
| `config/`                  | 发布来源锁、协议、工具链配置                                |
| `test/`                    | QEMU/OVMF 启动、完整切换验收门、故障参数、发行版 ABI 运行器 |

`zig build proto` 更新生成文件；`zig build check-proto` 检测漂移。生成文件随工程提供，正常构建只校验，不自动改写协议。序列号在 JSON/bridge 中用十进制字符串
传输，避免 JavaScript 丢失 u64 精度；磁盘日志仍是小端 u64。

当前完成外围工程、本地 bundle 的原生部署，以及 phase 3 的 RAM 维护环境基础：
`pizza-init` 检查 RAM 根、挂载 proc/sys/dev/devpts/run/tmp、加载匹配内核的驱动，
解析非敏感 `pizza.*` 参数并持续回收子进程。初始化失败或应用退出时 PID 1 保持存活；不自动重试维护操作。
正常启动由静态 PID 1 启动并监护 `bin/pizza-maint`。业务与 WPE 宿主同进程；网页自动通过原生 bridge 连接，事件按 journal 序号回放，不使用 HTTP/SSE 或令牌表单。
`zig build test-maintenance -- --kernel-version VERSION` 构建并启动基础层加应用层的真实镜像，
验证动态 bundle 程序、设备发现、信号处理和孤儿进程回收；需先准备包含当前 PID 1 的完整 bundle。
`zig build bundle`（也包含在 `zig build all` 中）下载并验证固定的运行环境发布归档，加入静态
`pizza-init`、动态 `pizza-maint` 与前端，生成 `zig-out/share/pizza/bundle.tar.gz`。
`pizza transition build --kernel KERNEL --initrd IMAGE --plan PLAN --journal-device DEVICE --journal-home DIR`
暂存匹配内核、维护镜像与计划；`pizza transition transition` 通过 systemd 执行 kexec。
包来源通过 GitHub Attestations 验证。消费端不重复审计上游 ELF 或维护逐文件哈希清单；
`manifest.json` 只描述接口、架构、布局与已验证的运行环境版本。WPE 的 DRM、sandbox
及旧内核兼容性仍需分别验收。
journal 已实现 64 字节小端记录、CRC32、fsync 追加和跨 boot 恢复。
`pizza transition report --journal /path/journal.bin` 只读输出 JSON 时间线与步骤状态，
有效前缀后的损坏会明确报告；仅有 intent 的步骤保持 `in_flight`。
`zig build test-journal` 使用同一块临时 ext4 虚拟盘完成两次 QEMU 启动验收。
模拟执行器已接入普通应用：显式 `--execute --plan PLAN --journal-home DIR` 启动全新的 20 步模拟计划，
每步 intent/结果均 fsync，网页与串口 TUI 同时更新。延迟和注入挂起通过主循环推进；日志失败停止执行。
具备终端时使用 libvaxis 仪表盘；`--tui` 强制启用，`--no-tui` 使用文本输出。
`q` 隐藏仪表盘并继续执行，`Ctrl+C` 中断维护应用；尚未确认完成的步骤保留为待核查状态。
界面目录职责见 [ui/README.md](ui/README.md)。
已有 journal 一律拒绝重跑，只读查看会标明未完成步骤。`--no-ui --exit-after-plan` 可用于命令行验收。
`zig build test-executor -- --bundle PATH --kernel-version VERSION` 验证真实 WPE 实时进度、失败/挂起/fsync/短写，
并以独立 ext4 虚拟盘完成第二次启动恢复及只读报告验证。
kexec 切换与独立 ext4 journal 设备的生产交接已接入，使用方法见 [docs/transition.md](docs/transition.md)。
维护镜像先由 `pizza-tools image` 构建；分区和文件系统操作仍为模拟。WPE/bridge 已接入普通应用；DRM、sandbox 与旧内核矩阵继续单独验收。项目外的可行性实验使用独立最小程序，不能替代后续核心实现的验收。

依赖与打包见 [docs/dependencies.md](docs/dependencies.md)，测试入口见
[test/README.md](test/README.md)，需要修订或确认的 spec 约束见
[docs/spec-clarifications.md](docs/spec-clarifications.md)。

参考用户指定的 [zigcc/skills](https://github.com/zigcc/skills)：
[0.17 API 指南](https://github.com/zigcc/skills/blob/main/zig-0-17/SKILL.md)
与 [TigerStyle](https://github.com/zigcc/skills/blob/main/zig-tiger-style/SKILL.md)。
0.18 的实际 API 以锁定工具链的本地标准库源码和编译结果为准。

格式化统一入口为 `zig build fmt`；`zig build fmt-check` 只检查，并用于 CI。
Zig 和 ZON 直接使用官方 `zig fmt`；JSON、JS/TS、HTML、CSS、YAML、Markdown 使用锁定版本的
Prettier；C 使用系统 clang-format。配置为 `.prettierrc.json`、`.clang-format`，
编辑器通用规则在 `.editorconfig`。首次执行 `zig build deps` 安装前端开发依赖，
并确保系统已安装 clang-format。
生成的协议绑定也使用同一格式规则，避免格式化和重新生成互相改写。

运行日志统一使用 `std.log`；帮助文本和供脚本读取的 JSON 结果输出到 stdout。
公共函数显式接收 allocator、I/O 等所需参数，没有通用 Context 或自制参数解析器。

独立启动镜像选用 systemd-boot + UKI，目标为 x86-64 UEFI；阶段与布局见 [boot-image.md](docs/boot-image.md)。
