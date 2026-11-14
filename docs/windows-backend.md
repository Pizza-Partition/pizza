# Windows 后端

入口通过 `main.zig` 在编译期组合 `Disk` 和 `Sessions`；业务规划、审批摘要、
执行顺序、取消及逐步核对沿用跨平台代码。Windows 目标不导入 Linux C 头，也不链接 libblockdev。

## 构建

使用 `.zigversion` 指定的 Zig 0.17.1。Windows 原生构建执行 `zig build -Dwindows-lld=true`；
Linux 上执行 `zig build compile -Dtarget=x86_64-windows-gnu -Dwindows-lld=true` 只编译主程序和宿主测试。
这是当前固定工具链下已验证的构建组合，原因见下方核查；并非 zigwin32 的依赖要求。
窗口需要 WebView2 Runtime，`pizza serve` 提供显式浏览器入口。

zigwin32 由以下命令实际获取，URL 和内容哈希已写入 `build.zig.zon`：

```sh
zig fetch --save=win32 https://codeload.github.com/marlersoft/zigwin32/tar.gz/6f281fc4a9a6135000ba0f9c6792d0c2b8e7acff
```

固定提交 [6f281fc](https://github.com/marlersoft/zigwin32/commit/6f281fc4a9a6135000ba0f9c6792d0c2b8e7acff)
包含 Zig 0.17.0 的适配和 CI 测试，依赖选择以该提交为依据。

### 链接器核查

在 Linux 上使用项目固定的 Zig 0.17.1，以 `x86_64-windows-gnu` 为目标，
移除 zigwin32、WebUI 和应用代码后，以下程序仍能复现原生链接器失败：

```zig
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
pub fn main() void {
    _ = GetCurrentProcessId();
}
```

保存为临时目录中的 `probe.zig`，执行
`zig build-exe probe.zig -target x86_64-windows-gnu` 并追加以下选项：

| 代码生成、链接与增量选项              | 本地结果                                                                        |
| ------------------------------------- | ------------------------------------------------------------------------------- |
| `-fllvm -fno-lld -fincremental`       | 未解析 `memcpy`、`memset`、`___chkstk_ms` 和 Windows 启动路径使用的 NT 系统符号 |
| `-fllvm -fno-lld -fno-incremental`    | 同类未解析符号，关闭增量编译不能解决                                            |
| `-fno-llvm -fno-lld -fincremental`    | 导入库写出失败，另报 `TODO implement saving linker state for coff`              |
| `-fno-llvm -fno-lld -fno-incremental` | 导入库写出失败，切换代码生成后端仍不能完成构建                                  |
| `-fllvm -flld -fno-incremental`       | 成功                                                                            |

完整应用关闭 LLD 时还出现 GNU CRT 和 Win32 导入符号未解析；使用 LLD 可链接主程序及
Windows 宿主测试。因此当前问题定位在工具链的原生 COFF 链接路径，不能归因于某个应用依赖，
也不能简单归因于增量编译。以上诊断尚不能确定所有失败是否来自同一内部缺陷。
Zig 上游仍有[移除 COFF/PE 对 LLD 依赖的跟踪项](https://github.com/ziglang/zig/issues/17751)。

项目保留原生 COFF 默认值，Windows CI 和当前可用构建显式传入 `-Dwindows-lld=true`；
该选项仅设置链接器并关闭相应编译步骤的增量编译，不更换 zigwin32 或系统 API。

## 当前范围

| 场景                                        | 实现                                                                                      |
| ------------------------------------------- | ----------------------------------------------------------------------------------------- |
| 清单                                        | MSFT_Disk / MSFT_Partition / MSFT_Volume，与类型化 GPT 布局、磁盘号、单卷磁盘范围交叉核对 |
| NTFS 缩扩容                                 | MSFT_Partition.GetSupportedSize + Resize；缩容在执行入队前预检，执行时再次检查支持范围    |
| NTFS / FAT / exFAT 标签                     | MSFT_Volume.SetFileSystemLabel；UTF-16 长度、禁用字符及 FAT 大写规则预检                  |
| 格式化                                      | 对已识别的简单数据卷使用 MSFT_Volume.Format，目标 NTFS / FAT32 / exFAT；Force=false       |
| BitLocker                                   | 只检测转换状态；加密、转换中及未知状态都禁写，不解锁、暂停保护或解密                      |
| 新建、删除、移动、复制                      | 暂未开放；新建需要精确保持审批后的 GPT UUID，移动和复制需要维护环境                       |
| MBR、动态盘、Storage Spaces、系统与恢复分区 | 不提供宿主写入能力                                                                        |

只有健康、在线、可写、未加密、范围映射明确的 GPT 基本数据卷才能获得写入能力。
缺少管理员读取权限时可能只能显示磁盘摘要；通过界面的管理员读取入口重新查询完整清单。
加密状态提供程序不可用时保留未知状态，不把“检测失败”当作未加密。
返回成功后仍重新查询实际布局，核对几何、标签、文件系统及不相关分区；失败不重放步骤。

Windows 优先读取 STORAGE_DEVICE_ID_DESCRIPTOR 的设备级 NAA/EUI 标识，按 Linux
维护端相同的 WWID 规则计算身份。其他设备保留包含提供程序 UniqueId / SerialNumber、
GPT 磁盘 GUID、容量和扇区大小的宿主身份，并明确拒绝跨系统维护接管。
重复身份禁写；执行还检查当前路径和全局分区 GUID 的唯一性。

所有产品构建均使用 `build.zig.zon` 的 `pizza_maintenance` 发布包及其中的匹配协议。
构建将镜像摘要编入宿主，并将镜像安装在 EXE 旁；镜像缺失或无效时构建失败。
`pizza request` 接受有界的协议 JSON；`prepare` 持久化审批请求及 ESP 预留文件，
`reboot` 复核审批摘要与固件绑定后设置启动租约，`complete-session` 校验五个身份、
ESP 收据和已恢复的启动设置，保护性保存报告并读回后才删除终态固件绑定。
原始请求绑定仍有效时可撤销尚未获准离线执行的准备；已发布执行清单或终态收据后，
拒绝宿主撤销并交由维护恢复处理。

当前 UKI 未签名，仅允许 Secure Boot 明确关闭或固件明确不实现相应变量的环境；
读取失败、变量不完整或相互矛盾均拒绝。BitLocker 仍不支持。

## 授权与持久会话

UI 以普通权限运行，通过 ShellExecuteExW 的 runas 启动同一程序的 privileged-exec。
当前支持同一管理员账户的 UAC 拆分令牌；普通账户输入另一管理员凭据的跨账户提权会被拒绝。
服务检查授权父进程。具名管道拒绝远程客户端，限定当前用户和 SYSTEM，
以首实例标记排除管道抢占，并双向检查进程 SID、登录会话和可执行文件的卷号/文件 ID。
传输有长度和时间上限；开始发送后丢失响应只提示重新查询状态，不自动重发写盘请求。

执行工作线程独立于连接。服务空闲五分钟后退出，活动写入不会因界面关闭、空闲计时或通信错误
释放其上下文。取消只在步骤边界生效，已经开始的系统操作先完成核对。
记录保存到系统已知目录 ProgramData/Pizza/sessions/用户SID。
目录和文件使用仅 SYSTEM / Administrators 可访问的 ACL，验证打开句柄的所有者与权限，
拒绝重解析点，并保持祖先目录句柄禁止重命名；文件刷盘后原子替换。

## 验证边界

纯能力与 GUID 测试也在 Linux 执行。Windows 的 `zig build check` 另包含只读 WMI 清单、
管道分片/超限、对端凭据以及临时目录的原子记录/权限检查。CI 增加 Windows 原生任务，
下载的 Zig ZIP 使用 `config/toolchain.json` 中的 SHA-256 核验。

### 虚拟磁盘验收

在隔离的 Windows 管理员会话中执行：

```sh
zig build test-windows-image -Dwindows-lld=true --summary all
```

`test/windows-image.zig` 分别创建 1 GiB / 512 字节逻辑扇区和
1.5 GiB / 4096 字节逻辑扇区的动态 VHDX，不接受现成磁盘路径或编号。
通过 CreateVirtualDisk / AttachVirtualDisk 建立短生命周期句柄，以 GetVirtualDiskPhysicalPath
和 IOCTL 磁盘号绑定写入目标；初始化前还要求 RAW、无分区、File Backed Virtual、非系统/启动盘。
不分配盘符，不设置永久挂载；正常退出显式卸载并删除，进程退出也会释放挂载句柄。

测试先建立两个临时 NTFS 卷，通过与 GUI 相同的 `Service.plan`、审批和 worker
调用实际 Windows Disk 后端；分区位置与尺寸从各自容量推导，标签在每次运行时生成，覆盖：

- 无效标签、过小缩容、过期清单和复制请求的写前拒绝。
- NTFS Unicode 标签修改、缩至原长的 3/4 再扩至 5/4，逐次读取并核对 2 MiB 文件的 SHA-256。
- exFAT、FAT32、NTFS 格式化，核对旧文件消失、新文件可写读及文件系统/标签/几何结果。
- 每步使用生产布局后置条件检查，并核对另一卷的数据哈希，防止无关分区被改变。

用例通过正常清单和能力判断进入写入，不伪造“未加密”或绕过 BitLocker 拒绝策略。
运行环境需要可用的 `Win32_EncryptableVolume` 提供程序；Windows Server 若没有此组件，
本用例明确失败，不将所有写入被拒绝当作验收通过。VHDX API 或管理员权限不可用也直接失败。
测试显式启用并在退出时恢复当前进程的 SeManageVolumePrivilege。

Linux 的 Windows `compile` 目标会编译该用例，Windows CI 中单独执行，超时为十分钟。
它不包含 UAC 交互、UI 退出/重连或进程强制中断验收，普通 `check` 不触发虚拟盘写入。

### WinBoat 实测记录（2026-10-28）

在用户的 Podman WinBoat 中实际运行，客体为 Windows 11 专业版，系统版本
`10.0.26200.0`；管理员进程和加密状态检测提供程序均可用。Zig 0.17.0 在 Linux 上
交叉编译，客体直接执行生成的 EXE。debug 和 safe 分别完成一次全套运行：

| 套件            | debug           | safe            |
| --------------- | --------------- | --------------- |
| 纯业务          | 34 通过         | 34 通过         |
| 协议            | 2 通过          | 2 通过          |
| Windows 宿主    | 41 通过、1 跳过 | 41 通过、1 跳过 |
| VHDX 与后置条件 | 8 通过          | 8 通过          |

唯一跳过项是明确限定 Linux 的清单测试。Windows WMI 清单、管道分片与超限、
内核对端凭据、持久记录原子替换与权限拒绝均实际通过；VHDX 用例实际执行了上文的
缩扩容、Unicode 标签、三种文件系统格式化及双卷数据检查，没有跳过写入。
safe 程序的 `pizza.exe inventory` 也成功返回 Windows 清单。

测试程序先复制到 Windows 本地临时目录，从该目录创建 VHDX，避免在 SMB 共享上
运行虚拟盘写入。结束后确认测试目录内遗留 VHDX 为零、挂载的 1 GiB 测试盘为零，
并删除本轮创建的三个客体临时目录。日志保留在开发工作区的
`.zig-cache/winboat-test/*-tests.log`、`*-tests-safe.log`、`results*.json` 和 `cleanup.json`，不提交构建产物。

#### 维护启动全流程

同一 WinBoat 中另接专用 4 GiB GPT 测试盘，固定设备级 WWN 和序列号；
Windows 系统盘不作为分区操作目标。home 共享在测试期间关闭，产物只传入客体临时目录。
宿主 Linux 始终运行。以下均经过真实 UEFI 重启和客体程序执行：

| 流程     | 实测结果                                                                                                                        |
| -------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Accept   | 在原有布局外新增 256 MiB NTFS，卷标 `PizzaFlow2`；离线校验后明确选择保留，自动清理维护分区并返回 Windows，导入 `completed` 收据 |
| Undo     | 以上述五分区布局为基线，新增 128 MiB NTFS；离线校验后明确选择回滚，自动恢复原布局并返回 Windows，导入 `rolled_back` 收据        |
| 中断恢复 | 重复会话胶囊初始化被拦截后保留启动绑定；重新启动仅恢复持久事务，不重放用户操作；返回 Windows 后导入 `rolled_back` 收据          |
| 收据     | 逐项匹配会话、审批计划、物理程序、磁盘及镜像五个身份；再次导入返回相同的受保护报告                                              |

Accept 与 Undo 均核对全部保留分区的 UUID、偏移、长度、类型、属性、槽位、文件系统和卷标；
专用数据文件 SHA-256 均保持 `4331f6fd59299bea143d32f6cd62fad04cda8571f354179a88e380835fcf94e2`。
Undo 后分区数仍为五，无维护分区或本轮新增分区残留。

实际测试补齐了 Windows 保护性 MBR 使用 `0xffffffff` 长度的兼容；
启动租约恢复允许原始 BootOrder 前缀不变时保留固件新发现的尾部启动项；
新一轮 bootstrap 以可回滚写入初始化旧胶囊头，仍拒绝直接覆盖已存在胶囊；
NTFS 创建时传递并校验批准的 Unicode 卷标。完成后只释放本会话的镜像、执行清单和恢复预留文件，
保留小型请求/收据和受保护报告。

更新后的 Windows 原生测试通过：业务 43 项、宿主 58 项（另有 1 项仅限 Linux 而跳过）、
协议 3 项。维护会话回归通过，存储崩溃模型通过 17,340 个执行场景和 4,080 个恢复场景。
PID1 主救援终端另以无磁盘 QEMU 实测，直接取得控制终端、启动 Bash 并响应受控关机；
固定基础镜像仍缺 BusyBox 及新救援工具，九场景救援套件未全部通过，需待新基础镜像发布后复验。

本轮证据保存在 `.zig-cache/winboat-flow/accept-v6.json`、`undo-v6.json`、
`recovery-v5.json`、`native-v6.json` 及相应准备/重启记录。它们是本地验收产物，不提交。
2026-10-30 通过 Windows SSH 再次读取了相同的持久回滚报告；容器重启后专用测试盘已不再挂载。

原生 UI 仍需在普通用户图形会话验收。管理员启动返回 `UiMustRunUnprivileged`；
SSH 管理会话通常位于会话 0，不代表交互桌面，也不能以成功执行后台测试代替窗口验收。

可在 Linux 上导出无需客体安装 Zig 的测试程序：

```sh
zig build stage-windows-tests -Dtarget=x86_64-windows-gnu -Dwindows-lld=true --prefix zig-out/windows-acceptance
# safe 构建另加 -Doptimize=safe
```

将导出目录复制到 Windows 本地工作目录，从该目录运行 `bin/windows-tests/` 下的
`domain-tests.exe`、`protocol-tests.exe`、`host-tests.exe`、`image-tests.exe`。
协议清单及各文件摘要已在构建时嵌入，测试不依赖构建宿主的缓存绝对路径或另行复制协议源码；
临时虚拟盘测试需要前述管理员权限。加入 `-Dheadless=true` 可同时导出无 WebUI 的
`pizza-backend.exe`，用标准输入 JSON 调用 `plan` 和 `request`。

### 无头后端与卷标清理（2026-10-30）

GUI 与 CLI 的编辑均经过纯 Zig 编辑器和 `Service.plan`。原生 VHDX 用例经过相同的
计划生成、审批、后台 worker 和系统磁盘后端，目标限于测试自身持有句柄的临时磁盘。
查询的卷标来自文件系统；新分区默认空卷标，清空卷标保持为空，不再自动填入
“New Partition”、GPT 名称或设备路径。未命名和空闲空间提示只在显示层生成。
中文测试标签在每次运行时生成，并以请求值核对真实读回，不对特定名称作特殊判断。
显式 `?demo=1` 的样例磁盘与 UI 测试夹具仍为展示数据，不进入真实磁盘执行链路。

Windows SSH 管理会话（Session 0）实测：业务 51 项通过，宿主 67 项通过、1 项 Linux
专用检查跳过，VHDX/后置条件/启动规则 32 项通过，协议 2 项通过。无头 CLI 的真实
`inventory → plan → execute → status` 通过；系统盘使用零操作计划，写入验证由临时
VHDX 完成。报告保存于 `.zig-cache/winboat-flow/headless-20261030.json`。

启动项改为从实际固件状态分配空槽；配套维护端读取 `BootCurrent` 并核对认证租约，
不再要求固定 Boot5049。宿主启动规则及维护端 20 项会话测试通过。此前 v6 的实际
重启验收属于旧固定槽实现；新动态槽已于 2026-10-30 使用包含该维护端修复的新 UKI，
在独立 QEMU Windows 副本完成五条实际重启验收：Accept、Undo、verified 后强杀再
Undo/Accept、APPLY 阶段强杀后自动回滚。结果见 `.zig-cache/windows-e2e/run-09/results.json`；
配套入口和环境说明见 [`test/windows-vm/README.md`](../test/windows-vm/README.md)。
不能拿旧 v6 镜像与新宿主配对后宣称通过。

Windows CI 的配置已接入，但尚无该远端 CI 的运行结果。发布前仍需验收 UAC 取消、
界面退出后进度查询、服务中断后的 needs_recheck，以及真实加密/复杂卷拒绝路径。
使用测试 VM 的快照和临时虚拟盘执行这些验收，不以当前宿主的真实磁盘为测试对象。

虚拟盘测试 API 依据：[CreateVirtualDisk](https://learn.microsoft.com/en-us/windows/win32/api/virtdisk/nf-virtdisk-createvirtualdisk)、
[AttachVirtualDisk](https://learn.microsoft.com/en-us/windows/win32/api/virtdisk/nf-virtdisk-attachvirtualdisk)、
[GetVirtualDiskPhysicalPath](https://learn.microsoft.com/en-us/windows/win32/api/virtdisk/nf-virtdisk-getvirtualdiskphysicalpath)、
[Initialize](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/initialize-msft-disk)、
[CreatePartition](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/createpartition-msft-disk)。

API 依据：[Storage Management API](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/windows-storage-management-api-portal)、
[GetSupportedSize](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition-getsupportedsizes)、
[Resize](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-partition-resize)、
[Format](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/format-msft-volume)、
[SetFileSystemLabel](https://learn.microsoft.com/en-us/windows-hardware/drivers/storage/msft-volume-setfilesystemlabel)。
