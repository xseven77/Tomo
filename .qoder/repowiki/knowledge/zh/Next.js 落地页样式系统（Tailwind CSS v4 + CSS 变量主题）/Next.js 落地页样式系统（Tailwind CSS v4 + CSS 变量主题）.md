---
kind: frontend_style
name: Next.js 落地页样式系统（Tailwind CSS v4 + CSS 变量主题）
category: frontend_style
scope:
    - '**'
source_files:
    - app/landing/src/app/globals.css
    - app/landing/postcss.config.mjs
    - app/landing/src/components/ThemeProvider.tsx
    - app/landing/src/components/ThemeToggle.tsx
    - app/landing/src/lib/theme/constants.ts
    - app/landing/src/lib/theme/theme-script.ts
    - app/landing/package.json
---

## 1. 使用的系统与工具
- 框架：Next.js App Router（React 19），使用 pnpm 作为包管理器。
- 样式方案：Tailwind CSS v4（通过 `@tailwindcss/postcss` PostCSS 插件集成），无传统 `tailwind.config.js`，采用 v4 的 CSS-first 配置方式。
- 图标：lucide-react。
- 构建与代码质量：ESLint（eslint-config-next）、TypeScript、PostCSS。

## 2. 核心文件与位置
- 全局样式与主题变量：`app/landing/src/app/globals.css`
- Tailwind 初始化与自定义变体：`app/landing/src/app/globals.css` 中的 `@import "tailwindcss"` 与 `@custom-variant dark (&:where(.dark, .dark *));`
- PostCSS 配置：`app/landing/postcss.config.mjs`（仅启用 `@tailwindcss/postcss`）
- 主题状态管理：`app/landing/src/components/ThemeProvider.tsx`、`app/landing/src/lib/theme/constants.ts`、`app/landing/src/lib/theme/theme-script.ts`
- 主题切换 UI：`app/landing/src/components/ThemeToggle.tsx`
- 依赖声明：`app/landing/package.json`（tailwindcss ^4、@tailwindcss/postcss ^4、next 16、react 19、lucide-react）

## 3. 架构与设计约定
- **CSS 变量驱动的主题系统**：在 `globals.css` 中通过 `:root` 和 `.dark` 两套 CSS 变量定义浅色/深色主题，涵盖背景、前景、边框、卡片、强调色、GitHub 风格配色以及一套以 `--preview-*` 前缀命名的“应用预览”变量，用于在落地页中模拟 Tomo 菜单栏应用的界面。
- **Tailwind v4 内联主题映射**：通过 `@theme inline { --color-background: var(--background); ... }` 将 CSS 变量映射到 Tailwind 的颜色命名空间，使组件类名（如 `bg-background`、`text-foreground`）直接消费这些变量。
- **暗色模式策略**：通过在 `<html>` 根元素上切换 `class="dark"` 并设置 `color-scheme` 实现；同时提供阻塞式内联脚本 `themeInitScript` 在首次渲染前同步应用主题，避免 FOUC。
- **主题状态持久化与系统跟随**：`ThemeProvider` 使用 `localStorage`（key 为 `tomo-theme`）保存用户选择，支持 `light | dark | system` 三种模式；当选择 `system` 时通过 `matchMedia("prefers-color-scheme: dark")` 监听系统主题变化。
- **组件级样式组织**：组件内部大量使用 Tailwind 原子类组合样式，少量通用样式（如 `.glass`、`.grid-bg`、动画 keyframes）集中在 `globals.css` 中复用。
- **无障碍与动效**：对 `prefers-reduced-motion` 媒体查询做了降级处理，禁用浮动、脉冲等动画；主题切换按钮包含完整的 ARIA 属性（`aria-expanded`、`aria-haspopup`、`role="listbox"`、`role="option"`、`aria-selected`）。

## 4. 约定与约束
- **Tailwind 配置方式**：不使用 `tailwind.config.js`，所有主题扩展通过 `globals.css` 中的 `@theme inline` 块完成，符合 Tailwind v4 的 CSS-first 规范。
- **暗色类作用域**：通过 `@custom-variant dark (&:where(.dark, .dark *));` 限定 `.dark` 变体仅在根元素含 `dark` 类时生效，避免污染全局。
- **主题变量命名规范**：基础变量使用语义化名称（`--background`、`--foreground`、`--accent` 等），应用预览相关变量统一以 `--preview-` 前缀区分，便于与页面主题解耦。
- **主题切换入口**：所有主题切换必须通过 `ThemeProvider` 提供的 `setTheme` 进行，禁止直接操作 `document.documentElement.classList`。
- **FOUC 防护**：首屏主题由 `theme-script.ts` 生成的内联脚本在 HTML 头部执行，确保在 React 挂载前已正确设置 `dark` 类和 `color-scheme`。
- **响应式与可访问性**：动画遵循 `prefers-reduced-motion` 降级；交互控件具备必要的 ARIA 标记与键盘支持（Escape 关闭下拉）。

## 5. 与 macOS 原生应用的视觉一致性
- `--preview-*` 变量集专门用于在 Next.js 落地页中复刻 Tomo 菜单栏应用的界面（包括 menubar、panel、sidebar、chrome、card、ticket 等），并在 light/dark 两套变量中分别对齐原生应用的明暗主题，保证产品宣传图与真实应用视觉一致。
