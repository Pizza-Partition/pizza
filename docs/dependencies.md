# 依赖与发布

项目拆成两个仓库：

- [pizza-bundle](https://github.com/Pizza-Partition/pizza-bundle) 维护第三方运行环境的构建、测试和发布。
- [pizza](https://github.com/Pizza-Partition/pizza) 维护业务程序和界面，将应用层加入已发布的可信基础镜像。

`pizza-bundle` 使用固定 digest 的官方 Arch 容器和指定日期的包快照。
pacman 负责签名验证、递归依赖解析与安装，patchelf 负责解释器和搜索路径，dracut 负责基础 initramfs，GNU tar/cpio 负责归档。
运行库、动态插件、资源、字体和许可证一同保留；不再自研包解析器、依赖收集器或 ELF 修改器。
发布之前在只包含打包文件的 scratch 容器中运行 ABI/动态加载检查与真实 WPE JavaScript 往返测试。
测试失败不发布。真实 DRM 硬件、sandbox、旧内核矩阵与内存预算需要另外验收。

## 消费固定发布版本

宿主需要锁定的 Zig、Node >=22、npm、curl（归档互操作测试另需 libarchive 的 bsdtar）。前端格式检查另需 clang-format。构建自动下载官方 patchelf 0.19.2 二进制并验证 `config/patchelf.json` 中的 SHA-256；已复现 Ubuntu 24.04 自带 0.18 会破坏当前 Zig ELF 布局，禁止用于应用组装。

```sh
zig build deps
zig build runtime-deps
zig build bundle -Doptimize=safe
zig build all test
```

`config/bundle/release.json` 固定仓库 ID、发布 tag、源 commit，以及基础 initramfs、内核、base.json 的文件名和 SHA-256。
`build/bundle/release.zig` 流式校验 SHA-256，再调用 `build/bundle/sigstore.zig` 离线验签。
ECDSA 签名通过 `std.crypto.sign` 验证；同时验证内置 Fulcio 信任链、证书用途、SCT、
Rekor SET、Merkle inclusion proof 和签名 checkpoint，并将日志绑定到证书、签名和 payload。
签名证书中的仓库 ID、发布 workflow、tag、source commit、signer commit 和 GitHub 托管 runner 必须匹配锁文件；
签名的 in-toto subject 必须包含三个原始产物的摘要。信任根版本及支持格式见 [信任策略](../build/bundle/trust/README.md)。
信任根更新需提交代码审核，不信任随包携带的自定义根；未支持的格式或算法直接拒绝。
验证通过后将原始基础层复制到新目录；不解包或改写基础层。失败会清理临时目录。
签名验证发生在宿主构建阶段，不依赖 GitHub CLI、OpenSSL 或外部 Sigstore 客户端；
下载结束后验签无需网络。RAM 维护环境仍使用已有的镜像摘要校验，并未增加运行时来源验证。
没有跳过验证的生产选项。

消费端 TAR 读写使用 `std.tar.Iterator` / `std.tar.Writer`，gzip 使用 `std.compress.flate`，
Zig 工具链的 XZ 解包使用 `std.compress.xz`。流式打包不把整个基础镜像读进内存，
归档条目排序，mtime/uid/gid 归零，保留普通文件权限与相对符号链接。newc 写入器由应用层和 console 层共享。
工具解包拒绝路径穿越、绝对链接、逃逸链接及符号链接父目录；gzip 解包显式验证 CRC 和原始长度。
固定 nightly 的 XZ 解码器尚未实现数据块校验和，因此只解码已经过完整 SHA-256 锁验证的官方工具链；
它还按块分配内存，XZ 引导并非固定内存流式解压。
CI 首次安装 Zig 时尚无编译器，仍用 runner 自带 tar 解包；获得 Zig 后的消费端归档与压缩均不调用外部命令。

```sh
zig build tools -- fetch-bundle --destination /tmp/pizza-runtime
zig build tools -- bootstrap-patchelf --destination /tmp/pizza-patchelf
zig build tools -- verify-bundle --bundle /tmp/pizza-runtime
zig build tools -- prepare-bundle \
  --runtime /tmp/pizza-runtime --patchelf /tmp/pizza-patchelf/bin/patchelf \
  --init zig-out/bin/pizza-init --maintenance zig-out/bin/pizza-maint \
  --panel ui/execution/gui/dist --destination /tmp/pizza-application
zig build tools -- pack-bundle --bundle /tmp/pizza-application --output /tmp/pizza-application.tar.gz
zig build tools -- image --bundle /tmp/pizza-application --output /run/pizza/maint.img
```

这里的 `verify-bundle` 验证下载目录里的三个原始发布产物与 attestation。
`prepare-bundle` 再次验证产物，创建独立 overlay 目录放入本次构建的程序。
应用目录是本地构建输出，应保持受控；对目录的后续修改不受原始归档的 attestation 保护。
`image` 检查应用布局、静态 PID 1 与内核契约，重新验证基础层来源，然后把原生 newc/gzip 写入器生成的应用层追加到基础 initramfs，不做上游内容审计。

## 布局与版本契约

运行环境可部署到任意目录，镜像默认放在 `/opt/pizza/bundle`。启动前须把工作目录设为 bundle 根。
第三方程序的 `PT_INTERP` 为相对路径 `lib/ld-linux-x86-64.so.2`，RUNPATH 全部相对于 `$ORIGIN`；
Pizza 只为自己刚构建的 `pizza-maint` 设置解释器与 RUNPATH。
`runtime.json` 是 format 3 的运行环境契约；`manifest.json` 在加入本地应用时生成，
记录架构、profile、入口路径和运行环境来源，不含逐文件哈希清单。
整体移动 bundle 不需要重写 ELF。WPE 上游写死的 libexec/resource 路径由 RAM 镜像中的别名适配，
资源环境变量按实际 bundle 根设置；这些别名不属于 bundle 的固定安装前缀。

运行库版本、来源包清单和许可证随包发布。基础 initramfs、内核与 base.json 各自固定摘要并验证同一发布来源。升级时先在 pizza-bundle 发布测试通过的新版本，
再更新本仓库的 release.json。两仓库不存在反向依赖。
旧 format 1/2 原生归档部署接口、collect/prepare/audit 实现和包锁定树已移除。

## 内核与维护镜像

Linux 7.2.11 与匹配的 7.2.11-arch1-1 模块来自同一已验证发布，独立于宿主内核。
`pizza-bundle` 已用 dracut 安装选定模块；`zig build image` 只追加应用层并输出对应内核。签名证明运行环境的来源与完整性，
不证明它可以运行于任意内核、CPU 或显卡。生产交接见 [transition.md](transition.md)。
`test-smoke` 使用独立的静态 PID 1 测试夹具，不代表运行环境发布验收。生产 image 没有开发绕过选项。

旧设计文档中关于本地软件包收集、逐文件清单和手工发行签名的描述已由本设计取代。

未来可启动 ISO 采用 systemd-boot + UKI（x86-64 UEFI），见 [boot-image.md](boot-image.md)。

应用包布局：

```text
pizza-base-x86_64.img    # 上游基础层，保持原始字节
vmlinuz                 # 同次发布的 Linux 7.2.11
base.json / release.json / attestation.json
manifest.json           # 本地应用接口
overlay/
  init
  opt/pizza/bundle/bin/pizza-maint
  opt/pizza/bundle/share/panel/...
  opt/pizza/panel -> bundle/share/panel
```

最终 `maint.img = 基础 initramfs + gzip/newc 应用层 + console 层`。
驱动、固件和系统布局调整都在 pizza-bundle 中发布；Pizza 不再调用 dracut、depmod 或 modprobe。
基础层本身没有 `/init`，不单独宣称可启动。生产者追加测试 init 验收基础层；消费者追加真实程序后做真实 WPE 启动验收。

`build/bundle.zig` 用 `b.addRunArtifact` 接入上述 Zig 工具步骤。`release.zig` 负责来源策略，
`assemble.zig` 负责应用层，`archive.zig` 调用标准归档工具，`tool.zig` 校验并安装构建工具。
已移除 Node bundle 脚本；Node/npm 仍用于前端、格式检查及 CI 首次引导 Zig。
