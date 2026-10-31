# Pizza desktop UI

`partition/prototype` 包含桌面界面，普通 `pizza` 程序嵌入并通过 zig-webui 提供页面。
`transport.js` 使用 Zig 绑定调用真实查询、验证和宿主执行；协议 JS 来自独立协议包。
`?demo=1` 保留内存演示，用于外观设计，不会执行磁盘操作。

后端编辑、plan 生成、分区操作和重启编排测试使用 Zig（`zig build test-domain -Dheadless=true`）。
GUI 通过 `pizza_plan` 绑定调用 `Service.plan`，只显示后端布局、转换输入单位并串行发送编辑命令。
Node 测试覆盖显示格式和请求适配，不再承担分区操作规则测试：

```sh
node --test ui/partition/test/live-model.test.mjs
```

完整前端测试使用锁定协议包的 JS 绑定；先运行 `zig build protocol-bindings`，
再执行 `node --test ui/partition/test/*.test.mjs`。
浏览器预览使用 `zig build run -- serve 4182`，与桌面窗口共用同一后端。
特权执行使用同一个 pizza 程序的 `privileged-exec` 模式，由系统授权工具启动。
Linux 桌面菜单入口位于 `../packaging/linux/pizza.desktop`，由 `zig build` 连同图标一起暂存到输出目录。

维护界面和 storage 已迁入 pizza-maint；本仓库不保留维护执行 UI。
