# Otto：Blend2D + SDL3 原生 C++ 实现

本目录独立构建、独立运行，不依赖父目录的 React、Node 或 WebGL。原项目文件未修改。Node 只用于可选的迁移对照测试。

实现了原项目当前的 34.8 秒时间轴、八套配方、手绘食材、透明扇形展开、逐片柔边显色、抬升、厚度、逆时针转动、软阴影、配料滚轮和最终回中。播放/暂停、重播、1/1.5/2 倍速、拖动进度、三个章节和配料弹窗均可使用；支持宽窗口、窄窗口和高 DPI。

## 构建与运行

需要 C++20 编译器、xmake 3.0+ 和 CMake。首次配置会下载并构建固定版本依赖，需要联网。

```sh
cd "/home/perdixky/Documents/ChatGPT/New project 3/native-blend2d"
xmake f -y -m release
xmake -y
xmake run otto
```

`xmake.lua` 固定 Blend2D **0.11.1** 和 SDL3 **3.4.16**，校验下载文件的 SHA-256。Blend2D 使用发行包自带、与该版本匹配的 AsmJit，启用 JIT。两个依赖均不使用系统中碰巧安装的版本。

构建结果位于 `build/<平台>/<架构>/release/`，其中包含程序、SDL3 动态库和本地字体资源。Linux 已配置 `$ORIGIN` 运行时库路径，可以直接运行该目录中的 `otto`。当前已实际验证 Linux x86_64；其他平台尚未实测。

```sh
# 指定初始时刻，暂停查看
xmake run otto --time 6.3 --paused

# 无窗口导出关键帧，不需要显示服务器
xmake run otto --render output/reveal.png --time 6.3 --paused
xmake run otto --render output/mobile.png --time 19.8 --width 480 --height 1100
xmake run otto --render output/ingredients.png --time 19.8 --ingredients

# 放大查看四种配方的食材厚度、遮挡和材质
xmake run otto --render output/toppings/detail.png --toppings-detail --width 1920 --height 1080

# 整段动画的 CPU 渲染性能；--threads 0 为同步单线程模式
xmake run otto --benchmark --width 1920 --height 1080 --frames 300 --report output/benchmark.json
```

键盘：Space 播放/暂停，R 重播，S 倍速，I 配料，Esc 关闭弹窗，左右方向键前后移动一秒，1/2/3 跳转章节，Home/End 跳至首尾，Tab/Shift+Tab 与 Enter 操作控件。

## 渲染与缓存

Blend2D 完成矢量绘制、图像变换、文字和合成；SDL3 负责窗口、输入及最终帧的纹理上传与显示。每帧显示前结束 Blend2D 上下文，确保多线程渲染完成后才读取像素。

- 食材路径、配方纹理、纸张背景和文字排版复用。十二种食材各有独立的轮廓高度表面：香肠卷边、蘑菇帽、橄榄孔洞、弯曲叶片、虾仁分节、菠萝倒角和软芝士分别建模。法线由各自表面的高度差分计算，材质具有独立的粗糙度和高光强度。
- 用视线与高度场求交产生视差、厚度和轮廓遮挡；食材按真实高度向芝士投影并柔化接触阴影。光源保持世界坐标固定，披萨旋转时高光和投影会随之变化。透明边缘采用预乘颜色采样，避免食材边缘出现黑圈。
- 高度求交、光照与投影按八个方向在初始化时烘焙，旋转时连续插值；仅为发生变化的片更新像素。纹理、透明外壳、工作图像和显色坐标缓存合计约 **51.9 MiB**，比原版增加约 8.7 MiB，不随播放时长增长。滚轮字体大小按半像素量化，避免文字缓存随动画无限增长。
- 厚度侧面按真实旋转和高度投影。**正面与侧面共用同一个局部 X 坐标显色规则和 24 单位柔边**；长切边使用屏幕空间渐变，不再根据边缘中点把整个侧面一次显色。渐变使用 17 个采样点近似相同的 smoothstep。
- 抬高食材的显色坐标随表面求交结果更新，以 1/16 单位精度缓存，保持运动中的食材、芝士和侧面显色同步。
- 软阴影采用原项目的两盏区域光、32 + 20 个光源样本，并投影显色部分的顶面和底面。每个光源样本将各片轮廓作为一个非零绕数路径填充，避免同一样本内重叠处重复变暗。阴影在 420×420 的独立缓冲区计算。
- 暂停或完成后等待事件，画面未变化时不持续重绘。

