# Linux 完整重启验收

Zig 宿主测试器直接启动独立 QEMU/KVM，主系统为 systemd Linux，通过 COM1 上的受限
Zig agent 调用产品 CLI。维护系统也使用 COM1。来宾无网卡，不依赖 SSH、libvirt 或
通用远程 shell。所有可写磁盘均为本次新建的普通文件，不传入宿主块设备。

主流程和断言共用 `../vm/guest.zig`、`../vm/cases.zig` 与 `../vm/common.zig`；本目录仅保留
Linux 基线制作、QEMU/串口、sysfs 设备认证、文件系统操作与 ext4 移动计划端口。

## 环境与构建

当前制作器适配 x86-64 Arch Linux 的系统路径。需要项目固定的 Zig、系统 libblockdev
及其插件、QEMU、OVMF、systemd/ukify/EFI stub、udev、kmod、bsdtar、e2fsprogs、
dosfstools、util-linux 和 mtools。`mkfs.ext4` 必须支持从 tar 输入初始化根目录。
ukify 及其 Python 依赖是外部构建工具；测试编排、产品调用和断言均使用 Zig。

宿主和维护系统使用同一锁定发布。下面的命令同时安装 VM 所需的维护文件到
`.zig-cache/linux-e2e/stage/share/pizza/maintenance`。

```sh
zig build stage-linux-tests maintenance-files -j2 -Dheadless=true -Doptimize=safe \
  --prefix .zig-cache/linux-e2e/stage

zig build compile-linux-vm -Dheadless=true
zig build test-linux-vm -Dheadless=true -- --help
```

`stage-linux-tests` 导出产品、来宾驱动、镜像和 domain/protocol/host/image 四个测试程序。
必须等构建完成后再制作基线，不能并发更新同一 stage。

## 制作只读基线

制作器从维护运行环境提取工具，再加入与宿主产品匹配的 systemd、libblockdev 插件和
动态库。主系统使用指定的宿主内核及 initramfs；宿主必须安装维护元数据所指定内核版本的
FAT/NLS 模块。当前默认路径为 `/boot/vmlinuz-linux`、`/boot/initramfs-linux.img`，
可通过 `--kernel FILE`、`--initrd FILE` 覆盖。

```sh
zig build test-linux-vm -Dheadless=true -- provision \
  --stage .zig-cache/linux-e2e/stage/bin \
  --maintenance .zig-cache/linux-e2e/stage/share/pizza/maintenance \
  --ukify /absolute/path/to/ukify \
  --out .zig-cache/linux-e2e/base-unique
```

父目录必须已存在，`--out` 必须不存在。整个制作过程不挂载磁盘、不创建 loop 设备，
无需 root。tar 输入的所有者统一为 root，再由 mkfs 写入文件镜像。
主系统为 4 GiB GPT/NVMe，含 256 MiB ESP 与 3 GiB ext4 根分区，使用 UEFI fallback 启动。
OVMF 使用支持 Secure Boot 变量的固件和未注册密钥的变量模板；产品要求 Secure Boot
明确关闭，不能用缺失变量替代此条件。

`linux.raw`、`OVMF_CODE.fd`、`OVMF_VARS.fd` 设为只读；`baseline.json` 固定其 SHA-256，
同时记录内核、initramfs 和全部七个导出文件的摘要。运行时验证全部摘要，拒绝 stage
与基线不一致。产品或测试更新后必须制作新基线。

## 执行完整矩阵

每次运行新建 qcow2 系统盘覆盖层、可写 UEFI 变量副本和 4 GiB 目标盘。目标盘通过随机
serial、WWN、容量和空白布局共同锁定；使用 virtio-scsi，系统盘使用 NVMe。
512 与 4096 字节逻辑/物理扇区分别运行，默认使用 TCG；以下命令使用 KVM。

```sh
zig build test-linux-vm -Dheadless=true -- run \
  --base .zig-cache/linux-e2e/base-unique \
  --stage .zig-cache/linux-e2e/stage/bin \
  --out .zig-cache/linux-e2e/run-512-unique --accel kvm --sector 512

zig build test-linux-vm -Dheadless=true -- run \
  --base .zig-cache/linux-e2e/base-unique \
  --stage .zig-cache/linux-e2e/stage/bin \
  --out .zig-cache/linux-e2e/run-4096-unique --accel kvm --sector 4096
```

