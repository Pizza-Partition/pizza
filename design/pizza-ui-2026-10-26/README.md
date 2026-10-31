# Pizza 关键帧与矢量素材

## 原版披萨源码

已按用户要求加入 `native-blend2d/`，包含原版绘制、配料、体积光照、阴影、时间轴、运行入口、构建配置、字体许可和现成渲染参考。20 个原始文件逐个通过 SHA-256 核对。复用入口见 [`native-blend2d/REUSE.md`](native-blend2d/REUSE.md)。

下面两幅彩色 SVG 是之前的简化示意，与指定代码库的原版披萨并不相同。需要原版外观时，应直接使用新加入的源码与绘制链。

## 交付内容

- `keyframes/01-welcome.png`：欢迎页，八块披萨全部实色。
- `keyframes/02-select-disk.png`：选择磁盘，磁盘图标改为简笔披萨。
- `keyframes/03-edit-slices.png`：编辑页，只有未选中的披萨分区淡化。
- `keyframes/04-review-confirm.png`：确认页，操作摘要与分区容量。
- `keyframes/05-all-set.png`：完成页，八块披萨全部恢复实色。
- `icons/`：12 个原创线描 SVG 图标，以及 2 幅按切片分组的简化示意 SVG 插画。
- `native-blend2d/`：原样复制的原版关键代码、字体、构建配置与参考图。
- `previews/icon-sheet.png` / `.svg`：全部矢量素材预览。
- `index.html`：本地素材浏览页，直接在浏览器中打开。
- `generation.json`：内置 image_gen 的完整提示词、输入参考路径与原始生成记录。
- `build_assets.py`：使用 Python 标准库重建全部原创 SVG 与素材浏览页。

五张关键帧分别通过内置 image_gen 生图功能生成，使用相同界面风格参考。它们是独立的 PNG 文件，并非从拼图裁切。前四张为 1505 × 1045，最后一张为 1504 × 1046；保留生图原始文件。

## SVG 选用

| 文件 | 用途 |
| --- | --- |
| `pizza-mark.svg` | 页头、品牌标记 |
| `pizza-disk-classic.svg` | 番茄罗勒圆形披萨，磁盘列表 |
| `pizza-disk-funghi.svg` | 蘑菇圆形披萨，磁盘列表 |
| `pizza-disk-garden.svg` | 蔬菜圆形披萨，磁盘列表 |
| `pizza-disk-24.svg` | 紧凑的 24px 磁盘图标 |
| `pizza-slice.svg` | 腊肠单片披萨 |
| `pizza-slice-basil.svg` | 罗勒蘑菇单片披萨 |
| `pizza-slice-bite.svg` | 咬过一口的单片披萨 |
| `pizza-pull-slice.svg` | 分离一片，适合分区隐喻 |
| `pizza-add.svg` | 添加分区 |
| `pizza-resize.svg` | 调整分区 |
| `pizza-check.svg` | 操作完成 |
| `pizza-eight-recipes.svg` | 简化示意：所有切片完全不透明，并非原版导出 |
| `pizza-edit-selection.svg` | 简化示意：选中部分实色，其余 opacity=0.28，并非原版导出 |

线描图标使用 `currentColor`，默认砖红色 `#A43F2C`。内联 SVG 时，可通过 CSS `color` 修改颜色；作为 `<img>` 使用时，可修改 SVG 根元素的 `color` 属性。添加、调整与完成图标的徽章底色可通过 `--pizza-surface` 设置，默认 `#FAF8F1`。其余背景均透明。

彩色插画为原生 SVG 路径，不是嵌入位图。每个切片有独立的 `slice-1` 至 `slice-8` 分组。全部实色版本不含 opacity；编辑示例中只有未选中的切片分组设置 opacity。

## 视觉与容量规则

奶油白 `#FAF8F1`、砖红 `#A43F2C`、暖棕线条、鼠尾草绿、金黄色饼边。配料与颜色参考用户指定的 `~/Documents/ChatGPT/New project 3/native-blend2d/src/artwork.cpp` 和其 `output/complete.png`；用户提供的五幕示意图用于界面风格及流程参考。SVG 为本次原创绘制。

示例容量为 System 200 GB + Data 300 GB + New Volume 150 GB + Free Space 281.5 GB = 931.5 GB。确认页演示将 Data 从 450 GB 调整到 300 GB，再创建 150 GB 的新分区。生成图片用于视觉参考，实际界面的扇区角度应由 `分区容量 / 磁盘总容量 × 360°` 计算。

## 重建

在此目录运行 `python build_assets.py` 可重建 SVG 和 HTML。安装了系统 `rsvg-convert` 时，运行 `rsvg-convert previews/icon-sheet.svg -o previews/icon-sheet.png` 可更新素材预览。
