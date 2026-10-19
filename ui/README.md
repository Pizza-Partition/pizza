# 界面目录

界面先按使用阶段划分，再按显示方式划分：

```text
ui/
├── partition/             # 正常系统：分区任务的交互与规划
├── execution/             # initramfs：执行期间的状态显示
│   ├── gui/
│   │   ├── host.zig       # WPE 宿主与 JS/native 消息处理
│   │   ├── wpe.zig        # 动态加载 WPE ABI
│   │   ├── src/           # 执行状态、进度和日志网页
│   │   │   └── generated/ # 从 core/proto/contract.json 生成的绑定
│   │   ├── test/          # 网页协议与 bridge 测试
│   │   └── dist/          # 构建产物，不纳入源码
│   └── tui/
│       └── root.zig       # libvaxis 仪表盘与串口文本输出
├── build.mjs              # 网页资源构建入口
├── package.json           # UI 开发工具与 npm 命令
└── package-lock.json
```

`partition` 负责用户选择磁盘、编辑分区操作、查看和确认任务计划；该界面目前尚未实现。
`execution` 负责展示已确定计划的执行进度、日志和故障状态，GUI 与 TUI 使用同一份维护业务状态。

界面代码不负责执行分区操作或持久化 journal；执行器、日志和业务后端位于
`core/maint/`，协议来源位于 `core/proto/contract.json`。
WPE 宿主仍与维护程序处于同一个普通进程，目录拆分不会新增进程或网络通信。

`zig build panel` 构建执行 GUI 到 `ui/execution/gui/dist/`；bundle 将该目录作为
`panel/` 打包，运行时的 panel 路径保持不变。Zig 构建将 GUI 和 TUI 作为独立模块导入维护程序。
