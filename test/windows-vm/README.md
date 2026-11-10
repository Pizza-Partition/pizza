# Windows 完整重启验收

测试代码全部位于本目录，使用 Zig。宿主通过 libvirt 管理独立的 QEMU/KVM 来宾机。
Windows 可通过 COM2 上的 Zig 测试服务，或 COM1 的 SAC/CMD 启动 Zig 来宾程序；
维护 Linux 使用 COM1。26H2 Core 缺少 SAC，使用专用 Zig 服务模式。磁盘操作使用固定的
zigwin32 绑定、产品 WMI 适配层和本次构建的产品 CLI。宿主全程保持运行，原 WinBoat
不作为故障注入对象。

| 文件                                                     | 职责                                                                   |
| -------------------------------------------------------- | ---------------------------------------------------------------------- |
| `build.zig`                                              | 注册构建、下载、检查和 VM 测试命令                                     |
| `artifacts.zig`                                          | 构建维护 UKI、Windows 产品及测试程序，记录构建摘要                     |
| `images.json`、`image_config.zig`、`fetch_image.zig`     | 镜像配置、续传、缓存和完整性验证                                       |
| `tests.zig`、`runner.zig`                                | 五条 Zig 测试及共享 VM 生命周期                                        |
| `vm.zig`、`libvirt.zig`、`sac.zig`                       | 宿主编排、虚拟机控制、串口和命令分帧                                   |
| `guest.zig`                                              | Windows 提权检查、目标盘/文件系统及计划编辑端口，组装共用来宾验收      |
| `agent.zig`、`agent_protocol.zig`                        | Win32 SYSTEM 测试服务及受限串口指令；不提供通用远程 shell              |
| `servicing.zig`                                          | 查询挂起维护和服务状态；维护结束后固定更新策略并禁用测试基线更新服务   |
| `provision.zig`、`autounattend.xml`                      | 校验 ISO、创建独立磁盘、无人值守安装、能力检查、关机冻结基线           |
| `../vm/common.zig`、`../vm/guest.zig`、`../vm/cases.zig` | 两端共用文件/进程工具、CLI 验收断言和五种恢复交互流程                  |
| `cli.zig`                                                | 构建、下载、宿主测试和来宾工具共用的 zig-clap 参数定义、帮助和解析测试 |

五个工具均支持 `-h` / `--help`；帮助在读取配置、询问密码、要求来宾提权或执行操作前输出。
现有参数也支持 `--name=value`；构建器和宿主测试器仍拒绝重复的单值选项。
仅检查参数解析、不启动 VM：

```sh
zig build test-vm-cli -Dheadless=true
```

## 环境与基线

Linux 宿主需要项目固定的 Zig、QEMU/KVM、qemu-img、mkfs.vfat、mcopy、libvirt 库和
session daemon。构建自动获取锁定的维护镜像，不依赖维护源码检出目录或本地 UKI 工具；
下载使用 curl 的 HTTPS 传输。这些是系统工具依赖，编排和断言均在 Zig 中。

libvirt C API 源码通过根目录 `build.zig.zon` 固定到 12.8.0，由 Zig 翻译头文件。
运行需要同版本的库和 daemon；`zig fetch` 不安装运行环境。
`-Dvm-libvirt=/absolute/libvirt/prefix` 指定包含 `lib/`、`sbin/libvirtd` 的安装前缀。
测试启动私有的无特权 libvirt session，不连接用户已有的 VM session。

Windows 基线需要 virtio-scsi 驱动、Storage WMI、BitLocker WMI，以及 COM2 Zig 测试服务。
服务使用 Win32 Service Control Manager 安装，以 SYSTEM 运行；串口只属于无网卡的测试 VM。
可选 SAC 模式另需 `Windows.Desktop.EMS-SAC.Tools~~~~0.0.1.0`、COM1 115200 波特率的
EMS/SAC 和管理员账号。当前维护 UKI 未签名，要求关闭 Secure Boot。
测试 VM 不配置网卡，运行不依赖 SSH 或防火墙规则。

正常关机后，按同一时间点冻结以下文件并设为只读，禁止复制运行中的系统盘：

```text
base/windows.raw
base/OVMF_CODE.fd
base/OVMF_VARS.fd
```

每次运行创建 qcow2 系统盘覆盖层、UEFI 变量副本、4 GiB 目标盘和只读 FAT 构建产物盘。
目标由本轮随机 serial、WWN 和容量锁定；初始化要求 RAW、非启动/系统盘，并核对
WMI 与 Win32 设备编号。宿主使用 libvirt 的设备属性 override 移除系统盘默认的
`bootindex`，让来宾管理 BootOrder/BootNext，避免 OVMF 清理来宾创建的维护启动项。

## 镜像下载配置

`images.json` 当前固定 Tiny11 Core Pro 26H2 x64、构建 26300.9725、2026-10-27。
地址、来源、大小、SHA-256 和必要能力均由配置提供，下载器不硬编码镜像地址。

```sh
zig build fetch-windows-image -Dheadless=true
zig build fetch-windows-image -Dheadless=true -- --config test/windows-vm/images.json --verify-only
```