两轮可以共享只读基线，各自使用独立输出目录。`--timeout SECONDS` 为单次等待截止时间，
默认 600。`--cases accept,undo` 选择子集；`--native skip` 仅供调试，完整验收必须保留
默认四个原生套件和全部五个场景。

| 用例              | 操作与预期                                                                                           |
| ----------------- | ---------------------------------------------------------------------------------------------------- |
| `accept`          | CLI 查询和审批；暂存真实 FAT32 ESP、配置固件、正常重启、移动 ext4、Accept、返回并导入 completed 收据 |
| `undo`            | 执行后选择 Undo，恢复本轮原始布局，导入 rolled_back 收据                                             |
| `powercut-undo`   | verified 等待确认时 SIGKILL QEMU，保留磁盘与 UEFI，重启后 Undo                                       |
| `powercut-accept` | verified 等待确认时 SIGKILL QEMU，重启后 Accept                                                      |
| `powercut-apply`  | 外部观察到 APPLY 阶段立即 SIGKILL，重启恢复并回滚；如已 verified 则显式 Undo                         |

目标盘含 FAT32 ESP 和带 2 MiB 随机文件的 ext4 分区。每轮计划将 ext4 向右移动 64 MiB，
确保实际进入维护执行。检查保留分区 UUID、偏移、长度、类型、属性、槽位、文件系统、
卷标和文件 SHA-256；检查无关系统盘的布局不变、没有残留临时分区、宿主启动标识不变。
收据必须绑定本轮会话、计划、磁盘和构建镜像，重复导入必须相同。最终主系统正常关机，
QEMU 必须成功退出。

## 证据与范围

每轮输出保留 `baseline.json`、`inputs.json`、`qemu-argv.json`、`events.jsonl`、
`serial.log`、`results.json` 和 `guest/` 下的请求、响应、原生套件日志与逐场景验证结果。
仅 `results.json` 的 `status=passed`、`native=true` 且五个场景齐全才表示完整通过。
失败返回非零并尽力导出来宾日志。覆盖层、目标盘及变量副本保留供诊断。

本矩阵验证 systemd/UEFI/CLI 的 ext4 移动与维护恢复链路；未覆盖桌面提权弹窗、所有
发行版、其他文件系统或真实硬件。SIGKILL 是虚拟机断电模型，APPLY 是外部观察的阶段
边界，不表示穷举扇区撕裂、掉写或每条写入指令。

2026-10-30 首轮本地验收（公共层抽取前）：

- 基线：`.zig-cache/linux-e2e/base-15/baseline.json`。
- 512 字节报告：`.zig-cache/linux-e2e/matrix-512-02/results.json`。
- 4096 字节报告：`.zig-cache/linux-e2e/matrix-4096-02/results.json`。
- 汇总复核：`.zig-cache/linux-e2e/validation-final.json`；基线、固件及全部导出程序再次计算摘要一致。
- 两轮各运行 domain 51、protocol 3、host 68、image 5，共 127 项原生测试。
- 两种扇区各五场景通过、各三次 `fault:qemu-sigkill`；五轮文件哈希保持一致，收据导入均幂等。
- 使用与 Windows 验收相同的维护 UKI，摘要 `1cece609a08e9f89d05fd0252f7ed94b2c6ac5d479ce5961f90ec6c3fb12af7d`。
- 最终两台来宾正常关机、QEMU 均退出，宿主启动标识不变。默认 Linux 编译、Windows 维护
  交叉编译、前端现有测试和 Zig 格式检查通过；错误模式、未知选项及 stage 摘要不一致均拒绝。

公共层抽取后再次全量复测：`.zig-cache/shared-e2e/linux-base` 基线及
`linux-stage/bin` 产物，报告分别为 `.zig-cache/shared-e2e/linux-512/results.json` 和
`linux-4096/results.json`，各五场景、129 项原生测试通过。两端共用的完整布局断言和
维护状态机同时通过 Windows 五场景；汇总见 `.zig-cache/shared-e2e/validation.json`。
