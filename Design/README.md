# UPasswords · macOS 设计稿管线

本目录维护 UPasswords macOS 客户端的高保真设计稿（v1 Aurora Indigo 设计系统）。

## 产物

| 文件 | 说明 |
|---|---|
| `UPasswords-macOS-all-ui.svg` | **唯一主源**。3600×10300 画板，含 9 个主窗口 + 03–06 区块（首次运行、全部偏好页签、全部弹窗、系统状态）+ 设计令牌 |
| `UPasswords-macOS-All-UI.sketch` | 暗色主题 Sketch 文件（由 SVG 导入生成，图层已命名） |
| `UPasswords-macOS-All-UI-Light.sketch` | 浅色主题 Sketch 文件（由暗色文件调色板重映射生成） |
| `Previews/` | 重设计前后对比渲染图（由 sketchtool 导出） |

## 管线（修改设计后按顺序执行）

```bash
cd Design

# 1. 编辑主源 SVG（9 个主窗口分组 id/transform 必须保持稳定，
#    name-sketch-layers.mjs 依赖它们重命名图层）

# 2. 追加/重建 03–06 区块（幂等：区块由 COMPLETE-UI-APPENDIX-START/END 标记包裹，
#    重跑前先剥离再重挂；同时兼容旧版无标记布局）
node extend-all-ui.mjs

# 3. 用 Sketch 导入 SVG 并保存为 .sketch（AppleScript）
osascript <<'AS'
tell application "Sketch"
  activate
  open (POSIX file "/Users/lizhen/Projects/UPasswords/Design/UPasswords-macOS-all-ui.svg")
  delay 8
  set theDoc to front document
  save theDoc in (POSIX file "/Users/lizhen/Projects/UPasswords/Design/UPasswords-macOS-All-UI.sketch")
  close theDoc saving no
end tell
AS

# 4. 重命名 Sketch 导入产生的「编组」图层
node name-sketch-layers.mjs UPasswords-macOS-All-UI.sketch

# 5. 生成浅色主题（调色板重映射；会重建 zip 并保留单一 page 条目）
node create-light-theme.mjs
```

## 设计令牌（暗色 Aurora Indigo）

- 画布 `#0d1017 → #08090e`；窗口 `#171b28 → #10131c`（边框 `#283049`，圆角 14）
- 标题栏/工具栏 `#181c2a`；侧栏 `#10131c → #0e1018`，选中胶囊 `#252c42`（选中行描边 `#4f5bd5`）
- 卡片 `#1a1f2e`；次级按钮 `#20263a`（边框 `#2f3854`）；输入框 `#0e111a`（边框 `#2c3450`）
- 分隔线 `#242b3d`/`#252c3e`；边框 `#283049`/`#313a56`
- 文本：主 `#f2f5fc`/`#e7ecf7`，次 `#8f99b3`/`#7e88a3`，弱 `#5a6480`
- 主 CTA：靛蓝渐变 `#818cf8 → #6366f1` + 白字（渐变 id 仍为 `whiteBtn`，引用兼容）
- 头像渐变 `#8f9bf9 → #6366f1`（id `avatarGrad`）；开关开启态同 CTA 渐变
- 强调/链接 `#818cf8`；成功 `#34d399`；警告 `#fbbf24`；危险 `#f87171`
- 氛围光晕：画布左上 `#6366f1` @10%、右下 `#8b5cf6` @5%；锁屏背景 `#1b2140 → #12162a → #0a0c14`
- 标签点缀：工作 `#7dd3fc` / 个人 `#c4b5fd` / 财务 `#fcd34d`
- 交通灯保留 macOS 标准色 `#ff5f57` / `#febc2e` / `#28c840`

浅色映射表见 `create-light-theme.mjs` 顶部 `palette`（蓝调浅色中性色 + 加深一档的靛蓝 `#4f46e5`）。

## 迁移脚本

- `redesign-aurora.mjs`：2026-10 从 Graphite Monochrome 迁移到 Aurora Indigo 的一次性脚本
  （上下文替换渐变/头像/光晕/CTA + 41 色全局重映射 + tokens 区块重写）。幂等；对已是
  新配色的画板执行为无操作，保留用于审计与再次验证。

## 注意

- ⚠️ `normalize-theme-consistency.mjs` 已**废弃**（内置旧蓝灰配色映射，运行会破坏新稿），请勿执行。
- `UPasswords-macOS.sketch` 为旧版留存，不在管线内。
- 浅色文件的 `previews/preview.png` 由 Sketch 打开保存后自动刷新。
- 渲染预览：`sketchtool export artboards <file>.sketch --output=<dir> --export-page-as-fallback=YES`
  （`sketchtool` 位于 `/Applications/Sketch.app/Contents/MacOS/`）。
