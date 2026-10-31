"""Build original, editable pizza vector assets and a local review gallery.

Standard library only. All illustrations are drawn as SVG geometry.
"""
from pathlib import Path
import math
import html
import json

ROOT = Path(__file__).resolve().parent
ICONS = ROOT / 'icons'
ICONS.mkdir(exist_ok=True)
SVG_NS = 'http://www.w3.org/2000/svg'
items = []


def save(name, label, body, *, size=64, colored=False):
    attrs = '' if colored else ' fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"'
    svg = f'<svg xmlns="{SVG_NS}" viewBox="0 0 {size} {size}" width="{size}" height="{size}" color="#A43F2C" role="img" aria-labelledby="title"><title id="title">{html.escape(label)}</title><g{attrs}>{body}</g></svg>\n'
    (ICONS / f'{name}.svg').write_text(svg)
    items.append(dict(name=name, label=label, body=body, size=size, colored=colored))


def leaf(x, y, s=1, rotation=0, fill='none', stroke='currentColor'):
    return f'<g transform="translate({x} {y}) rotate({rotation}) scale({s})"><path d="M-4 5C-8-1-3-7 5-6C8 1 2 7-4 5Z" fill="{fill}" stroke="{stroke}"/><path d="M-5 6 4-5M-1 1-3-2M1-1 4-1" fill="none" stroke="{stroke}" stroke-width=".85"/></g>'


def mushroom(x, y, s=1, rotation=0, fill='none', stroke='currentColor'):
    return f'<g transform="translate({x} {y}) rotate({rotation}) scale({s})"><path d="M-6 0C-7-9 7-9 6 0Q3 2 2 0L2 6Q0 8-2 6L-2 0Q-4 2-6 0Z" fill="{fill}" stroke="{stroke}"/><path d="M-4-1Q0-4 4-1" fill="none" stroke="{stroke}" stroke-width=".85"/></g>'


def pepperoni(x, y, r=3.4):
    return f'<circle cx="{x}" cy="{y}" r="{r}"/><path d="M{x-1.1} {y-1.2}h.01M{x+1.3} {y+.3}h.01M{x-.6} {y+1.5}h.01" stroke-width="1.1"/>'


def disk(recipe='plain', cx=32, cy=32, r=26):
    # Six radial cuts stop on the inner crust ring; toppings sit between cuts.
    body = f'<circle cx="{cx}" cy="{cy}" r="{r}"/><circle cx="{cx}" cy="{cy}" r="{r-4}" stroke-width="1.2"/>'
    for a in range(30, 360, 60):
        t = math.radians(a)
        body += f'<path d="M{cx} {cy} {cx+(r-4)*math.cos(t):.3f} {cy+(r-4)*math.sin(t):.3f}" stroke-width="1.15"/>'
    if recipe == 'classic':
        for a in (0, 120, 240):
            t=math.radians(a)
            body += pepperoni(cx+14*math.cos(t), cy+14*math.sin(t))
        for a in (60, 180, 300):
            t=math.radians(a)
            body += leaf(cx+14*math.cos(t), cy+14*math.sin(t), .47, a-40)
    elif recipe == 'funghi':
        for a in (0, 120, 240):
            t=math.radians(a)
            body += mushroom(cx+14*math.cos(t), cy+14*math.sin(t), .6, a-10)
        for a in (60, 180, 300):
            t=math.radians(a)
            body += f'<circle cx="{cx+14*math.cos(t)}" cy="{cy+14*math.sin(t)}" r="2.8"/>'
    elif recipe == 'garden':
        for a in (0, 120, 240):
            t=math.radians(a)
            body += leaf(cx+14*math.cos(t), cy+14*math.sin(t), .65, a-20)
        for a in (60, 180, 300):
            t=math.radians(a)
            x,y=cx+14*math.cos(t),cy+14*math.sin(t)
            body += f'<ellipse cx="{x}" cy="{y}" rx="3" ry="3.7"/><ellipse cx="{x}" cy="{y}" rx="1" ry="1.5" stroke-width=".8"/>'
    return body


# Compact identity mark: sufficiently sparse for a toolbar or app header.
mark='<circle cx="32" cy="32" r="25"/>'
for a in range(0,360,45):
    t=math.radians(a)
    mark+=f'<path d="M{32+4*math.cos(t):.2f} {32+4*math.sin(t):.2f} {32+22*math.cos(t):.2f} {32+22*math.sin(t):.2f}" stroke-width="1.4"/>'