JIT 缓存的是优化后的像素处理代码；应用缓存的是可复用的内容和计算结果，两者互补。

视觉实现保留原设计与动画行为，在当前固定视角下以 2.5D 高度场重现食材体积。顶面光照采用方向插值，透明材质、软阴影和部分装饰有近似处理；布局使用原生坐标系统。原版网页与本程序的具体抗锯齿和字体栅格化也可能不同。

## 验证

```sh
xmake build otto-tests
xmake build otto-relief-tests
xmake test

# 对照父目录当前 TypeScript 时间轴，需要 Node 22.13+
node tools/compare_timeline.mjs

# 无显示器的 SDL3 事件及显示链路测试
SDL_VIDEODRIVER=dummy SDL_RENDER_DRIVER=software xmake run otto --smoke-test

# Linux 的实际 X11 窗口后端测试，需要 Xvfb
xvfb-run -a env SDL_VIDEODRIVER=x11 SDL_RENDER_DRIVER=software xmake run otto --smoke-test
```

已经通过：

- 34,801 个时间轴样本的范围、展开、抬升、对齐、旋转连续性和播放状态测试。
- 19,796 个侧面/正面显色对照，包含长切边上不同位置和两个屏幕方向。
- 独立高度场测试：16 个视线方向的平面求交、超出原始平面轮廓的遮挡、旋转视差、开放孔洞、固定世界光照和高度修正后的显色坐标。该测试同时通过 AddressSanitizer 与 UndefinedBehaviorSanitizer 检查。
- 3,481 个时刻与父项目当前 TypeScript 的 11 个字段对照，误差小于 `1e-9`。
- SDL3 dummy 和 X11 两种后端的按键事件、播放状态、配料弹窗、章节、进度命中、窗口尺寸变化和纹理上传/显示测试。
- `output/` 中 6.0、6.3、6.6 秒的同步显色关键帧、完整披萨、配料弹窗及窄窗口截图的人工视觉检查。
- `output/toppings/` 保存修改前后完整披萨、放大材质图和增强后的显色过渡关键帧。

2026-10-21 在 AMD Ryzen 5 7500F、Linux x86_64、release、Blend2D 4 线程、1920×1080 下，对整段动画均匀采样，预热后测得：

| 实现 / 采样帧数 | 平均 CPU 渲染 | P95 | 最大值 |
| --- | ---: | ---: | ---: |
| 增强前 / 300 | 4.329 ms | 6.794 ms | 8.896 ms |
| 食材体积增强后 / 600 | 4.294 ms | 7.866 ms | 10.007 ms |

初始化从约 0.50 秒增加至约 1.20 秒，换取播放期间复用已烘焙的高度与光照结果。平均帧耗时接近，P95 和最大值略有增加；此测量不能证明新版本更快。测量包含 CPU 绘制及多线程同步，不包含窗口纹理上传、显示和垂直同步，不能直接当成实际窗口 FPS。原始 JSON 位于 `output/toppings/benchmark-before.json` 与 `output/toppings/benchmark-after.json`；其他设备应重新测量。

## 代码入口

| 文件 | 内容 |
| --- | --- |
| `xmake.lua` | 依赖版本、校验、release/debug 与资源复制 |
| `src/timeline.hpp` | 确定性时间轴和播放状态 |
| `src/reveal.hpp` | 正面和侧面共享的柔边显色规则 |
| `src/artwork.cpp` | 八套配方、食材矢量和光照缓存 |
| `src/relief.cpp` | 食材高度场采样、视线求交、轮廓遮挡与投影 |
| `src/renderer.cpp` | 体积投影、阴影、界面及命中测试 |
| `src/main.cpp` | SDL3 事件循环、PNG 导出、性能测试 |

本地字体为 Cormorant Garamond 和 DM Sans，附带各自的 SIL Open Font License。Blend2D 和 SDL3 使用 Zlib 许可证；第三方库由 xmake 从官方发行源获取。
