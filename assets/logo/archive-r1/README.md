# InputLock — Logo & Icons

## 设计理念：Caret Lock
**一把锁，锁孔是文本光标（I-beam）——输入被锁住。**

- 锁 = 锁定 / 稳定 / 安心；I-beam 光标 = 输入。两个最直接的符号合成一个形状，一句话讲得清。
- 实心锁体 + 负形光标：在 16–18 px 下仍可辨认，适合菜单栏。
- 同一母形派生菜单栏三态：锁定（光标锁孔）、密码框英文模式（锁孔变成 `•••` 密码点）、未启用（锁梁打开）。

### 概念评审（round 1，见 `concepts/concepts-sheet.png`）
| 概念 | 一句话 | 评价 |
|---|---|---|
| A Keyhole i | 键帽上的锁孔同时是小写 i | 形体好、App 图标感强；**风险：容易被读成"信息 i"图标**，"锁"的含义弱 |
| **B Caret Lock ✔** | 锁孔是文本光标 | 立意最清楚，16 px 仍能看出锁；I-beam 让通用挂锁变得可拥有（ownable）；能自然派生三态 |
| C Locked Toggle | 开关旋钮戴上锁梁 | "切换被锁住"的隐喻最准，但横向构图在方形图标/菜单栏中偏小，16 px 下锁梁变糊 |

Critique 评分（1–5）——B：Idea 5 · Simplicity 5 · Distinction 3（挂锁是常见符号，靠光标锁孔区分）· Memorability 4 · Relevance 5 · Craft 4 · Versatility 5 · Longevity 5 · Colour 4 · Typography 4。

## 色值
| 名称 | HEX | RGB | 用途 |
|---|---|---|---|
| Jade（主色） | `#0E9F7E` | 14 159 126 | 符号、单色品牌版 |
| Jade Light | `#2BC9A2` | 43 201 162 | App 图标渐变顶部 |
| Jade Deep | `#08795F` | 8 121 95 | App 图标渐变底部 |
| Ink | `#13201D` | 19 32 29 | 字标 |

选绿而不选蓝：工具类/安全类图标普遍是蓝色盾牌，玉绿更易区分，同时传达"稳、安心、可用（go）"。

## 字标
"InputLock" 为几何无衬线字母，全部由描边几何构造并转为轮廓（无字体依赖、无授权问题），笔画 20/256，x-height 96，cap 132。

## 文件清单
| 路径 | 内容 |
|---|---|
| `inputlock-symbol.svg` | 符号母版（彩色） |
| `inputlock-symbol-black.svg` / `-white.svg` | 单色黑 / 反白 |
| `inputlock-symbol-small.svg` | 小尺寸版（≤32 px，锁梁更粗、锁孔更大） |
| `inputlock-horizontal.svg` | 横版 lockup（符号 + "InputLock"） |
| `inputlock-horizontal-black.svg` / `-white.svg` | 横版单色 / 反白 |
| `inputlock-stacked.svg` | 竖版 lockup |
| `inputlock-wordmark.svg` | 纯字标 |
| `variants/` | export_variants.py 导出：黑/白/品牌单色/方形/favicon/app-icon SVG + PNG |
| `app-icon/app-icon-1024.svg` / `.png` | macOS App 图标源（824 px squircle 位于 1024 画布，Big Sur 网格；含渐变与投影） |
| `app-icon/app-icon-small.svg` | 16/32 px 专用小尺寸图标源 |
| `app-icon/app-icon-flat.svg` | 扁平无滤镜版（印刷/审核用） |
| `app-icon/AppIcon.iconset/` | 16/32/128/256/512 @1x @2x 全部尺寸 |
| `../../Resources/AppIcon.icns` | `iconutil -c icns` 生成 |
| `menubar/MenuBarIconTemplate(.svg/.png/@2x.png)` | 菜单栏：锁定状态（18×18 / 36×36） |
| `menubar/MenuBarIconSecureTemplate…` | 菜单栏：密码框英文模式（锁孔为 •••） |
| `menubar/MenuBarIconDisabledTemplate…` | 菜单栏：未启用 / 暂停（锁梁打开） |
| `concepts/` | 3 个概念的 symbol/lockup SVG + 概念对比图 `concepts-sheet.png` |
| `presentation/presentation-board.png` / `.html` | 展示板（含 App 图标、README、网站、浏览器标签、贴纸、社交头像 mockup） |
| `tests/svg-audit.txt`、`tests/preview.png` | svg_audit 报告与测试表（尺寸阶梯、16/32/48 px 像素测试、背景、单色、模糊、镜像、旋转） |
| `source/*.py` | 生成全部矢量的几何脚本（需 `skia-pathops`），可复现/迭代 |

## 集成说明（给 App / 打包）
- **App 图标**：把 `Resources/AppIcon.icns` 拷入 `.app/Contents/Resources/`，Info.plist 设置 `CFBundleIconFile` = `AppIcon`（可同时设 `CFBundleIconName` = `AppIcon`）。
- **菜单栏图标**：把 `menubar/*.png`（含 @2x）放进 bundle Resources，或在 SwiftPM 中作为资源。文件名以 `Template` 结尾，`NSImage(named:)` 会自动当作 template image；手动加载时请设置：
  ```swift
  let img = NSImage(named: "MenuBarIconTemplate")   // 或 Bundle.module.image(forResource:)
  img?.isTemplate = true
  img?.size = NSSize(width: 18, height: 18)
  statusItem.button?.image = img
  ```
  状态切换：正常锁定 → `MenuBarIconTemplate`；密码框英文模式 → `MenuBarIconSecureTemplate`；未启用/暂停 → `MenuBarIconDisabledTemplate`。
- 菜单栏 PNG 已校验：所有可见像素 RGB = (0,0,0)，仅 alpha 变化；在深色/浅色菜单栏由系统自动着色。

## 使用规范
- 留白：符号周围至少保留锁体圆角半径（锁体宽度的 1/5）。
- 最小尺寸：符号 16 px（≤32 px 用 small 版）；横版 lockup 高度 ≥ 20 px。
- 背景：白/浅灰用彩色版；深色或品牌色背景用反白版；照片上用反白版或 App 图标形态。
- 禁止：拉伸变形、改色为其他色相、给符号加描边/投影、把光标锁孔替换为普通钥匙孔、重新排版字标。

## 测试结果
- svg_audit：symbol / small / wordmark / 菜单栏 Disabled 100，horizontal / stacked / 菜单栏 锁定·Secure 99，app-icon-flat 92（仅"锚点多"：squircle 为高密度多边形）；app-icon-1024 67——渐变、投影滤镜、低对比为 App 图标有意为之，它只用作栅格化源文件，不作为 logo 母版。
- 小尺寸：菜单栏 18/36 px 按像素网格绘制，锁梁、光标锁孔、密码点均清晰；16 px 图标使用 small 版，锁形可辨（锁梁内孔在 16 px 下会闭合，属可接受）。
- 单色、反白、灰度、模糊、镜像均通过；旋转 180° 无不良读法。
- 未完成项：商标检索与反向图片搜索需由人工完成（挂锁是通用符号，本设计的可识别点在光标锁孔）；概念检查点按任务要求未暂停等待用户选择，由设计角色直接选定 B。