mark+='<circle cx="32" cy="32" r="2" stroke-width="1.25"/><circle cx="39" cy="18" r="1.3" fill="currentColor" stroke="none"/><circle cx="20" cy="39" r="1.3" fill="currentColor" stroke="none"/>'
save('pizza-mark', '品牌标记 · 八瓣披萨', mark)
save('pizza-disk-classic', '磁盘图标 · 番茄罗勒', disk('classic'))
save('pizza-disk-funghi', '磁盘图标 · 蘑菇', disk('funghi'))
save('pizza-disk-garden', '磁盘图标 · 蔬菜', disk('garden'))

slice_shape='<path d="M12 13Q32-3 52 13L34 54Q32 58 30 54Z"/><path d="M15 20Q32 6 49 20"/>'
save('pizza-slice', '单片披萨 · 意式腊肠', slice_shape+pepperoni(25,25,3.7)+pepperoni(39,24,3.4)+pepperoni(32,39,2.7))
save('pizza-slice-basil', '单片披萨 · 罗勒蘑菇', slice_shape+leaf(27,26,.8,-15)+mushroom(38,24,.67,20)+'<circle cx="32" cy="40" r="2.6"/>')
bitten='<path d="M12 13Q32-3 52 13L45 29Q35 24 36 35Q27 33 29 44L34 54Q32 58 30 54Z"/><path d="M15 20Q32 6 49 20"/>'+pepperoni(25,26,3.5)+pepperoni(38,20,2.7)+'<path d="m51 32 2 1m-8 9 2 2"/>'
save('pizza-slice-bite', '单片披萨 · 小咬一口', bitten)

pulled='<path d="M28 35 37.72 14.15A23 23 0 1 0 49.61 27.13Z"/><path d="M28 35 10 20M28 35 8 44M28 35 32 57" stroke-width="1.2"/><path d="M34 29 43.72 8.15A23 23 0 0 1 55.61 21.13Z"/>'+pepperoni(44,18,2.7)+pepperoni(15,34,2.8)+leaf(27,48,.5,-15)+mushroom(27,20,.48)
save('pizza-pull-slice', '拿起一片 · 分区隐喻', pulled)

for suffix,label,symbol in [
    ('add','添加分区','<path d="M49 43v12M43 49h12"/>'),
    ('resize','调整分区','<path d="M42 49h14m-11-3-3 3 3 3m8-6 3 3-3 3"/>'),
    ('check','操作完成','<path d="m43 49 4 4 9-10" stroke-width="2.4"/>'),
]:
    body=disk('plain',27,27,22)+'<circle cx="49" cy="49" r="12" fill="var(--pizza-surface, #FAF8F1)"/>'+symbol
    save('pizza-'+suffix,label,body)

mini='<circle cx="12" cy="12" r="9.25"/><path d="M12 12V3.25M12 12 19.6 7.65M12 12l7.6 4.4M12 12v8.75M12 12l-7.6 4.4M12 12 4.4 7.65" stroke-width="1.15"/><circle cx="16" cy="12" r="1"/><circle cx="10" cy="8.5" r="1"/><circle cx="10" cy="15.5" r="1"/>'
save('pizza-disk-24', '紧凑磁盘图标 · 24px',mini,size=24)


def point(r,a):
    t=math.radians(a)
    return 128+r*math.cos(t),128+r*math.sin(t)


def wedge(r,a,b):
    x,y=point(r,a); u,v=point(r,b)
    return f'M128 128L{x:.3f} {y:.3f}A{r} {r} 0 0 1 {u:.3f} {v:.3f}Z'


