import type { Metadata } from "next";
import Link from "next/link";
import { NotchCompanionDemo } from "@/components/preview/notch/NotchCompanionDemo";

export const metadata: Metadata = {
  title: "刘海屏伴侣 · 布局方案 · Tomo",
  description:
    "刘海屏只在主显示器且为刘海屏时启用，非主屏 / 无刘海机型自动降级原始菜单栏胶囊。多 Agent 并发与多账号多 Key 额度滚动轮播。",
};

export default function NotchPreviewPage() {
  return (
    <main className="min-h-screen bg-[linear-gradient(145deg,var(--preview-desktop),var(--preview-desktop-end))] px-4 py-10 text-[var(--preview-ink)] sm:px-6">
      <div className="mx-auto max-w-[860px]">
        <div className="mb-8 text-center">
          <div className="text-[10px] font-bold uppercase tracking-[0.16em] text-emerald-600 dark:text-emerald-400">
            Product preview · 布局方案
          </div>
          <h1 className="mt-2 text-3xl font-bold tracking-[-0.045em]">刘海屏伴侣 · 显示方案</h1>
          <p className="mx-auto mt-3 max-w-2xl text-sm leading-6 text-[var(--preview-muted)]">
            刘海屏只在 <b className="text-[var(--preview-ink)]">主显示器且为刘海屏</b> 时启用（中央避让摄像头）；
            非主显示器或非刘海屏机型自动降级到 <b className="text-[var(--preview-ink)]">原始菜单栏胶囊</b>（状态·额度横排）。
            本页可交互：切换设备/方案、悬停展开、点击固定、手动轮播。
          </p>
          <div className="mt-4 flex flex-wrap items-center justify-center gap-2 text-[10px]">
            <Link
              href="/preview"
              className="rounded-full border border-[color:var(--preview-line)] bg-[var(--preview-card)]/70 px-3 py-1.5 text-[var(--preview-muted)] transition hover:text-[var(--preview-ink)] backdrop-blur"
            >
              ← 返回多账号陪伴预览
            </Link>
            <span className="rounded-full border border-[color:var(--preview-line)] bg-[var(--preview-card)]/70 px-3 py-1.5 text-[var(--preview-muted)] backdrop-blur">
              路由：<code className="text-[var(--preview-ink)]">/preview/notch</code>
            </span>
          </div>
        </div>

        {/* ============ 可交互演示 ============ */}
        <NotchCompanionDemo />

        {/* ============ 分支矩阵 ============ */}
        <h2 className="mt-20 text-xl font-bold tracking-[-0.03em]">分支矩阵 · 全部情况</h2>
        <p className="mt-1.5 text-xs leading-6 text-[var(--preview-muted)]">
          运行时由「设备/屏幕」与「数据状态」两个维度决定最终呈现；下表为完整分支。
        </p>
        <div className="mt-4 overflow-x-auto rounded-2xl border border-[color:var(--preview-line)] bg-[var(--preview-card)]/70 backdrop-blur">
          <table className="w-full min-w-[680px] border-collapse text-[11px]">
            <thead>
              <tr className="border-b border-[color:var(--preview-line)] text-left text-[9px] uppercase tracking-[0.1em] text-[var(--preview-muted)]">
                <th className="px-3 py-2.5 font-semibold">分支</th>
                <th className="px-3 py-2.5 font-semibold">条件</th>
                <th className="px-3 py-2.5 font-semibold">呈现</th>
              </tr>
            </thead>
            <tbody className="text-[var(--preview-ink)]">
              <BranchRow
                branch="刘海屏方案"
                cond="主显示器 && safeAreaInsets.top &gt; 0（刘海屏）"
                show="310pt 黑色胶囊居中挂于刘海下方：左区 Agent 状态 / 中央 104pt 避让摄像头 / 右区供应商 logo+额度，左右独立轮播"
              />
              <BranchRow
                branch="降级方案"
                cond="非主显示器 || 无刘海（safeAreaInsets.top == 0）"
                show="原始 218pt 白色胶囊，横排「● 状态 · logo 额度」，边缘流光跟随状态色顺时针旋转"
              />
              <BranchRow
                branch="收起态（默认）"
                cond="未悬停、未固定"
                show="固定宽度避免轮播跳动；左区 Agent 状态 2.8s / 右区供应商额度 3.6s 独立轮播"
              />
              <BranchRow
                branch="悬停展开"
                cond="mouseenter 且无固定"
                show="向下展开 452×236 详情面板（左右两列）；两侧轮播暂停"
              />
              <BranchRow
                branch="点击固定"
                cond="click 展开态按钮"
                show="pinned=true，面板保持展开；再点收起"
              />
              <BranchRow
                branch="Esc / 外部点击"
                cond="键盘 Esc 或点击外部"
                show="取消固定并收起"
              />
              <BranchRow
                branch="单 Agent 工作"
                cond="仅 1 个活跃 Agent"
                show="左区直接显示其状态（工作中/待确认/…），无计数徽标"
              />
              <BranchRow
                branch="多 Agent 并发"
                cond="≥2 个活跃 Agent（含同一 Codex 多账号）"
                show="左区状态带 ×N 计数徽标；展开面板底部显示「N 个本地任务 / M 个待确认」；左列逐个轮播/箭头切换每个 Agent"
              />
              <BranchRow
                branch="多账号 / 多 Key"
                cond="多个 Codex 账号 + DeepSeek/Claude API Key"
                show="右列点供应商 logo 切换额度；降级下拉列出全部账号与额度"
              />
              <BranchRow
                branch="账号额度型"
                cond="Codex / Kimi 等账号窗口"
                show="额度显示「5h 82% · 周76%」双窗百分比"
              />
              <BranchRow
                branch="API Key 余额型"
                cond="DeepSeek / Claude 等余额接口"
                show="额度显示「¥42.80」货币余额，副行标注 API Key"
              />
              <BranchRow
                branch="未登录 / 无额度"
                cond="无账号或额度接口不可用"
                show="胶囊文字退化为「未登录」/「无额度」，圆点灰色"
              />
              <BranchRow
                branch="减少动态效果"
                cond="系统 prefers-reduced-motion"
                show="停用流光与过渡动画；两侧轮播暂停"
              />
              <BranchRow
                branch="深浅色"
                cond="跟随系统主题"
                show="刘海胶囊恒为深色（避开摄像头观感）；降级胶囊跟随主题浅/深色"
              />
              <BranchRow
                branch="屏幕配置变化"
                cond="外接/断开显示器、切换主屏"
                show="监听 didChangeScreenParameters，动态重算模式（刘海 ↔ 降级）"
              />
            </tbody>
          </table>
        </div>

        {/* ============ 运行时检测（Swift 侧） ============ */}
        <h2 className="mt-14 text-xl font-bold tracking-[-0.03em]">运行时检测 · Swift 实现要点</h2>
        <p className="mt-1.5 text-xs leading-6 text-[var(--preview-muted)]">
          刘海没有直接 API，用主屏安全区 / 摄像头辅助区判定；主屏取 <code className="text-[var(--preview-ink)]">NSScreen.screens.first</code>。
        </p>
        <div className="mt-4 overflow-x-auto rounded-2xl border border-[color:var(--preview-line)] bg-[var(--preview-card)]/70 backdrop-blur">
          <pre className="overflow-x-auto p-4 text-[11px] leading-relaxed text-[var(--preview-ink)]"><code>{`// 1) 主屏是否为刘海屏
let mainScreen = NSScreen.screens.first
let isNotch = (mainScreen?.safeAreaInsets.top ?? 0) > 0
          || mainScreen?.auxiliaryTopLeftArea != nil   // macOS 12+

// 2) 启用条件：主屏 && 刘海
let usesNotchMode = isNotch && mainScreen === statusItem.button?.window?.screen

// 3) 屏幕配置变化时重算（外接/断开/切换主屏）
NotificationCenter.default.addObserver(
  forName: NSApplication.didChangeScreenParametersNotification,
  object: nil, queue: .main
) { _ in
  self.rebuildCapsuleForCurrentScreen()
}`}</code></pre>
        </div>
        <p className="mt-3 text-xs leading-6 text-[var(--preview-muted)]">
          降级 = 现有 <code className="text-[var(--preview-ink)]">StatusCapsuleView</code> 原样保留；刘海 = 新增分支，
          仅在 <code className="text-[var(--preview-ink)]">usesNotchMode</code> 时替换为刘海胶囊（左状态 / 中央避让 / 右额度 + 展开面板）。
        </p>

        {/* ============ 状态色板 ============ */}
        <h2 className="mt-14 text-xl font-bold tracking-[-0.03em]">Agent 状态色板</h2>
        <p className="mt-1.5 text-xs leading-6 text-[var(--preview-muted)]">
          与 Swift <code className="text-[var(--preview-ink)]">CodexActivityState.statusNSColor</code> 对齐。
        </p>
        <div className="mt-4 flex flex-wrap gap-2">
          {(["working", "idle", "waiting", "reviewing", "completed", "interrupted", "unavailable"] as const).map((key) => {
            const meta = {
              working: { label: "工作中", color: "#2e6bff" },
              idle: { label: "空闲", color: "#aeb5b3" },
              waiting: { label: "待确认", color: "#f27314" },
              reviewing: { label: "检查中", color: "#05a1cc" },
              completed: { label: "已完成", color: "#1fa55a" },
              interrupted: { label: "已中止", color: "#ed384d" },
              unavailable: { label: "不可用", color: "#aeb5b3" },
            }[key];
            return (
              <span key={key} className="flex items-center gap-2 rounded-full border border-[color:var(--preview-line)] bg-[var(--preview-card)]/70 px-3 py-1.5 text-[10px] text-[var(--preview-ink)] backdrop-blur">
                <span className="h-2 w-2 rounded-full" style={{ backgroundColor: meta.color }} />
                {meta.label}
              </span>
            );
          })}
        </div>
      </div>
    </main>
  );
}

function BranchRow({ branch, cond, show }: { branch: string; cond: string; show: string }) {
  return (
    <tr className="border-b border-[color:var(--preview-line)]/60 align-top last:border-0">
      <td className="whitespace-nowrap px-3 py-2.5 font-semibold">{branch}</td>
      <td className="px-3 py-2.5 text-[var(--preview-muted)]">{cond}</td>
      <td className="px-3 py-2.5">{show}</td>
    </tr>
  );
}
