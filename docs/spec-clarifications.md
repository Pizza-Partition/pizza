> 2026-10-19 更新：第三方运行环境由独立 pizza-bundle 流水线通过成熟工具组装、测试、证明来源并发布。
> pizza 通过固定摘要、仓库 ID、workflow、tag 与 commit 验证来源后消费，不再重复审计依赖内容。
> 旧的本地包收集、manifest 文件哈希和原生 bundle 部署要求被 [dependencies.md](dependencies.md) 取代。

# Implementation findings and open spec constraints

2026-10-19 用户已明确修订进程与通信架构：静态 `pizza-init` 监护普通
`pizza-maint`；维护业务、journal 与 WPE 宿主同进程，通过 JS/native bridge
交互，取消 HTTP/SSE。主设计文档已据此更新。以下其他约束继续有效。

用户已明确修订分发方式：第三方包由用户构建时下载，bundle 在本地生成，因此移除
原 spec 的 Pizza 发行签名和公钥要求。继续保留上游固定 SHA-256、文件完整性、
路径/链接/权限检查及编译进程序的组件与版本策略。

1. **原根只读与日志写回原根不能同时成立。** 即使把同一个 ext4 设备再次挂成 rw，
   journal 的底层写入仍会改变原根内容；bind mount 不会提供独立的持久化。可选
   方案是明确允许专用日志区域写入，或改用独立 journal device。外部实验用了独立
   虚拟盘，所以证明了切换与持久化机制，但没有证明原 spec 的 root-path 组合。

2. **自带 glibc 的约束是 bundled symbol versions、CPU ISA 和内核 ABI。**
   正确隔离后，宿主 glibc 的版本不会参与加载。RHEL 8 / Ubuntu 20.04 的旧内核
   仍必须跑矩阵；宿主 libc 版本只是来源信息。外部实验发现本机 glibc 要求
   x86-64-v4，首次 QEMU 启动因非法指令失败。默认 Zig 输出和 ELF 审计因此
   显式采用基线 ISA。最终改用官方 Arch glibc 2.44 的基线包，并通过完整切换实验；
   不需要自编 libc。GNU property note 缺失不等于机器码已被证明兼容；最终
   仍需在基线 VM 中运行。

3. **`dracut --no-kernel` 会省略驱动和 firmware。** 自带宿主模块树需要
   `installkernel` / `instmods`，或分别生成并合并模块 archive。当前打包入口
   使用同一 kernel release 的模块。模块依赖的 firmware 是否来自宿主、如何
   验证和打包，仍需明确，不能仅凭“kernel + modules”保证硬件驱动可用。

4. **nonce 放在 kernel cmdline 无法保证“从不记录”。** Linux 的启动日志和
   `/proc/cmdline` 可暴露它。降低 console loglevel 不能清除 kernel ring buffer。
   可以考虑在 tmpfs 中的 session initrd 注入受保护文件，或设计其他 RAM 交接
   通道。当前 bridge 不使用网络 bearer nonce；旧 HTTP helper 已移除。未来网页执行授权仍需单独设计。

5. **内存预算没有数值。** 应先定义内存上限与统计口径：总进程 RSS/PSS、kernel、
   tmpfs 解压后的 bundle，以及 kexec 前后的双份常驻峰值。外部最小环境中
   `getrusage().ru_maxrss` 返回 0，而 `/proc/self/smaps_rollup` 显示 PID 1 RSS
   112 KiB；0 不能算有效峰值数据。WPE 的预算可行性仍未验证。

6. **“拒绝前无状态变化”与 marker 写入次序需要定义。** 完整性/环境检查失败不应
   留下 staged marker。`kexec_file_load` 拒绝时，应恢复 staged 状态；只有确认
   `kexec_loaded` 后，才能建立可被后续启动解释的 loaded marker。用户会话的
   nonce 不应随 marker 写盘。

7. **日志 header 原先没有定义 padding/byte order/phase 数值。** 当前协议源
   明确 64 字节、小端字段与 offsets。时间线跨 boot 的 UTC anchor、boot id、
   journal home 应放在 boundary payload，不能依赖重新从 0 开始的 monotonic
   时间。JSON/bridge 的 seq 使用十进制字符串，客户端用 BigInt 比较。

8. **原生桥接必须在真实 WPE 中验收。** 前端不再通过网络连接维护程序。
   自检应运行实际本地 panel、JS Promise 请求/回复及 journal 回放，QEMU
   内确认 PID 1 静态、普通应用动态，应用退出不会带走 PID 1。WPE 内部
   renderer/network/GPU 子进程继续存在。桥接自检不等于 DRM、sandbox 或
   真实硬件显示已验收。
9. **缺失输入不会被当成测试成功。** 完整 transition fixture、完整本地 bundle、
   七个 distro image 和 Secure Boot keys 都需要真实输入。现阶段 full-transition
   入口会明确拒绝无夹具运行；矩阵不会下载不明镜像或把 checksum 检查当 ABI 通过。

本次最小实验的源代码、内核副本、initramfs、qcow2、串口记录与报告均在
`/tmp/pizza-transition-feasibility`，不在项目内。实验实际覆盖直接 syscall
`kexec_file_load` 和 `reboot(KEXEC)`；尚未覆盖 systemd 的 orderly-shutdown 路径、
真实 Linux 发行版根、维护 RAM 环境的 WPE/bridge 或 real hardware。另一个独立测试已
用 dracut 111 生成仅含静态 PID 1 的开发镜像并在 QEMU 启动；系统 WPE 2.54.1 的
headless DOM/JS 验证通过。当前实现另有原生桥接 VM 自检：真实 WPE 在 RAM 根中加载本地 panel，完成请求/回复与 134 条 journal 的分批重放；该结果仍不代表 DRM、生产 sandbox 或完整 kexec 往返已通过。

10. **模拟执行的显式边界。** `pizza-maint --execute` 只接受全新的 journal 和 20 个
    simulated step。调用方预先选定并持久化 journal home；应用只检查受支持磁盘文件系统，
    不挂载磁盘，也不替生产系统选择设备。旧 journal 无论完整、失败、挂起或尾部损坏均拒绝重跑。
    同进程 writer 通过已持锁 FD 向 UI 提供 fsync 确认过的前缀，不再次获取自身的文件锁。
    注入 fsync 失败后，重启时可能仍读到有效 intent；这仍保守归类为 `in_flight`，不证明步骤已执行。

11. **生产 journal 的当前选择。** 保留原根只读，要求显式指定独立物理磁盘上的 ext4
    设备及其已建立的私有目录；不写回原根。暂存和加载端核对设备、实际挂载目录、
    UUID、哈希和 boot ID，维护应用在 RAM 根中按 UUID 重新挂载。复杂存储拓扑未支持时
    明确拒绝。生产命令和状态流转见 [transition.md](transition.md)。普通应用负责
    journal 的挂载和业务执行；PID 1 仍只负责初始化、模块加载与监护。
