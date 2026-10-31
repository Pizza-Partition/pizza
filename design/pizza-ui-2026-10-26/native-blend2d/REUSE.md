# 原版披萨代码复用入口

这里是从用户指定的 `~/Documents/ChatGPT/New project 3/native-blend2d` 原样复制的关键代码、运行入口、字体和构建配置。`SOURCE-MANIFEST.json` 与 `SHA256SUMS` 记录了每个原始文件的校验值。源文件没有重新绘制、改色或简化。

## 关键文件

| 文件 | 应复用的内容 |
| --- | --- |
| `src/artwork.cpp` | `recipes` 的八套配方、`wedge` 的披萨形状、`topping` 的十二种食材路径、`sliceArt` 的饼底与细节、`makeIngredient` 与 `Artwork::bake` 的食材体积和光照纹理、`Artwork::image` 的渲染缓存 |
| `src/artwork.hpp` | 配方、绘制接口和 Artwork 类 |
| `src/dough.hpp` | 饼边鼓起、烘烤纹理及厚度，供表面、切边和投影共同使用 |
| `src/relief.cpp` / `.hpp` | 配料高度场、视差、遮挡与阴影 |
| `src/renderer.cpp` | `sliceAt` / `world` 的切片布局，`Renderer::shadow` 的软阴影，`Renderer::scene` 的切边厚度和最终合成 |
| `src/renderer.hpp` | 原版 Renderer 和布局接口 |
| `src/reveal.hpp` | 正面与侧面一致的显色规则 |
| `src/timeline.hpp` | 动画展开、旋转、抬升、显色和完成状态 |
| `src/main.cpp` | 原版可运行入口，包括窗口运行和无窗口 PNG 导出 |
| `xmake.lua` | 原版固定版本依赖与构建配置 |
| `assets/fonts/` | 原版 Cormorant Garamond、DM Sans 及各自 OFL 许可 |
| `tests/` | 构建配置引用的两份原版测试 |
| `output/complete.png` | 原版现成的完整披萨界面参考 |
| `output/toppings/after.png` | 原项目增强材质后的现成渲染参考 |

## 直接运行原版

此目录保留了原项目构建所需的源文件布局。具体环境要求、参数和依赖版本见旁边原样复制的 `README.md` 与 `xmake.lua`。第三方源码、缓存和平台二进制未放进素材包；首次构建可能需要下载依赖。

```sh
# 在解压后的 native-blend2d 目录中运行
xmake f -y -m release
xmake -y
xmake run otto

# 原版完整画面的 PNG 导出，包含原版界面
xmake run otto --render output/export-complete.png --time 34.8 --paused
```

现成参考图及上述导出都是完整界面，未声称是去掉背景的披萨贴图。

## 移入 Pizza 前端时

要保留相同的配料、饼边、体积光照和阴影，应复用完整绘制链：`Artwork` → `ReliefField` / dough → `Renderer::scene` / `shadow`。只复制 `topping` 的二维路径，会缺少原版的体积光照效果。

原版前端之外的 SDL 窗口和展示用文字可以按产品需要替换；披萨绘制链保持一致即可继续使用原版披萨。

界面状态与原版演示时间轴要分开处理：

- 欢迎和完成界面：每个切片的 reveal 为 1，整片合成透明度为 1。
- 编辑界面：选中的切片透明度为 1；只对未选中切片整体降低透明度，连同该片的切边一起处理。
- 不要直接用原演示中“尚未显色”的时间轴状态来表示欢迎页或完成页。
- 编辑页实际分区大小由容量比例决定；原版固定八片的展示布局不能直接代表任意磁盘分区容量。

这些是复用时的接入说明；本目录保留的原始源码未应用上述产品逻辑修改。

## 与本素材包中 SVG 的区别

`../icons/pizza-eight-recipes.svg` 和 `../icons/pizza-edit-selection.svg` 是上一轮的简化示意插画，与原版并不相同。要使用用户指定的原版披萨，请以本目录的源码和渲染参考为准。

原版披萨是矢量食材与栅格化高度场光照结合的原生渲染结果，不能把两幅简化纯 SVG 称为原版的等价导出。素材包中的十二个线描 SVG 图标仍可作为磁盘列表、按钮和页头素材使用。