`--image ID` 选择条目，`--out DIR` 覆盖缓存目录；相对路径以命令工作目录为准。
`download` 配置缓存目录、重试、连接超时、下载超时和 1–16 个并行连接。
未完成文件以 `.partial` 保存并绑定来源；合并后核对大小和 SHA-256，成功才更名为 ISO
并写入 `.verified.json`。缓存锁阻止并发写入；已有 ISO 再次使用仍验证。

下载成功不等于可用基线，需要安装并验证必要能力。该 ISO 的安装映像已确认为单一
Windows 11 Pro、26300.9725，未包含 `sacsess.exe`/`sacdrv.sys`，不能直接使用 SAC。

## 构建与执行

从 Pizza 根目录获取固定维护发布，构建产品 CLI、Zig 来宾驱动和四个原生测试程序：

```sh
zig build build-windows-vm-artifacts -Dheadless=true -- \
  --out .zig-cache/windows-e2e
```

`--zig FILE` 覆盖默认的本次构建所用 Zig。维护镜像直接来自宿主锁定的发布依赖；`--timeout SECONDS`
控制每条构建命令的截止时间；`--help` 列出全部选项。
构建器从维护镜像元数据读取内核版本并核对 initrd 摘要，将 UKI 补齐至 4096 字节边界。
维护内核的最后一个 console 为串口，以便进行 Accept/Undo 交互。
只有全部构建成功才写入 `build.json`，记录两个仓库版本及工作区状态、协议和 UKI
摘要，以及每个导出程序的大小与 SHA-256。
维护镜像以 SHA-256 命名的输入目录传给 Windows 构建，避免相同路径的新 UKI
复用旧构建图中固定的摘要；导出镜像还会再次核对。

只编译宿主测试器，不启动 VM：

```sh
zig build compile-windows-vm -Dheadless=true -Dvm-libvirt=/absolute/libvirt/prefix
```

用校验后的配置镜像制作全新基线；`--drivers` 提供签名的 virtio-scsi 驱动目录：

```sh
zig build provision-windows-vm -Dheadless=true -Dvm-libvirt=/absolute/libvirt/prefix -- \
  --stage .zig-cache/windows-e2e/stage/bin \
  --drivers /absolute/virtio-drivers \
  --out .zig-cache/windows-e2e/tiny11-26h2-base
```

驱动目录包含 `vioscsi/vioscsi.inf`、`.sys`、`.cat`。安装仅针对本次新建的 64 GiB 磁盘；
应答文件通过可移动 USB 盘提供，Windows Setup 按 GPT/UEFI 安装。首次登录由 CMD 启动
Zig 安装程序，之后的驱动安装、服务注册和测试均使用原生程序。能力检查和正常关机成功后，
冻结系统盘和配套固件，写入 `baseline.json`。安装诊断图保存在 `install.ppm`（PNG 数据）。
收到 Zig 服务的就绪消息后立即通过 libvirt 弹出安装 ISO，防止后续重启再次进入安装器。
串口连接被动等待服务心跳，不向固件发送唤醒字符。

未完成的安装可以在相同命令后增加 `--resume`：先核对来源及摘要，复用可写系统盘和
UEFI 变量，仅重建构建产物 USB 盘；禁止恢复已冻结的基线。此模式不发送 DVD 启动按键。

首次进入桌面不代表安装后的组件维护已经结束。制作器通过 Zig/Win32 查询 CBS/Windows
Update 挂起重启标记和 TrustedInstaller 状态，允许 Windows 完成维护及正常重启。
连续稳定后写入禁止自动更新、升级、自动维护的策略，并通过 SCM 禁用和停止
`TrustedInstaller`、`wuauserv`、`UsoSvc`、`DoSvc`；每项写入均读回确认。
受保护服务拒绝 SCM 配置时，通过原生注册表 API 写入下次启动配置，重启后必须由 SCM
确认已禁用并停止，否则制作失败。
保留系统组件文件。随后再次正常重启，确认策略和禁用状态保留、没有挂起维护，再关机冻结。
这些设置只应用于本次新建的测试系统。`baseline.json` 记录 `updates_disabled` 和维护状态；
Agent 测试拒绝尚未冻结更新的旧基线，并在每次返回 Windows 时再次核对服务状态。

完整 CI 会从固定 ISO 和 `virtio.json` 锁定的驱动重新制作基线，见
[`../vm/README.md`](../vm/README.md)。运行时通过 SMBIOS Type 11 选择串口控制台，
维护 UKI 保持正式发布原件及摘要。

在只读基线上运行全部用例：

```sh
zig build test-windows-vm -Dheadless=true -Dvm-libvirt=/absolute/libvirt/prefix -- \
  --base .zig-cache/windows-e2e/tiny11-26h2-base \
  --stage .zig-cache/windows-e2e/stage/bin \
  --out .zig-cache/windows-e2e/run-unique \
  --user perdixky
```

