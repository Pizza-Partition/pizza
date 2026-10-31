# 测试

独立测试入口、测试替身和 VM 编排都放在本目录。

| 入口                      | 范围                                                                 | 命令                                              |
| ------------------------- | -------------------------------------------------------------------- | ------------------------------------------------- |
| `domain.zig`、`domain/`   | 规划、审批、执行与后台任务的业务测试及替身                           | `zig build test-domain -Dheadless=true`           |
| `host.zig`、`windows.zig` | 当前平台、授权通信、持久记录与协议包证据                             | `zig build test-host -Dheadless=true`             |
| `linux-image.zig`         | 仅写入测试创建的普通文件镜像                                         | `zig build test-host-image -Dheadless=true`       |
| `windows-image.zig`       | Windows 管理员进程中真实 VHDX 测试                                   | `zig build test-windows-image -Dwindows-lld=true` |
| `windows-vm/`             | Linux/QEMU Windows 完整维护重启及断电流程                            | 见 [windows-vm/README.md](windows-vm/README.md)   |
| `linux-vm/`               | Linux/QEMU systemd 主系统、UEFI、512/4096 字节扇区完整维护及断电矩阵 | 见 [linux-vm/README.md](linux-vm/README.md)       |
| `vm/`                     | 两端共用的五场景流程、CLI 来宾验收、布局/收据断言及进程/证据工具     | `zig build test-vm-common -Dheadless=true`        |

`zig build stage-windows-tests` 交叉编译并导出 Windows 测试程序；测试分组和命令保持不变。
Windows 交叉编译不会执行生成的 `.exe`，真实运行应在隔离 VM 或 Windows 测试环境中进行。

`build.zig` 在构建缓存中将 `core/` 和 `test/` 组织到共同的模块根目录，
使测试能够导入产品源码，不必将测试入口放回 `core/`，也不添加测试专用的公开产品 API。
源文件旁的内联 `test` 声明仍随其模块一起纳入相应套件。

Linux 维护控制器随 `test-host` 检查持久状态、ESP 路径规则、交接请求与固件租约；
镜像和协议来自同一锁定维护发布。平台实现与整机验收边界见
[Linux 维护控制器](../docs/linux-maintenance.md)。
`zig build stage-linux-tests` 导出 Linux 产品与四个原生套件，完整重启验收使用独立文件镜像。

`vm/guest.zig` 通过平台端口选择测试盘、准备文件系统、编辑计划和读取保留文件，公共层
负责审批调用、准备/重启、导入收据、文件哈希、无关磁盘以及整个批准/原始布局的核对。
`vm/cases.zig` 统一用例类型、选择校验和 Accept/Undo/断电后的交互；两端宿主提供串口、
时钟和 VM 生命周期。Linux 保留 QEMU 进程控制，Windows 保留 libvirt/SAC/SCM 适配。
`vm/common.zig` 提供共用文件、JSON、进程、截止时间和宿主启动标识工具，不属于 Windows。

2026-10-30 公共层重构后，三套真实 VM 矩阵全部通过：

| 主系统               | 场景 | 原生套件                          | 报告                                            |
| -------------------- | ---- | --------------------------------- | ----------------------------------------------- |
| Linux，512 字节扇区  | 5/5  | 129 通过                          | `.zig-cache/shared-e2e/linux-512/results.json`  |
| Linux，4096 字节扇区 | 5/5  | 129 通过                          | `.zig-cache/shared-e2e/linux-4096/results.json` |
| Windows 26H2         | 5/5  | 156 通过，1 项 Linux 专属测试跳过 | `.zig-cache/shared-e2e/windows/results.json`    |

每套各三次强制断电，保留文件哈希、完整布局和幂等收据均通过；来宾正常关机且 QEMU
全部退出。汇总、产物摘要及公共源文件摘要见 `.zig-cache/shared-e2e/validation.json`。
另有宿主 70、协议 3、公共 VM 断言 3 项及配置/下载/串口/CLI 工具回归通过；默认 Linux
构建与 Windows 维护及公共断言交叉编译通过。
