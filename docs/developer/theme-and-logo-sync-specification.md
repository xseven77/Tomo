# Tomo & TomoGo 主题色与 Logo 跨端联动架构设计方案

## 1. 概述与设计宗旨

本方案旨在打通 **Tomo 桌面端（macOS SwiftUI）**、**TomoGo 移动端（Web 看板 / 原生 App）** 与 **TomoLogo（`g-row.html` 矢量规范）**，实现一套系统级的主题色与 Logo 视觉联动体系。

### 核心设计原则：
1. **按钮黑白极简，交互个性灵动**：
   - 按钮主体填充始终坚持黑白极简风格（`Color.codexPrimary` / `Color.codexOnPrimary`，深色为明亮米白，浅色为极深石墨灰），确保最高的操作辨识度与极客质感。
   - 所有点按涟漪（Material Wave）、卡片微波、状态栏流光以及 Logo 主色，统一接入动态主题重点色（Theme Accent Color）。
2. **多端对等互通，桌面具备绝对主控权**：
   - 手机端与桌面端均具备完整的主题与 Logo 选择能力。
   - 桌面端提供**「多端主题与 Logo 实时联动」总开关**。开启时双端双向秒级同步，关闭时手机端与桌面端保持完全独立的本地配置。
3. **中心区域纯矢量模板（无背景）即插即用**：
   - 从 `g-row.html` 提炼所有中心图形，消除任何外部底板容器与固定颜色，提供以 `viewBox="0 0 100 100"`、`fill="currentColor"` 的透明镂空矢量模板，支持在导航栏、状态栏、Favicon、水标等各种复杂背景中随处使用。

---

## 2. Logo 家族体系与孪生配对模型

根据 `g-row.html` 规范，桌面端与移动端建立严格的家族孪生映射：

| 家族代码 | 家族名称 | 桌面端呈现 (Tomo) | 移动端呈现 (TomoGo，带 GO) | 设计语义 |
| :--- | :--- | :--- | :--- | :--- |
| `hex` | 六边形家族 | **G1**（六边形 T） | **G2**（六边形内嵌 GO） | 坚固 Token 印章，硬核工具属性极强 |
| `circle` | 圆形家族 | **G3**（圆形 T） | **G4**（圆形内嵌 GO） | 正圆包容温和，留白均匀，亲和力高 |
| `squircle` | 方圆家族 | **G6**（方圆 T） | **G7**（方圆内嵌 GO） | 苹果 Squircle 现代曲率，对称沉稳 |
| `cloud7` | 7瓣云朵家族 | **G8**（7瓣云朵 T） | **G9**（7瓣云朵内嵌 GO） | 泡芙绒毛触感，小狮子体态感，温暖灵动 |
| `quota` | 源头印章 | **G5**（额度章） | **G5**（额度章） | 经典百分比印章，原始极客源头 |

### 变体维度（Orthogonal Attributes）：
* **T 缺口测试模式（Notch Mode）**：
  * `off`：标准闭合 T 字（`T_STD_CLOSED` / `T_G8_CLOSED`）
  * `on`：右侧 3.6px 留白对称缺口（`T_STD_NOTCHED` / `T_G8_NOTCHED`）
* **填充模式（Fill Type）**：
  * `solid`：纯色填充
  * `gradient`：谐波算法渐变（`vibrant` 鲜亮活力 / `subtle` 微光光泽 / `deep` 深邃对比），支持 45°/90°/135°/180°
* **渲染模式（Render Mode）**：
  * `color`：主题色 Logo + 界面点缀
  * `mono`：曜石黑灰 Logo + 底板（极客原石）
  * `inverse`：纯白 Logo + 主题重点色填充底板（彩色 App 图标经典形态）
* **8 款精选预设主题色**：
  1. 经典红橙 `#D74C32`（Tokomi 额度章经典红橙）
  2. 克莱因电蓝 `#2358E8`（AI / 终端科技电蓝）
  3. 伴侣深紫 `#7042E8`（04 伴随屏原版基底紫）
  4. 终端松石绿 `#09866F`（健康配额与运行绿）
  5. 日光珊瑚橙 `#F05A28`（明亮高饱和暖色）
  6. 极光靛青 `#5542E0`（现代生产力工具调性）
  7. 暗夜青绿 `#0E7C86`（数码设备与清爽终端）
  8. 曜石灰黑 `#24272C`（硬核极客实体印章）

---

## 3. 跨端统一数据协议与 API 规范

### 3.1 数据模型（`TomoThemeConfig`）