`--out` 必须不存在，父目录必须存在；每次使用新目录，不重放旧会话。
测试器从 `baseline.json` 读取串口模式；`--transport agent|sac` 可覆盖。
Agent 模式无需密码；SAC 模式隐藏读取密码，无人值守可通过 `PIZZA_VM_PASSWORD` 注入。
密码不写入参数、报告或串口日志，也不传给子进程环境。
`--timeout SECONDS` 控制等待时限，默认 600。

## 用例与断言

先运行 domain、protocol、host、image 四个原生 Zig 测试程序。VHDX 套件覆盖
512/4096 字节扇区、真实格式化、NTFS 缩扩容和数据哈希核对。

| 用例              | 操作与预期                                                                                 |
| ----------------- | ------------------------------------------------------------------------------------------ |
| `accept`          | CLI 查询、生成计划、安装维护镜像、配置重启、维护执行并 Accept，回主系统导入 completed 收据 |
| `undo`            | 同一链路选择 Undo，返回 rolled_back，恢复本轮原始布局                                      |
| `powercut-undo`   | verified 等待确认时强制销毁 VM，保留磁盘与 UEFI，重启后 Undo                               |
| `powercut-accept` | verified 等待确认时强制销毁 VM，重启后 Accept                                              |
| `powercut-apply`  | 观察到 APPLY 时强制销毁 VM，恢复后回滚；若已完整 verified，显式 Undo                       |

`--cases accept,undo` 可选子集，默认全部五条；`--native skip` 只用于调试，结果明确记录
跳过，完整验收必须使用默认原生套件。强制销毁通过 `virDomainDestroy` 执行，不向来宾
发送正常关机请求；QMP 连接和请求生命周期由 libvirt 管理。

每轮核对保留分区 UUID、偏移、长度、类型、属性、槽位、文件系统、卷标和 2 MiB 随机
文件 SHA-256；新分区必须与批准计划一致。收据绑定本轮会话、计划、磁盘和维护镜像，
重复导入结果相同。还核对无关磁盘布局和宿主启动标识，最终来宾正常关机。
每次返回 Windows 后先等待只读 `inventory` 连续成功两次，再执行后续命令。
仅对这一步明确的 WMI 启动错误进行有时限的轮询，不重试改变磁盘或导入收据的命令。

VM 强制销毁不能等同物理设备所有断电行为。APPLY 触发点是外部观察到的阶段边界，
不代表穷举扇区撕裂、掉写或每条写入指令；持久化故障模型另由 pizza-maint 崩溃测试覆盖。
纯命令行流程不覆盖 UAC 图形弹窗或桌面 UI。

## 证据与验证状态

运行目录保存 `domain.xml`、`inputs.json`、`events.jsonl`、`health.jsonl`、
`serial.log`、`agent.log`、`libvirtd.log`、`guest/` 下的请求、响应、原生日志和验证结果。
`results.json` 的 `status=passed` 才表示该轮通过；任何启动、权限、命令或断言失败均
非零退出。覆盖层、目标盘和 UEFI 变量副本保留供复现。
命令失败后也会尝试通过串口导出日志，保留失败调用的 stdout/stderr。

无需 VM 的配置、缓存校验和串口分帧测试：

```sh
zig build test-vm-config test-vm-download test-vm-console -Dheadless=true
```

2026-10-30，当前 Zig/libvirt 实现在配置中的 26H2 镜像上完成本地验收：

- 基线：`.zig-cache/windows-e2e/tiny11-26h2-base-04/baseline.json`，更新服务禁用且停止，无挂起维护。
- 构建：`.zig-cache/windows-e2e/zig-final/build.json`；本轮使用其 `stage/bin` 中的产物。
- 报告：`.zig-cache/windows-e2e/zig-26h2-run-07/results.json`，`status=passed`、`native=true`、五条用例全部通过。
- Windows 原生套件：domain 51、protocol 3、host 67、image 32，共 153 项通过；另有 1 项 Linux 专属测试跳过。
- 三次 `fault:libvirt-destroy`；五轮保留数据 SHA-256 相同，收据重复导入均幂等，维护镜像摘要均匹配本轮构建。
- 宿主启动标识始终为 `d4eb66ef-4585-4714-9af7-d101d97df143`；最终来宾正常关机，私有 VM/daemon 已退出。

上述完整用例从已冻结基线开始，全部通过 Zig/串口自动执行。基线制作期间中断后的
测试服务恢复曾使用虚拟键盘启动 Zig 安装器；这一步不计入上述自动测试通过结果。
此前 `.zig-cache/windows-e2e/run-09/results.json` 属于已删除的旧测试器；历史产物保留。

2026-10-30 公共维护状态机、ESP 格式和 VM 验收流程抽取后，再次使用同一只读 Windows
基线和 `.zig-cache/shared-e2e/windows-stage/bin` 复测：
`.zig-cache/shared-e2e/windows/results.json` 为 passed、native=true，五场景全部通过，
原生测试 156 项通过、1 项 Linux 专属测试跳过，三次强制断电及正常关机成功。
Linux 512/4096 字节矩阵也各五场景通过；共用断言比较整个批准/原始布局。
汇总与产物摘要见 `.zig-cache/shared-e2e/validation.json`。
