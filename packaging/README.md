# 安装与分发配置

此目录按平台保存安装与分发所需的源配置，随应用版本管理。
应用代码按职责组织在 `core` 中，界面与图标资源位于 `ui`。

`linux/pizza.desktop` 定义应用菜单入口。Linux 目标执行 `zig build` 时，
构建系统将它和应用图标暂存到 `zig-out/share`，不会写入系统目录。
开发运行使用 `zig build run`，不需要安装桌面入口。

制作发行包时可收集暂存文件：

```sh
DESTDIR=PACKAGE_ROOT zig build -Doptimize=safe --prefix /usr
```

安装、升级与卸载由包管理器或平台安装程序负责。发行包应声明主 README
列出的系统依赖，不复制宿主运行库或文件系统工具。生成的安装包放在构建输出
或 Release 中，不提交到源码仓库。

当前尚未提供 Windows 安装配置；待 Windows 构建与发布流程接通后再加入。