```typescript
export interface TomoThemeConfig {
  logoFamily: 'hex' | 'circle' | 'squircle' | 'cloud7' | 'quota';
  notchMode: 'off' | 'on';
  fillType: 'solid' | 'gradient';
  gradientAlgo: 'vibrant' | 'subtle' | 'deep';
  gradientAngle: 45 | 90 | 135 | 180;
  accentColor: string;       // 十六进制颜色代码，例如 "#D74C32"
  accentEndColor?: string;    // 渐变终止色
  tileBgColor: string;        // 底板背景色，例如 "#FFFFFF"
  renderMode: 'color' | 'mono' | 'inverse';
  updatedAt: number;          // 时间戳，用于版本竞态消歧
}
```

### 3.2 局域网同步端点（`MobileSyncServer`）

* `GET /api/v1/theme`
  * 返回：
    ```json
    {
      "config": { ... },
      "syncEnabled": true
    }
    ```
* `POST /api/v1/theme`
  * 请求 Body：`TomoThemeConfig`
  * 响应：
    * 桌面端开启联动时：`{ "success": true, "synced": true }`（桌面端已同时生效并广播 SSE）
    * 桌面端关闭联动时：`{ "success": true, "synced": false, "message": "Desktop sync is disabled" }`（手机端本地保存）
* `SSE (/api/v1/events)`：
  * 广播事件：`event: theme_updated\ndata: { "config": { ... } }\n\n`

---

## 4. 桌面端（macOS SwiftUI）落地规范

1. **设置中心（`SettingsViews.swift`）**：
   * 通用设置中引入主题控制卡片：
     * **多端联动开关**：`syncThemeWithMobileEnabled`（布尔值，持久化至 UserDefaults）
     * **Logo 形状选择器**：5 款家族图标预览（六边形、圆形、方圆、云朵、额度章）
     * **T 缺口开关**：闭合 / 缺口
     * **8 色色盘 + 自定义拾色器**
     * **纯色 / 渐变开关**
2. **点按波纹适配（`UsageViews.swift`）**：
   * `CodexMaterialWaveInk` 增加 `.themeAccent` 选项：
     * 深色模式：`Color(hex: config.accentColor).opacity(0.28)`
     * 浅色模式：`Color(hex: config.accentColor).opacity(0.18)`
   * 所有 `CodexPressableStyle` 统一消费该动态波纹，彻底替换写死的薄荷绿。
3. **状态栏与刘海活动流光（`StatusBarController.swift`）**：
   * `StatusCapsuleColorMode` 增加 `.themeAccent` 模式，支持流光与主题色联动。
4. **无背景矢量渲染组件（`TomoMarkView.swift`）**：
   * 采用原生 SwiftUI `Path` / `Shape` 或矢量渲染引擎，直接在关于面板、设置头部呈现动态选定 Logo。

---

## 5. 移动端（TomoGo Web & App）落地规范

1. **设置模态框（`SettingsModal.tsx`）**：
   * 增加外观与主题配置板块：
     * 显示与桌面端对等的 Logo 形状选择（以 G2、G4、G7、G9 等 GO 伴生款展示）
     * 缺口模式切换
     * 主题色拾色器
     * 联动状态指示器（显示「已与桌面端同步」或「独立本地模式」）
2. **CSS 变量动态注入（`index.css`）**：
   * `:root` 动态覆盖注入：
     * `--theme-accent`: 当前主题色十六进制
     * `--theme-accent-wave`: 点按涟漪背景色（带 0.20 透明度）
     * `--theme-accent-grad`: 线性渐变规则
3. **点按涟漪适配（`MaterialWaveLayer.tsx`）**：
   * 默认 `inkColor` 采用 `var(--theme-accent-wave)`。
4. **无背景纯矢量组件（`web/src/components/TomoMark.tsx`）**：
   * 封装 9 款无背景纯矢量图形，接收 `family`、`notch`、`fillType` 与 CSS 样式类名，随主题色响应变色。
5. **顶部导航栏与同步状态栏联动（`WindowHeader.tsx`）**：
   * 替换旧图标为无背景 `<TomoMark />` 实例。

---

## 6. 验证与测试规范

1. **桌面端单测与验证**：
   * 运行 `./package_local.sh` 编译并运行桌面端，切换 Logo 家族、缺口开关与主题色，验证主界面头部、设置页、点按波纹是否即时更新。
   * 验证开关关闭时，手机端 POST 无法更改桌面端状态。
2. **移动端单测与验证**：
   * 运行 `pnpm test` 与 `pnpm build`，验证无类型报错与构建异常。
   * 模拟断网与配对连接，验证 localStorage 本地持久化与 SSE 实时同步。
3. **跨端联动测试**：
   * 桌面端改动，手机端在 50ms 内无刷新平滑变化。
   * 手机端改动，桌面端主窗口与设置页实时同步。
