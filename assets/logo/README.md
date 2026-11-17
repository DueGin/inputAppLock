# InputLock — Logo & Icons（最终版：键盘锁）

> 当前最终方向是第二轮的 **E · 键盘锁**，由用户选定。
> - 第一轮的最终交付（Caret Lock）已整体移到 `archive-r1/`，包括旧的 `AppIcon-r1.icns`。
> - 第一、二轮的概念稿分别在 `concepts/` 和 `concepts-r2/`。

## 设计理念
**键盘就是锁体，锁梁扣在键盘上——你的输入法被锁住了。**

- 键盘（4 个按键 + 空格键）代表"输入"，锁梁代表"锁定"。两个元素合成一个稳重、对称、近似方形的剪影。
- 键盘的按键网格一眼可读。在小尺寸测试中它是第二轮最稳的方向，16/18 px 都清楚。
- 菜单栏三态都从同一个母形派生：
  - **锁定**：键盘锁
  - **密码框英文模式**：锁体里的键盘换成字母 **A**
  - **未启用**：锁梁打开

## 色值
| 名称 | HEX | RGB | 用途 |
|---|---|---|---|
| Jade（主色） | `#0E9F7E` | 14 159 126 | 符号、单色品牌版 |
| Jade Light | `#2BC9A2` | 43 201 162 | App 图标渐变顶部 |
| Jade Deep | `#08795F` | 8 121 95 | App 图标渐变底部 |
| Ink | `#13201D` | 19 32 29 | 字标 |
| White | `#FFFFFF` → `#E6F6F1` | — | App 图标上的锁，带极浅的渐变 |

## 构造
- 画布 256×256，以 4 为单位。
- 锁体 192×112，圆角 32。
- 锁梁半径 48，粗 24。
- 按键 4 个，每个 28×24（圆角 6，间距 12）；空格键 148×24（圆角 8）。
- 小尺寸版（`inputlock-symbol-small.svg`）：锁梁加粗到 32，按键改为 3 个更大的键，间距更宽。用于 ≤32 px 和 App 图标的 16/32 px。
- 字标 "InputLock" 是自绘的几何字母轮廓，不依赖任何字体：笔画 20，x-height 96，大写字母高 132。

## 文件清单
| 路径 | 内容 |
|---|---|
| `inputlock-symbol.svg` | 符号母版（Jade） |
| `inputlock-symbol-black.svg` / `-white.svg` | 单色黑 / 反白 |
| `inputlock-symbol-small.svg` | 小尺寸加粗版 |
| `inputlock-horizontal.svg` | 横版 lockup（符号 Jade + 字标 Ink） |
| `inputlock-horizontal-black.svg` / `-white.svg` | 横版单色 / 反白 |
| `inputlock-stacked.svg` / `-black.svg` / `-white.svg` | 竖版 lockup 及其单色 / 反白 |
| `inputlock-wordmark.svg` | 纯字标 |
| `variants/` | export_variants.py 导出：黑、白、品牌单色、方形、favicon、app-icon 的 SVG 与 PNG（512 / 1200） |
| `app-icon/app-icon-1024.svg` / `.png` | macOS App 图标源：824 px squircle 底板放在 1024 画布上（Big Sur 网格），Jade 渐变加轻投影 |
| `app-icon/app-icon-small.svg` | App 图标 16/32 px 专用源（使用小尺寸版） |
| `app-icon/app-icon-flat.svg` | 扁平无滤镜版，供印刷和审核用 |
| `app-icon/AppIcon.iconset/` | 16/32/128/256/512，每个尺寸 @1x 和 @2x，共 10 张 |
| `../../Resources/AppIcon.icns` | 用 `iconutil -c icns` 生成，已覆盖第一轮版本 |
| `menubar/MenuBarIconTemplate.png` / `@2x.png` / `.svg` / `@2x.svg` | 菜单栏 · 锁定（键盘锁） |
| `menubar/MenuBarIconSecureTemplate…` | 菜单栏 · 密码框英文模式（锁体内是 A） |
| `menubar/MenuBarIconDisabledTemplate…` | 菜单栏 · 未启用（锁梁打开） |
| `presentation/presentation-board.png` / `.html` / `spec.json` | 展示板，含 App 图标、README、网站、浏览器标签、贴纸、社交头像的 mockup |
| `tests/svg-audit.txt` | svg_audit 完整报告 |
| `tests/preview.png` / `.html` | 测试表：尺寸阶梯、16/32/48 px 像素测试、各种背景、单色、灰度、模糊、镜像、旋转、竞品并排 |
| `tests/menubar-states-test.png` | 菜单栏三态测试：@1x/@2x 放大、浅色和深色菜单栏实际尺寸、16 px 缩放 |
| `source/final_e.py` 等 | 生成全部矢量的几何脚本，依赖 `skia-pathops`，可复现、可迭代 |
| `concepts/`、`concepts-r2/`、`archive-r1/` | 往轮概念与第一轮最终交付存档 |

