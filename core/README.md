# 核心代码组织

`main.zig` 负责解析入口和组装平台实现。业务层通过参数使用磁盘与会话能力，
不直接导入 Linux、libblockdev 或 WebUI。

| 目录               | 职责                                                                      |
| ------------------ | ------------------------------------------------------------------------- |
| `app`              | 请求解析、授权路由、计划审批、执行入队与会话状态协调                      |
| `planning`         | 身份与快照摘要、布局编辑、草稿生成与校验、操作归并与执行顺序规划          |
| `execution`        | 逐步执行、布局核对、取消及后台任务所有权                                  |
| `desktop`          | WebUI 窗口生命周期、回调适配与内嵌页面响应                                |
| `platform/linux`   | 系统清单、libblockdev 操作、授权与会话通信、持久记录                      |
| `platform/windows` | WMI/IOCTL 清单、卷能力策略与操作、UAC/具名管道授权、受 ACL 保护的执行记录 |
| `boot`             | 共用的维护状态机、ESP 暂存格式与 UEFI 启动项规则；原生访问放在平台层      |

## 命名规范

- 函数使用 `camelCase`，包括返回类型的工厂函数。
- 编译期值常量使用 `UPPER_SNAKE_CASE`；类型使用 `PascalCase`。
- 局部变量和普通参数使用 `snake_case`；运行期初始化的 Zig 局部 `const` 也遵循此规则。
- 模块命名空间别名使用 `snake_case`，类型别名和 `comptime T: type` 参数使用 `PascalCase`。
- 外部 ABI、第三方 API 和协议字段保留约定名称；JavaScript 解构使用别名区分字段与局部变量。

## 依赖与状态

- `planning` 只依赖标准库和协议包。文件系统标签和操作能力由调用者提供，
  Linux 实现调用 libblockdev，Windows 实现调用系统 Storage Management API；测试使用固定能力替身。
- `execution/runner.zig` 通过传入的 backend 查询、写入和保存进度，
  不导入实际磁盘驱动或会话通信。
- `app/service.zig` 通过 `service(Disk, Sessions)` 组合业务。
  `coordinator.zig` 负责审批后入队、执行前复核和断线状态恢复。
- `desktop/window.zig` 管理窗口、GTK 初始化与平台兼容处理，将请求交给注入的应用服务；
  `asset_response.zig` 统一处理资源查找、响应头与 MIME 类型。CLI 与窗口使用各自的参数类型。
- Linux 的 `session.zig` 管理认证、连接及服务生命周期，`client` 处理授权与请求，
  `store` 处理所有权检查和原子持久记录；存储层不查询工作线程，状态合并由应用层负责。
- Windows 的 `wmi` 只管理 COM 和类型转换，`native` 管理句柄和原生布局，`policy` 是纯能力策略，
  `disk` 复核身份后执行系统方法，`inventory` 内部完成加密状态检测。`session` 管理服务生命周期，子模块分别负责
  UAC 客户端、传输、内核凭据与 ACL、持久记录。平台选择仅发生在 `main.zig`。
- 每个服务实例持有自己的工作线程控制和会话存储。后台任务显式接收应用上下文，
  不再依赖进程级的活动 I/O、用户、请求处理器或执行状态。
  WebUI 无上下文参数的回调仅在窗口适配层保留单窗口绑定。

Linux 原生 C 绑定由 `build/linux/bindings.zig` 按 API 所属库生成，调用处显式导入：

- `libc`：Linux/POSIX 文件、进程、套接字、挂载及 ioctl 接口。
- `libblockdev`：分区与文件系统操作，以及配套的 GLib 错误与内存管理。
- `libblkid`：文件系统签名探测。
- `gobject`：桌面 GTK 属性访问，仅注入 GUI 构建。

libblockdev 的 `GError` 等类型与其函数保留在同一个翻译单元，避免跨 C 绑定的类型不一致。
会话、持久记录和 ESP 访问只导入 `libc`；普通文件镜像测试只需 `libc` 和 `libblockdev`。

平台层不反向导入应用或窗口模块。协议来自固定版本的 `pizza_maintenance` 发布包，
不在本目录重复定义。

