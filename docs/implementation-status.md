# 三仓库拆分实施状态

这是实施记录，不是全部验收完成声明。

- 迁移前快照：`/tmp/pizza-before-split-20261027-163407/worktree.tar.gz`，包含
  344 个跟踪及未忽略文件；同目录保留原 HEAD、工作树状态和文件清单。
- pizza-maint 从原仓库本地 clone，保留 Git 历史，迁移的是包含未提交改动的快照。
  后续修改同步至 `/home/perdixky/Codes/pizza-maint`。没有提交、推送或创建远端仓库。
- pizza-bundle 保留原独立构建。其既有 Python 构建脚本和测试尚未改写；本轮没有
  新增或运行它们。宿主与维护系统新增/迁移的测试使用 Zig，前端显示及请求适配继续使用 Node，分区编辑与 plan 生成规则使用 Zig。

| 部分 | 当前实现 |
| --- | --- |
| 宿主独立构建 | Zig+zig-webui，系统动态 libblockdev/GLib/libblkid，无 storage 链接 |
| Windows 后端 | 已接入编译期平台组合、WMI/IOCTL 清单、NTFS 缩扩容与卷标签/格式化、UAC 会话；BitLocker 禁写；实现与验收边界见 [windows-backend.md](windows-backend.md) |
| Windows 临时盘验收 | `test-windows-image` 在 Podman WinBoat / Windows 11 专业版实际通过 debug 与 safe：NTFS 缩扩容、Unicode 标签、exFAT/FAT32/NTFS 格式化、双卷数据哈希与写前拒绝；宿主、业务和协议套件也通过。已清理测试虚拟盘，详见 [实测记录](windows-backend.md#winboat-实测记录2026-10-28) |
| libblockdev 构建输入 | Zig fetch 固定 3.5.0 源码和哈希，使用该 API 头文件；运行库和插件仍来自系统，尚未从该源码构建运行库 |
| 协议 | 独立 v4 包；维护端生成和导出 Zig/JS/TS，宿主检查导出内容清单；不保留旧 wire 协议入口 |
| 提权 | 当前可执行文件绝对路径 + privileged-exec，按 run0 → pkexec → kdesudo 顺序检查可执行工具；开发目录直接可用，无系统安装/所有权前置条件；IPC 对端及会话凭据检查、按用户隔离的持久状态 |
| 查询/规划 | Linux/Windows 清单查询；GUI/CLI 共用无状态 Zig 编辑器及 `Service.plan`，负责边界调整、UUID/操作生成、规范化和宿主/维护阶段分类。`-Dheadless=true` 构建不含 WebUI 的后端入口 |
| 宿主执行 | 后台会话、逐步进度、当前步骤完成后取消、重连及 JSON 报告；Linux 格式化/标签通过临时文件镜像测试；Windows 临时 VHDX 通过实际分区写入验收 |
| 浏览器执行入口 | `pizza serve [端口]` 复用同一程序的 WebUI、系统授权和执行器；页面探测当前程序/系统授权工具及格式工具，管理员读取后在编辑器内刷新，验证保持同一权限基线。旧 Python 服务仍只读 |
| 桌面窗口 | 默认 `pizza` 显式使用原生 WebView；Linux 为系统 GTK 3 + WebKitGTK 4.1，不允许自动回退到系统浏览器。`serve` 保留为显式浏览器模式 |
| 窗口关闭 | 构建时修正固定 WebUI 版本 GTK delete-event 的 bool/int ABI 错误，不修改下载缓存；原生主循环处理关闭并退出 UI，启动时无需等待页面连接即可关闭 |
| 字体与显示兼容 | TTF 使用正确字体 MIME 与变量字重声明；设备路径使用等宽字形和斜线零。编辑器图例与操作提示至少 13px，横屏侧栏采用 15px 分区名和独立容量行，提高文字对比度；空间不足时侧栏滚动。原生 WebView 创建前在 GTK 线程将进程内 hintfull 调整为 hintslight，避免 WebKit 横向字形取整造成异常字距，保留其他 hinting 设置，不写入系统配置。NVIDIA/Wayland 默认在自身进程使用 implicit sync，保留 DMA-BUF 与显式环境覆盖，不改动 JIT |
| 编辑器布局 | 横向窗口按比例重排：左侧标题、权限说明及分区图例，中间披萨，右侧设置；窄屏折叠设置。分区条与导航保留，侧栏内部滚动，格式菜单使用独立浮层 |
| 维护会话 | 离线编译、RawCapsule、恢复锚点、Undo/Accept/Cleanup；已接入冻结 FAT 分配链的 ESP 收据读写与认证终态发布，持久化并读回后才恢复启动；Linux/Windows QEMU 均通过 Accept、Undo、断电恢复及幂等收据导入 |
| 内核切换 | UEFI UKI 构建、Linux/Windows ESP 准备及启动租约、PID1 固件绑定接管已接通；两平台均通过主系统 → UEFI UKI → 离线编译/实际写入 → Accept 或 Undo → 自动返回 → 认证收据导入 |
| 发布 | 已区分构建边界；发布 workflow 暂只生成手动源代码预览，未启用 ISO/UKI 或发行版包正式发布 |

已通过的本地检查：

- Hyprland 原生窗口正常关闭：页面加载后与刚创建时分别发送 compositor close，窗口消失、UI 退出码 0，均约 2 秒；不是强杀测试。
- NVIDIA 615.78.08 / WebKitGTK 2.54.1：原始 explicit-sync 路线复现 Missing acquire timeline；仅禁用 NVIDIA explicit sync 后，协议日志确认 DMA-BUF 创建成功，页面截图正常，关闭退出码 0。
- WebKitGTK 2.54.1 / 显示缩放 166.67%：原生测试窗口复现 hintfull 下按钮、分区名及说明文字间距不均；实际调用项目字体处理后变为 hintslight，渲染对比正常；hintnone 保持不变。应用构建、宿主检查和两种窗口关闭场景通过。
  修复后的默认启动及显式 shared-memory 回退分别复测通过。开发时直接启动构建目录，不再维护手动安装的系统副本。
- 宿主 `zig build fmt-check check` 通过，包含开发构建无需 root 所有权/系统前缀的 Zig 回归，另包含协议包测试。
- 新增 `zig build test-host-image`：2 个 Zig 测试，实际调用系统 libblockdev、blkid、e2fsck，
  验证临时文件镜像的格式化/标签、无效标签和挂载限制拒绝、缩容最小尺寸/健康预检只读，
  以及锁冲突时逐字节不变。
- Node 前端模型 4 个、执行轮询/重连/取消 7 个、原生会话与提权校验路由 1 个用例通过。
- 维护 `check`、`check-proto`、`test-session`、`test-maint-executor`、
  `test-maint-session-image`、`test-report`、`protocol-package`。
- 维护 `test-storage-unit`、`test-filesystems`、`test-storage-crash`。
  随机强制终止用例本轮 seed=3166637973500666117，120 rounds，90 次进程终止（其中 30 次发生在写入中），
  19 次恢复进程终止；测试只使用临时普通文件镜像。
- 协议包独立 `zig build test`；宿主安装前缀通过 DESTDIR 暂存目录检查。

已删除此前手工复制的 `/usr/local/bin/pizza`。安装、升级和卸载交给包管理器/平台安装包；
构建步骤仅将产物暂存到输出目录。真实只读查询和原生 WebUI 通信已验证；
管理员查询确认两块 NVMe 的 GPT 可用边界和 USB 的 MBR。
当前开发构建通过 pkexec 从新会话完成管理员只读查询，验证前确认没有旧 root 会话；
同一测试确认 `/usr/local/bin/pizza` 不存在，授权后 GPT 编辑状态正常。当前 4182
预览由 `zig build run -- serve 4182` 提供；临时验证服务在完成后关闭。
编辑器在读取后留在当前磁盘，GPT 草稿编辑已解锁；真实后端的无修改草稿校验也通过。
没有提交真实执行请求。
同权限验证、执行进度和报告按钮的页面链路使用模拟端点验证，没有调用真实写盘接口。
编辑器在 1440×960、1280×720、1024×600、768×640、390×844、600×400、320×568 下检查。

已验收：Windows 临时 VHDX 写入与数据核对；专用 4 GiB 测试盘的 ESP 准备、
v4 PID1 接管、真实 UEFI 重启、Accept/Undo 自动返回及报告导入。中断恢复也已实测，
并核对原有 GPT、文件系统、卷标及文件哈希。证据见 Windows 后端文档。
尚未验收：桌面 UAC 交互、窗口重连及宿主服务强制中断；ISO 仍未发布。完整 QEMU
断电矩阵现已通过，当前证据见两平台 VM 测试文档。

`prepare`、`reboot`、`complete-session` 已接入显式启用的 Linux/Windows 维护构建；默认固定协议
依赖与正式镜像发布仍需更新；完整返回流程已在显式维护构建中实际通过。宿主执行取消已实现，但
实际写盘场景的 系统提权授权、浏览器退出及服务恢复仍需桌面/VM 集成验收。
混合计划在维护预检完成前保持不可执行，不能先运行宿主前缀。
执行边界新增检查：取消前不写入、取消中核对当前步骤后停止；库调用失败但已有写入时
报告 needs_recheck/partial；日志同步失败停止后续步骤。后台租约可跨请求线程移交，
活动执行不会被服务空闲退出终止。
首个写入前遍历计划内的缩容操作，检查当前文件系统健康和真实最小尺寸；工作线程
开始写入前再次检查。尚无健康预检的在线缩容保持关闭，卷能力按当前挂载状态返回。连接丢失不自动重发执行；未知会话编号时仅通过
原计划摘要查找相符的用户会话。普通进度查询不触发系统提权，重新授权由用户点击触发。

共享收据包含会话、计划、物理程序、磁盘及镜像五个标识；协议包提供有界、严格的
匹配校验。该校验不替代 ESP 设备/分配链与可信来源验证。维护测试覆盖收据同步失败
和读回不符时保留固件绑定及维护启动，以及固件恢复中断后的幂等完成。
相同的已发布收据不会再次写入；固件绑定已移除而收据缺失时拒绝补写。
协议导出构建跟踪清单中的源文件；宿主测试在构建时嵌入清单和内容摘要，交叉编译后
不再依赖构建机器的绝对路径，也不固定导出文件数量。

已删除手动系统副本。提权改为参考 vscode-sudo-prompt 的 Linux 路线，由原生进程
按 run0 → pkexec → kdesudo 检查工具存在性并调用第一个可执行者；无需 Node.js 或系统安装前置条件。没有修改真实分区、
改变 UEFI 变量或重启当前系统。

## Linux 维护入口（2026-10-30）

已增加 Linux Controller 的 prepare/reboot/complete/pending/cancel，接入显式维护构建。
root 持久记录、FAT32 ESP 暂存和 efivarfs 固件绑定已实现；启用维护的构建与 71 项测试通过。
QEMU/KVM systemd 主系统已通过 512/4096 字节扇区的五场景完整矩阵，各运行 127 项
原生测试，覆盖真实 UEFI 接管、ext4 移动、Accept/Undo、三次断电恢复及幂等收据导入。
Linux 清单同时修复空白盘分区表类型和 GPT GUID wire 编码。复现与证据见
[Linux VM 测试](../test/linux-vm/README.md)及 [Linux 维护控制器](linux-maintenance.md)。

## 平台与 VM 公共层（2026-10-30）

Linux/Windows 维护控制器现共用 `core/boot/maintenance.zig`，平台模块仅提供原生端口。
待处理记录与终态收据校验、准备/重启/导入/取消状态转换和持久化顺序使用一份实现；
Windows 同步采用此前仅在 Linux 实现的严格记录校验。`core/boot/staging.zig` 共用 ESP
路径、文件名、上限及收据解封。原生固件策略、设备安全及同步机制仍在平台层。

两端 VM 共用 `test/vm/guest.zig` 的 CLI 审批与验证、`cases.zig` 的五场景交互和
`common.zig` 的进程/证据工具；Linux 不再依赖 Windows 目录中的公共辅助函数。
Accept 比较完整批准布局，Undo 比较完整原始布局，同时检查保留数据、无关盘和幂等收据。
`test-vm-common` 独立验证布局变化拒绝、自动选择新分区槽位及用例选择规则，可在两平台构建。

重构后真实 VM 共 15/15 场景通过：Linux 512/4096 字节各五场景、各 129 项原生测试；
Windows 五场景、156 项通过及 1 项平台专属跳过。三套各三次断电，数据、布局和幂等收据
均核对通过，来宾正常关机，QEMU 全部退出。证据：`.zig-cache/shared-e2e/validation.json`。