def colored_pizza(selected=False):
    # Palette and recipe types reference native-blend2d/artwork.cpp.
    cheese=['#EFC685','#F5DDA9','#C8D18B','#F5D277','#F3C7A0','#DE9D66','#F2E3B7','#F1D19A']
    recipes=['pepperoni','mushroom','garden','pineapple','shrimp','pepperoni','cheese','tomato']
    parts=[]
    for i,(color,recipe) in enumerate(zip(cheese,recipes)):
        a,b=-91+i*45+1.2,-91+(i+1)*45-1.2
        mid=(a+b)/2
        selected_here=selected and i==0
        dx,dy=(5*math.cos(math.radians(mid)),-0+5*math.sin(math.radians(mid))) if selected_here else (0,0)
        opacity=' opacity=".28"' if selected and not selected_here else ''
        s=f'<g id="slice-{i+1}" transform="translate({dx:.3f} {dy:.3f})"{opacity}>'
        s+=f'<path d="{wedge(111,a,b)}" fill="#D9A25E" stroke="#9C6839" stroke-width="1.3"/>'
        s+=f'<path d="{wedge(100,a+.4,b-.4)}" fill="#B85B36"/>'
        s+=f'<path d="{wedge(96,a+.6,b-.6)}" fill="{color}"/>'
        x,y=point(106,a+4);u,v=point(106,b-4)
        s+=f'<path d="M{x:.2f} {y:.2f}A106 106 0 0 1 {u:.2f} {v:.2f}" fill="none" stroke="#F2C98D" stroke-width="2.7" stroke-linecap="round"/>'
        for j in range(5):
            x,y=point(105,a+5+j*7)
            s+=f'<ellipse cx="{x:.3f}" cy="{y:.3f}" rx="1.5" ry=".9" fill="#A96C36"/>'
        for j,(rad,angle) in enumerate([(43,mid),(73,mid-10),(80,mid+11)]):
            x,y=point(rad,angle)
            if recipe in ('pepperoni','tomato'):
                s+=f'<circle cx="{x:.3f}" cy="{y:.3f}" r="8" fill="#B94D35" stroke="#923925" stroke-width=".7"/><circle cx="{x:.3f}" cy="{y:.3f}" r="6" fill="none" stroke="#EB9D68" stroke-width=".7"/>'
                for k in range(3):
                    t=math.radians(k*120)
                    s+=f'<ellipse cx="{x+3*math.cos(t):.3f}" cy="{y+3*math.sin(t):.3f}" rx=".8" ry="1.2" fill="#F3CB87"/>'
            elif recipe=='mushroom':
                s+=mushroom(x,y,1,angle+90,'#FFF0CC','#9F774F')
            elif recipe=='garden':
                s+=f'<ellipse cx="{x:.3f}" cy="{y:.3f}" rx="6" ry="7.4" fill="#4A5330"/><ellipse cx="{x:.3f}" cy="{y:.3f}" rx="2.7" ry="3.8" fill="{color}"/>'
            elif recipe=='pineapple':
                s+=f'<g transform="translate({x:.3f} {y:.3f}) rotate({angle})"><path d="M-6-6 6-5 7 5-5 7Z" fill="#F5D15B" stroke="#C49735" stroke-width=".8"/><path d="M-3-3 4 3M3-3-3 4" stroke="#D9AA3E" stroke-width=".8"/></g>'
            elif recipe=='shrimp':
                s+=f'<g transform="translate({x:.3f} {y:.3f}) rotate({angle})"><path d="M5-4C-1-12-12-3-7 5C-2 13 9 7 7 2C5-2 1-1 1 2C3 7-5 5-3 0C-2-4 2-3 4-1L9-5 9-8Z" fill="#EDA47A" stroke="#C77C56" stroke-width=".65"/><path d="M-6-2-2 0M-6 3-2 3M-2 7 0 4" fill="none" stroke="#FFE2BA" stroke-width="1.2"/></g>'
            else:
                s+=f'<path d="M{x-5:.2f} {y-4:.2f}q6-7 11 0 5 7-4 9-9 1-7-9Z" fill="#FFF3CD" stroke="#CCB780" stroke-width=".6"/>'
        if recipe in ('pepperoni','tomato','garden','shrimp'):
            x,y=point(65,mid+7)
            s+=leaf(x,y,1,mid+30,'#6C803D','#4C622C')
        if recipe=='pineapple':
            x,y=point(60,mid+13)
            s+=f'<path d="M{x-5:.2f} {y-4:.2f}q7-3 10 1l-1 8-10-1Z" fill="#D99181" stroke="#B76D62" stroke-width=".7"/>'
        if selected_here:
            s+=f'<path d="{wedge(114,a,b)}" fill="none" stroke="#A43F2C" stroke-width="1.8"/>'
        s+='</g>'
        parts.append(s)
    return ''.join(parts)


save('pizza-eight-recipes', '简化示意 · 全部实色（非原版导出）', colored_pizza(),size=256,colored=True)
save('pizza-edit-selection', '简化示意 · 编辑状态（非原版导出）', colored_pizza(True),size=256,colored=True)

# Self-contained vector contact sheet; can be rendered with rsvg-convert.
sheet=[f'<svg xmlns="{SVG_NS}" width="1200" height="1100" viewBox="0 0 1200 1100"><rect width="1200" height="1100" fill="#FAF8F1"/><text x="52" y="65" fill="#A43F2C" font-family="Georgia,serif" font-size="38">Pizza. / Vector ingredients</text><text x="53" y="97" fill="#8D7A69" font-family="sans-serif" font-size="13" letter-spacing="2">12 LINE ICONS + 2 SIMPLIFIED EXAMPLES / ORIGINAL CODE INCLUDED</text>']
for i,item in enumerate(items[:12]):
    col,row=i%4,i//4
    x,y=52+col*288,135+row*180
    sheet.append(f'<rect x="{x}" y="{y}" width="270" height="162" rx="12" fill="#FFFDF7" stroke="#E7DED0"/><g transform="translate({x+99} {y+22}) scale({72/item["size"]})" color="#A43F2C" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">{item["body"]}</g><text x="{x+135}" y="{y+130}" text-anchor="middle" fill="#725D4C" font-family="sans-serif" font-size="14">{item["name"]}</text>')
