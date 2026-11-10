# 完整虚拟机验收与发布门禁

`.github/workflows/vm.yml` 实际运行三组矩阵：Linux 512 字节扇区、Linux 4096 字节扇区、
Windows。每组保留原生套件，以及 accept、undo、powercut-undo、powercut-accept、
powercut-apply 全部五场景。`check-results.py` 拒绝跳过原生套件、缺少场景或未通过的报告。
`release.yml` 同时依赖常规 CI 和完整 VM 矩阵；仅编译测试器不满足发布条件。
记录日志的宿主 shell 显式启用 `pipefail`，容器失败必须传递到 job；容器退出后，
runner 还会独立检查最终报告，拒绝失败、缺失或不完整的结果。

每组在独立 GitHub-hosted Linux runner 上使用固定摘要的 Arch 容器和 2026/10/30
软件仓库快照。`ci-environment.sh` 仅在一次性容器中安装工具并切换普通用户；
`ci.sh` 用仓库锁定的 Zig 和维护镜像构建产品、制作新基线并执行矩阵。
这些脚本不配置本机持久化服务、不挂载宿主块设备、不连接已有 libvirt session。

Linux 使用安装内核、最小 mkinitcpio initramfs 和 systemd 根文件系统创建基线。
Windows 从 `test/windows-vm/images.json` 固定大小和摘要的 ISO 全新安装、冻结更新状态，
再创建测试覆盖层。VirtIO 驱动使用官方固定 ISO 中的三份签名文件，范围、大小和 SHA-256
锁定在 `test/windows-vm/virtio.json`，由 `fetch-virtio.py` 校验，无需下载整个驱动 ISO。
任何输入无法验证即失败，不回退到来源不同的镜像或旧本地结果。

UEFI 启动使用正式维护 UKI 原件。测试通过 systemd-stub 的 SMBIOS Type 11 接口选择
串口交互，不修改 UKI 或放松产品的镜像摘要验证。来宾无网卡，所有可写磁盘是当轮创建
的文件或覆盖层。断电通过终止该轮 QEMU 进程实现，不代表所有实体存储掉电行为。

工作流在 main push、PR、手动触发时运行，也可被发布工作流调用。KVM 是必要能力；
GitHub 不保证嵌套虚拟化，runner 缺少 KVM 时明确失败，不跳过、不伪造通过。
Windows job 在一次性托管 runner 中删除不需要的预装 SDK，要求至少 35 GB 可用空间。
若该类 runner 长期无法提供 KVM，应迁移此工作流的 runner 标签，保留相同门禁和测试。

无论成功失败都上传 `vm-*-evidence`：软件版本、构建/基线摘要、输入、事件、串口日志、
原生套件日志、请求/响应、布局和收据验证及最终报告；不上传磁盘镜像或 Windows ISO。
不要把历史本地报告当作当前 CI 的验收结果。

本地入口和环境要求见 [`../linux-vm/README.md`](../linux-vm/README.md) 与
[`../windows-vm/README.md`](../windows-vm/README.md)。本地已有冻结基线可以复用，但
Linux 的导出程序必须与基线摘要一致；修改产品后要重新制作基线。
