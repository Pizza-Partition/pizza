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

宿主需要锁定的 Zig、Node >=22、npm、GitHub CLI（支持 `gh attestation verify`）、
GNU cpio/gzip 和 GNU tar（测试另需 libarchive 的 bsdtar）。前端格式检查另需 clang-format。构建自动下载官方 patchelf 0.19.2 二进制并验证 `config/patchelf.json` 中的 SHA-256；已复现 Ubuntu 24.04 自带 0.18 会破坏当前 Zig ELF 布局，禁止用于应用组装。

```sh
zig build deps
zig build runtime-deps
zig build bundle -Doptimize=safe
zig build all test
```

`config/bundle/release.json` 固定仓库 ID、发布 tag、源 commit，以及基础 initramfs、内核、base.json 的文件名和 SHA-256。
`tools/runtime.mjs` 先检查归档摘要，再用 GitHub CLI 验证 attestation 的仓库、
发布 workflow、tag、source commit、signer commit 和 GitHub 托管 runner。
验证通过后将原始基础层复制到新目录；不解包或改写基础层。失败会清理临时目录。
签名验证发生在宿主构建阶段，RAM 维护环境无需 GitHub CLI、网络或 Sigstore 客户端。
没有跳过验证的生产选项。

```sh
node tools/runtime.mjs fetch --destination /tmp/pizza-runtime
node tools/bootstrap-patchelf.mjs /tmp/pizza-patchelf
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
`image` 检查应用布局、静态 PID 1 与内核契约，重新验证基础层来源，然后把 GNU cpio 生成的应用层追加到基础 initramfs，不做上游内容审计。

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
