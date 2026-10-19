# 可启动镜像路线

选定 x86-64 UEFI、systemd-boot 与 UKI，不以传统 BIOS 为目标。
systemd-boot 仅为固件阶段的启动菜单；运行时 PID 1 仍为静态 pizza-init。

两个仓库保持单向依赖。pizza-bundle 用 dracut 将 portable 用户态和匹配模块预装到基础 initramfs，
同时发布固定 Linux 7.2.11（官方 Arch 包 release 7.2.11-arch1-1）。pizza 验证三份产物来源，追加 /init、应用与界面的 newc 层，
通过 `zig build image` 生成 `vmlinuz`、`maint.img` 和镜像 metadata。
生产镜像直接消费随包模块，不要求宿主安装同版本内核。
固件取决于目标硬件；当前内核包不包含 GPU/无线等固件。

必须先完成应用层插入，再组装和签名 UKI；插入程序会改变镜像摘要，不能直接修改已经签名的 UKI。

后续 UKI 将通过 systemd ukify 封装内核、initramfs、OS 标识和启动命令行。
ISO 的 EFI System Partition 使用 FAT 格式，建议布局：

```text
ESP/
├── EFI/BOOT/BOOTX64.EFI       # systemd-boot
├── EFI/Linux/pizza.efi       # kernel + initramfs + cmdline 的 UKI
└── loader/loader.conf
```

ISO 再用 xorriso 加入 UEFI El Torito 引导项。USB 磁盘镜像需要合适的分区表与 ESP，
不能把仅有 ISO 光盘引导项当成已经验证的可写入 USB 的混合镜像。
所有安装/打包操作针对 staging ESP，不能运行会修改当前机器启动项的默认 bootctl 安装。

启动过程：UEFI → systemd-boot → UKI → Linux → RAM 根中的 /init → pizza-maint。
PID 1 进入 bundle 根目录后启动动态程序；相对 PT_INTERP 和 $ORIGIN RUNPATH 保持可移动性。
镜像中 /opt/pizza/bundle 是部署约定，不是第三方包的固定安装前缀。

现有 PID 1 已支持没有 kexec session 时启动 UI。独立 ISO 的磁盘选择和计划编辑界面尚未实现；
持久 journal 也必须由用户明确选择可写存储，不能存入只读 ISO 或易失 RAM 后声称可以恢复。
初版可将全部用户态放入 initramfs；后续依据 RAM 测量决定是否引入 SquashFS。
Secure Boot 需要固件信任的 EFI 签名链，与 GitHub/Sigstore 的产物来源验证是不同环节。

当前发布目标是可供 kexec 使用的内核与维护 initramfs。ISO、UKI、Secure Boot 还未实现，
不能将它们描述成已发布或已经通过硬件验收的功能。

参考：[systemd-boot](https://www.freedesktop.org/software/systemd/man/latest/systemd-boot.html)、
[ukify](https://www.freedesktop.org/software/systemd/man/latest/ukify.html)。