## 集成说明
菜单栏和 App 图标的文件名都与第一轮相同，替换后不需要改代码，打包后会自动使用新图标。

**App 图标**
- Info.plist 设置 `CFBundleIconFile` = `AppIcon`，也可以同时设 `CFBundleIconName` = `AppIcon`。
- 打包时把 `Resources/AppIcon.icns` 拷入 `.app/Contents/Resources/`。

**菜单栏图标**
- 文件名都以 `Template` 结尾，`NSImage(named:)` 会自动把它们当作 template image。
- 手动加载时，请设置 `image.isTemplate = true` 和 `image.size = NSSize(width: 18, height: 18)`。
- 三个状态对应的文件：

  | 状态 | 文件名 |
  |---|---|
  | 正常锁定 | `MenuBarIconTemplate` |
  | 密码框英文模式 | `MenuBarIconSecureTemplate` |
  | 未启用 / 暂停 | `MenuBarIconDisabledTemplate` |

- 18 px 与 36 px 两个尺寸分别按像素网格单独绘制：@1x 是 3 个键，@2x 是 4 个键，这是为了像素对齐，属于刻意的差异。
- 所有可见像素已校验为纯黑 RGB(0,0,0)，只有透明度变化。

## 使用规范
- **留白**：符号四周至少留出一个按键的宽度（锁体宽度的约 1/7）。
- **最小尺寸**：
  - 符号：16 px，≤32 px 时使用小尺寸版
  - 横版 lockup：高度 ≥ 20 px
  - 菜单栏：只使用 template 文件
- **背景**：
  - 白色或浅灰：用 Jade 彩色版
  - 深色或 Jade 底：用反白版
  - 照片上：用 App 图标形态
- **禁止**：
  - 拉伸变形
  - 改成其他色相
  - 给符号加描边或外发光
  - 增减按键数量（小尺寸版除外）
  - 重新排版字标

## 测试结果
**svg_audit 得分（全部无 FAIL）**

| 文件 | 得分 |
|---|---|
| symbol / wordmark | 100 |
| small / horizontal / stacked | 99 |
| 菜单栏 6 个 SVG | 99–100 |
| app-icon-flat | 92，仅"锚点多"：squircle 用的是高密度多边形 |
| app-icon-1024 | 67 |

app-icon-1024 的扣分来自渐变、投影滤镜和低对比，这些都是 App 图标有意的效果。这个文件只用来生成 PNG，不作为 logo 母版。

**菜单栏图标**
- 三态在 18/36 px 的浅色和深色菜单栏上都可以区分：
  - 键盘网格：锁定
  - 字母 A：密码框英文模式
  - 右移打开的锁梁：未启用
- 缩放到 16 px 仍可辨认。
- 迭代中做过两处修正：
  - 密码框英文模式 @2x 的 "A" 中间那个小三角形的孔原本几乎闭合，已改窄笔画把它打开。
  - 未启用状态的锁梁原本和锁定状态区别不明显，已右移并加大与锁体的间隙。

**单色、反白、灰度、模糊、镜像、旋转**：全部通过。

**还没做**：商标检索和反向图片搜索需要人工完成。
