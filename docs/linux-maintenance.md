# Linux 维护控制器

Linux 与 Windows 均通过 `core/boot/ports.zig` 的 Controller 接口接入产品请求。
Linux 原生端口位于 `core/platform/linux/maintenance.zig`，与 Windows 共用
`core/boot/maintenance.zig` 的 prepare、reboot、complete、pending、cancel 状态机。
所有构建均启用维护入口；镜像由 `build.zig.zon` 的 `pizza_maintenance` 固定版本及内容哈希，自动获取。

## 平台实现

- 状态存放在 root 管理的 `/var/lib/pizza/maintenance/pending.json`，与按用户隔离的宿主执行记录分开。
  固定锁文件使用非阻塞 flock 串行化跨进程访问；临时文件写入、fsync、rename、目录 fsync 后再读回。
  状态读取拒绝符号链接、非普通文件、额外硬链接、错误所有者、公开权限和不一致的终态收据。
- ESP 必须属于批准计划的目标磁盘，且是唯一的 GPT ESP、FAT32，支持 512/4096 字节逻辑扇区。
  平台锁定磁盘，持有分区设备描述符，在 root 管理的 `/run/pizza-maintenance/` 下建立私有挂载路径。
  每次文件操作核对磁盘身份、设备编号、分区 UUID、类型、偏移和长度。
  已挂载的 ESP 仍需满足 root 所有及不可被其他用户写入的检查，否则拒绝暂存。
- 暂存目录与 Windows 一样使用八段大写十六进制 FAT 短名称。
  镜像、请求、清单、恢复锚点和收据先实际写零预留空间，再原位写入和同步，避免改变后续 FAT 分配证明。
  使用目录描述符和 `openat(O_NOFOLLOW)`；文件和目录均检查类型及写权限。
- 镜像从当前可执行文件旁的 `maint.efi` 读取，核对构建时固定的 SHA-256。
  固件使用现有 efivarfs 后端；Secure Boot 必须明确关闭。
  prepare 发布并读回请求、镜像和受保护状态后才安装请求绑定；reboot 核对批准摘要和绑定后启用启动租约。
- 重启通过固定的 `/usr/bin/systemctl --no-block reboot` 请求 PID 1 正常收尾，使用独立环境，不直接调用内核重启接口。
  因此当前重启入口要求 systemd 主系统。
- complete 核对收据封装、终态固件绑定和会话/计划/程序/磁盘/镜像标识，恢复启动顺序，
  持久化并读回收据后清理固件绑定和大文件预留。重复导入返回同一收据。
  cancel 仅接受尚未进入离线编译/执行阶段的原始请求绑定，并先恢复固件状态。

## 构建与验证

构建自动获取固定版本的维护 UKI 和同一发布包内的协议。只编译、不执行重启：

```sh
zig build compile -Dheadless=true
```

2026-10-30 本地验证：启用维护功能的 Linux `test-host check fmt-check` 通过，共 71 项测试
（宿主 68、协议 3）；默认 Linux `compile` 通过。新增测试覆盖受保护状态原子替换及不安全记录拒绝、
ESP 名称和预留参数拒绝，以及 512/4096 字节扇区请求编码、固件绑定不匹配拒绝、租约恢复及重复 ESP 拒绝。
这些单元测试仅操作临时文件与内存固件替身。

另已完成独立 QEMU/KVM 的 Linux 整机验收：512/4096 字节扇区分别通过 Accept、Undo、
verified 后断电再 Undo/Accept，以及 APPLY 阶段断电恢复，共十个场景。每轮先通过
127 项来宾原生测试，之后验证真实 FAT32 ESP 暂存、固件重启接管、ext4 移动、数据哈希、
布局及幂等收据导入，最后主系统正常关机。复现步骤、报告位置及范围见
[Linux VM 测试](../test/linux-vm/README.md)。

实机流程还发现并修复了 Linux 清单将未分区磁盘误报为 MBR、以及 provider GUID 未转换为
协议 GPT 字节序的问题。ESP 挂载错误现在区分不支持文件系统、权限拒绝和无效 FAT。