`boot/maintenance.zig` 的 `Maintenance(Platform)` 是 Linux/Windows 共用的维护控制器，
统一 prepare/reboot/complete/pending/cancel 的状态转换、待处理记录校验与读回、请求绑定、
启动租约、认证收据导入和清理顺序。`platform/*/maintenance.zig` 仅组合受保护记录、清单、
可信程序路径、原生设备身份、固件访问与重启端口。Secure Boot 缺失变量的解释仍由原生
端口决定，不能因抽取公共层而放宽 Linux 的要求。
`boot/staging.zig` 统一短名称路径、暂存文件名和大小限制、收据封装认证；两个 ESP 原生实现
分别保留挂载/句柄、文件所有权、设备映射复核及实际写入与同步。

辅助函数与其所属状态、策略或边界放在同一模块：会话 ID 校验属于 `execution/worker.zig`，
GUID 转换、分区身份和快照摘要属于 `planning/identity.zig`，请求解码属于 `app/service.zig`。
不为几个辅助函数或纯转发单独拆文件；测试组装入口保留独立文件。

## 验证入口

```sh
zig build test-domain -Dheadless=true # 业务与替身测试，不导入系统 C API 或 WebUI
zig build -Dheadless=true   # 生成 pizza-backend；不构建 WebUI，也不嵌入前端资源
zig build check             # 编译完整应用、运行当前平台与协议测试
zig build test-host-image   # 仅操作临时普通文件镜像的 libblockdev 测试
zig build compile -Dtarget=x86_64-windows-gnu -Dwindows-lld=true # 不运行交叉编译产物
zig build stage-windows-tests -Dtarget=x86_64-windows-gnu -Dwindows-lld=true # 导出 VM 测试程序
# Windows 管理员会话中运行，只写测试自行创建的临时 VHDX
zig build test-windows-image -Dwindows-lld=true
```

独立测试入口、业务替身和镜像测试统一放在 [`test/`](../test/README.md)。
`test/build.zig` 在构建缓存中组织共同的 Zig 模块根目录，解析测试对产品源码的相对导入；
不在 `core` 中放置测试入口或测试专用目录，也不为测试扩大产品 API。

Windows 支持范围和验收边界见 [windows-backend.md](../docs/windows-backend.md)。

## 无 GUI 的编辑与执行接口

`planning/editor.zig` 是无状态的布局编辑器。输入为快照 ID、磁盘身份、可选的上次返回布局，
以及 `resize / add_left / add_right / delete / format / label` 命令。它负责空闲区计算、
扇区对齐、相邻边界检查、GPT UUID/分区身份生成，以及从最终布局推导完整 intents。
分区能力和保护状态来自后端查询，客户端不能通过修改视图中的 capabilities 解锁操作。
`name` 仅表示真实文件系统卷标或用户输入；空卷标保持为空，新分区不自动命名。
GPT 名称、设备路径和“未命名/空闲空间”等显示文字不会填入计划卷标。

`Service.plan` 每次重新查询清单并拒绝过期快照；管理员读取复用已有授权通道。
`review: true` 时，同一份清单上的编辑结果直接进入 planner，返回 `validated` 和审批摘要。
编辑不写盘；`execute / prepare / reboot / complete` 继续通过已有审批、工作线程及维护控制器。

桌面 `pizza_plan` 绑定和 `pizza-backend plan` 使用同一个 `Service.plan`，接收相同 JSON：

```json
{
  "version": 4,
  "snapshot_id": "<inventory 返回的 snapshot_id>",
  "disk_identity": "<目标磁盘 identity>",
  "review": true
}
```

首次省略 `layout` 会从查询结果开始；继续编辑时传回响应中的 `draft.layout`，并添加
`command`，例如 `{"kind":"label","partition_id":"<分区 id>","name":"<用户输入的标签>"}`。
CLI 从标准输入读取，向标准输出写 JSON。执行接口使用 `pizza-backend request`，仍需
传入生成的 `draft` 与对应 `approved_digest`；无 GUI 构建支持相同的提权与维护模式。
直接执行的 CLI 等待工作线程完成后退出，独立 `status` 请求可从持久记录读取结果。
所有产品构建均从固定发布依赖安装维护 UKI，并无条件挂载维护控制器。

GUI 只保留显示、输入单位转换、拖动预览和请求串行化，不生成可执行计划或 UUID。
纯 Zig 测试覆盖编辑、审批、维护准备/重启/收据编排和执行异常；重启控制器使用替身，
不会重启运行测试的机器。Windows 的 `test-windows-image` 使用真实 WMI/IOCTL，经过
相同服务、plan 生成、审批与执行 worker，且每次写入都额外确认临时 VHDX 的句柄所有权。
真实 UEFI 重启和维护系统 Accept/Undo 属于独立 VM 集成验收，不能用替身通过代替。