for i,item in enumerate(items[12:]):
    x=120+i*560
    sheet.append(f'<g transform="translate({x} 710) scale(1.1)">{item["body"]}</g><text x="{x+140}" y="1035" text-anchor="middle" fill="#725D4C" font-family="sans-serif" font-size="17">{item["name"]}</text>')
sheet.append('</svg>')
(ROOT/'previews'/'icon-sheet.svg').write_text(''.join(sheet))

frames=json.loads((ROOT/'generation.json').read_text())
titles=['01 · Welcome','02 · Select a Disk','03 · Slice Your Disk','04 · Review & Confirm','05 · All Set!']
frame_html=''.join(f'<figure><a href="keyframes/{f["file"]}.png"><img src="keyframes/{f["file"]}.png" alt="{title}" loading="lazy"></a><figcaption>{title} <a download href="keyframes/{f["file"]}.png">PNG ↓</a></figcaption></figure>' for f,title in zip(frames,titles))
icon_html=''.join(f'<a class="icon" download href="icons/{item["name"]}.svg"><img src="icons/{item["name"]}.svg" alt="{item["label"]}"><span>{item["name"]}</span><small>{item["label"]} · SVG ↓</small></a>' for item in items)
gallery='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Pizza · 关键帧与矢量素材</title><style>
*{box-sizing:border-box}body{margin:0;background:#FAF8F1;color:#40372F;font-family:system-ui,sans-serif}main{max-width:1360px;margin:auto;padding:48px 32px}h1,h2{font-family:Georgia,serif;font-weight:400;color:#A43F2C}h1{font-size:56px;margin:0 0 12px}h2{font-size:34px;margin-top:56px}p{line-height:1.8;color:#867564}a{color:#A43F2C}figure{margin:32px 0;border:1px solid #E7DED0;background:#FFFDF8}figure img{display:block;width:100%;height:auto}figcaption{padding:16px 20px;display:flex;justify-content:space-between}.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px}.icon{display:flex;flex-direction:column;align-items:center;gap:12px;padding:24px 12px;border:1px solid #E7DED0;border-radius:12px;background:#FFFDF8;text-align:center;text-decoration:none}.icon img{width:96px;height:96px}.icon small{color:#8D7A69}.icon:hover{border-color:#A43F2C}.source{font-size:13px;overflow-wrap:anywhere}@media(max-width:800px){main{padding:24px 16px}.grid{grid-template-columns:repeat(2,1fr)}h1{font-size:40px}}
</style><main><h1>Pizza.</h1><p>五张独立生图关键帧，以及十四份原生 SVG 素材。<br>欢迎页和完成页全部实色；仅第三幕中未选中的披萨分区淡化。第二幕使用简笔披萨图标。</p><p><a href="pizza-ui-assets.zip" download>下载完整素材包 ↓</a> · <a href="generation.json">完整生图提示词</a></p><h2>Original Pizza source</h2><p>已打包用户指定代码库的原版披萨绘制、配料路径、体积光照、阴影及运行入口。<a href="native-blend2d/REUSE.md">查看复用说明</a> · <a href="native-blend2d/output/toppings/after.png">原版渲染参考</a> · <a href="native-blend2d/SOURCE-MANIFEST.json">原样复制校验记录</a>。需要与原版保持一致时，以这份源码为准。</p><h2>Keyframes</h2>'''+frame_html+'<h2>Vector ingredients</h2><p>12 个线描图标采用 currentColor，可修改颜色；2 幅彩色插画是按切片分组的简化示意，与原版并不相同。图标背景透明，添加／调整／完成图标的徽章底色可通过 --pizza-surface 修改。</p><div class="grid">'+icon_html+'</div><h2>Usage</h2><p>磁盘列表推荐 pizza-disk-classic / funghi / garden；24px 小尺寸推荐 pizza-disk-24；页头推荐 pizza-mark。彩色 pizza-eight-recipes 的所有切片均为实色，pizza-edit-selection 专门演示编辑状态。</p><p class="source">图标为本次原创 SVG 绘制；配料类型和暖色方案参考用户指定的 native-blend2d/src/artwork.cpp。界面 PNG 使用内置 image_gen 工具生成，作为视觉关键帧参考。实际实现时，分区角度应由容量计算。</p></main></html>'
(ROOT/'index.html').write_text(gallery)
print(f'Created {len(items)} SVG files, vector contact sheet and gallery.')
