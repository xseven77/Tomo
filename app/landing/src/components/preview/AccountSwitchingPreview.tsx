"use client";

import Image from "next/image";
import { Check, ChevronRight, KeyRound, Plus, RefreshCw, Settings, X } from "lucide-react";
import { useLayoutEffect, useRef, useState } from "react";
import { connections, type Connection } from "./CompanionAccountPreview";

type PreviewLayout = "horizontal" | "vertical";

const PREVIEW_SIZE: Record<PreviewLayout, { width: number; height: number }> = {
  horizontal: { width: 720, height: 720 },
  vertical: { width: 390, height: 950 },
};

function WindowDots() {
  return (
    <div className="flex gap-2" aria-hidden>
      <span className="h-3.5 w-3.5 rounded-full border border-[#e0443e] bg-[#ff5f57]" />
      <span className="h-3.5 w-3.5 rounded-full border border-[#d89e24] bg-[#febc2e]" />
      <span className="h-3.5 w-3.5 rounded-full border border-[#17a92f] bg-[#28c840]" />
    </div>
  );
}

function LayoutIcon({ layout }: { layout: PreviewLayout }) {
  return layout === "horizontal" ? (
    <svg viewBox="0 0 20 16" aria-hidden className="h-4 w-5 shrink-0" fill="none" stroke="currentColor" strokeWidth="1.6"><rect x="1.25" y="1.25" width="17.5" height="13.5" rx="2.5" /><path d="M7 1.5v13" /></svg>
  ) : (
    <svg viewBox="0 0 14 18" aria-hidden className="h-[18px] w-3.5 shrink-0" fill="none" stroke="currentColor" strokeWidth="1.6"><rect x="1.25" y="1.25" width="11.5" height="15.5" rx="2.5" /><path d="M1.5 7h11" /></svg>
  );
}

function ConnectionMark({ connection, size = "md" }: { connection: Connection; size?: "sm" | "md" }) {
  const pixels = size === "sm" ? 28 : 36;
  return <span className={`grid shrink-0 place-items-center overflow-hidden rounded-[10px] bg-[var(--preview-card)] ring-1 ring-[color:var(--preview-line)] ${size === "sm" ? "h-7 w-7 p-1" : "h-9 w-9 p-1.5"}`}><Image src={`/brand-assets/${connection.brand}/color.svg`} alt={`${connection.agent} Logo`} width={pixels} height={pixels} unoptimized className="h-full w-full object-contain" /></span>;
}

function StatusCapsule() {
  return (
    <div className="status-edge-glow relative inline-flex h-9 w-fit self-center whitespace-nowrap items-center gap-2 overflow-hidden rounded-full px-4 text-[10px] font-bold text-[var(--preview-menubar-pill-fg)] shadow-sm">
      <span className="status-edge-glow__inner" />
      <span className="relative z-10 h-2 w-2 rounded-full bg-orange-500 shadow-[0_0_9px_rgba(249,115,22,0.7)]" />
      <span className="relative z-10">Kimi 等待你确认</span>
    </div>
  );
}

const localTasks = [
  { id: "codex-work", agent: "Codex", logo: "/brand-assets/codex/color.svg", task: "优化多账号切换", state: "工作中", tone: "bg-violet-500" },
  { id: "kimi-personal", agent: "Kimi Code", logo: "/brand-assets/kimi-code/color.svg", task: "是否执行完整测试？", state: "待确认", tone: "bg-orange-500" },
  { id: "qwen-local", agent: "Qwen Code", logo: "/brand-assets/qwen-code/color.svg", task: "Hooks 已就绪", state: "空闲", tone: "bg-gray-300" },
];

const petTasksPopoverPlacement: Record<PreviewLayout, string> = {
  horizontal: "-left-7 top-[calc(100%+8px)]",
  vertical: "left-[52px] top-[252px]",
};

function PetTasksPopover({ layout, onSelect, onFeedback, onClose, onPointerEnter, onPointerLeave }: { layout: PreviewLayout; onSelect: (id: string) => void; onFeedback: (message: string) => void; onClose: () => void; onPointerEnter: () => void; onPointerLeave: () => void }) {
  return (
    <section onMouseEnter={onPointerEnter} onMouseLeave={onPointerLeave} className={`absolute z-40 w-[286px] rounded-[16px] border border-[color:var(--preview-line)] bg-[color:var(--preview-card)]/96 p-3 shadow-[0_20px_54px_rgba(23,30,40,0.22)] backdrop-blur-xl animate-[preview-enter_180ms_ease-out] ${petTasksPopoverPlacement[layout]}`}>
      <div className="flex items-center justify-between">
        <div><span className="block text-[10px] font-bold text-[var(--preview-ink)]">Pet 看到的本地任务</span><span className="mt-0.5 block text-[7px] text-[var(--preview-muted)]">仅 Pet 汇总，不属于当前账号</span></div>
        <div className="flex items-center gap-1.5"><span className="text-[7px] font-semibold text-emerald-600">Hooks 正常</span><button type="button" onClick={onClose} aria-label="收起本地任务" className="grid h-5 w-5 place-items-center rounded-full bg-[var(--preview-sidebar)] text-[var(--preview-muted)]"><X className="h-2.5 w-2.5" /></button></div>
      </div>
      <div className="mt-2 space-y-0.5">
        {localTasks.map((task) => (
          <button
            key={task.id}
            type="button"
            onClick={() => task.id === "qwen-local" ? onFeedback("已准备打开 Qwen Code 本地任务") : onSelect(task.id)}
            className="flex w-full min-w-0 items-center gap-2 rounded-[9px] p-1.5 text-left transition hover:bg-[var(--preview-sidebar)]"
          >
            <span className="relative h-7 w-7 shrink-0 overflow-hidden rounded-[8px] bg-[var(--preview-sidebar)]"><Image src={task.logo} alt={`${task.agent} Logo`} width={28} height={28} className="h-full w-full object-cover" /><span className={`absolute bottom-0.5 right-0.5 h-2 w-2 rounded-full border border-[var(--preview-card)] ${task.tone}`} /></span>
            <span className="min-w-0 flex-1">
              <span className="block truncate text-[8.5px] font-bold text-[var(--preview-ink)]">{task.agent}</span>
              <span className="block truncate text-[7px] text-[var(--preview-muted)]">{task.task}</span>
            </span>
            <span className="text-[6.5px] font-semibold text-[var(--preview-muted)]">{task.state}</span>
          </button>
        ))}
      </div>
    </section>
  );
}

function PetPanel({ vertical = false, tasksOpen, onTasksEnter, onTasksLeave, onTasksToggle }: { vertical?: boolean; tasksOpen: boolean; onTasksEnter: () => void; onTasksLeave: () => void; onTasksToggle: () => void }) {
  return (
    <aside className={vertical ? "relative flex h-[300px] shrink-0 flex-col items-center justify-center border-b border-[color:var(--preview-line)] bg-[linear-gradient(150deg,var(--preview-sidebar),var(--preview-card))] px-4 pb-3 pt-3" : "relative flex h-full min-w-0 flex-col overflow-hidden border-r border-[color:var(--preview-line)] bg-[linear-gradient(160deg,var(--preview-sidebar),var(--preview-card))] px-5 pb-5 pt-4"}>
      <div className={vertical ? "absolute left-4 top-4" : ""}><WindowDots /></div>
      {!vertical && (
        <div className="absolute left-1/2 top-12 z-10 flex -translate-x-1/2 items-center gap-1.5 whitespace-nowrap text-[8px] text-[var(--preview-muted)]">
          <span className="font-semibold uppercase tracking-[0.12em]">任务来源</span>
          <span className="h-3.5 w-3.5 overflow-hidden rounded-[5px]"><Image src="/brand-assets/kimi-code/color.svg" alt="Kimi Code Logo" width={14} height={14} unoptimized className="h-full w-full object-contain" /></span>
          <span className="font-bold text-[var(--preview-ink)]">Kimi Code</span>
          <span className="h-1.5 w-1.5 rounded-full bg-orange-500" />
        </div>
      )}
      <div className={vertical ? "relative mt-1 h-[112px]" : "relative flex flex-1 items-center justify-center"}>
        <div className="pointer-events-none absolute inset-4 rounded-full bg-emerald-400/10 blur-2xl" />
        <Image src="/brand/tomo-logo.webp" alt="Tomo Pet" width={150} height={150} priority className={vertical ? "relative h-[112px] w-[112px] animate-float drop-shadow-[0_16px_18px_rgba(0,0,0,0.2)]" : "relative h-auto w-[78%] max-w-[150px] animate-float drop-shadow-[0_16px_18px_rgba(0,0,0,0.2)]"} />
      </div>
      <StatusCapsule />
      <button type="button" aria-expanded={tasksOpen} onMouseEnter={onTasksEnter} onMouseLeave={onTasksLeave} onClick={onTasksToggle} className={`mt-2 flex w-fit self-center whitespace-nowrap items-center justify-center gap-1.5 rounded-full border px-3 py-1.5 text-center text-[8px] font-semibold transition ${tasksOpen ? "border-emerald-500/30 bg-emerald-500/10 text-emerald-700" : "border-[color:var(--preview-line)] bg-[var(--preview-card)]/70 text-[var(--preview-muted)] hover:border-emerald-500/25 hover:text-[var(--preview-ink)]"}`}><span className="flex -space-x-1.5">{localTasks.map((task) => <span key={task.id} className="h-4 w-4 overflow-hidden rounded-full border border-[var(--preview-card)]"><Image src={task.logo} alt="" width={16} height={16} className="h-full w-full object-cover" /></span>)}</span>3 个本地 Agent<ChevronRight className={`h-3 w-3 transition-transform ${tasksOpen ? "rotate-90" : ""}`} /></button>
      <div className="mt-1 text-center text-[7px] font-medium text-[var(--preview-muted)]">今天陪伴 2 小时 21 分钟</div>
    </aside>
  );
}

function ConnectionSwitcher({ activeId, onSelect, onAdd, vertical }: { activeId: string; onSelect: (id: string) => void; onAdd: () => void; vertical?: boolean }) {
  const stateDotClass = { waiting: "bg-orange-500", idle: "bg-slate-300", healthy: "bg-emerald-500", working: "bg-violet-500" };
  const balanceMarkClass = { waiting: "text-orange-500", idle: "text-slate-400", healthy: "text-emerald-500", working: "text-violet-500" };
  return (
    <div className={`flex shrink-0 items-center border-b border-[color:var(--preview-line)] bg-[var(--preview-panel)] ${vertical ? "h-[76px] justify-between gap-2 px-5" : "-mx-5 -mt-5 mb-4 h-[70px] gap-1.5 px-4"}`}>
      {connections.map((connection) => {
        const selected = activeId === connection.id;
        return (
          <button key={connection.id} type="button" aria-label={vertical ? `${connection.agent} · ${connection.account}` : undefined} aria-pressed={selected} onClick={() => onSelect(connection.id)} className={`relative border text-left transition-all ${vertical ? "grid h-11 w-11 shrink-0 place-items-center rounded-[13px] p-1" : "flex min-w-0 flex-1 items-center gap-1.5 rounded-[11px] px-2 py-2"} ${selected ? "border-emerald-500/30 bg-emerald-500/[0.08] shadow-[0_4px_12px_rgba(16,185,129,0.12)]" : "border-transparent hover:border-[color:var(--preview-line)] hover:bg-[var(--preview-card)]"}`}>
            <ConnectionMark connection={connection} size="sm" />
            {!vertical && <span className="min-w-0"><span className="block truncate text-[8.5px] font-bold text-[var(--preview-ink)]">{connection.agent}</span><span className="block truncate text-[7.5px] text-[var(--preview-muted)]">{connection.account}</span></span>}
            {vertical && connection.kind === "provider" && <span aria-label="余额状态" className={`absolute bottom-0.5 right-0.5 grid h-2.5 w-2.5 place-items-center text-[11px] font-black leading-none drop-shadow-[0_1px_0_var(--preview-panel)] ${balanceMarkClass[connection.stateTone]}`}>$</span>}
            {vertical && connection.kind !== "provider" && connection.stateTone !== "working" && <span className={`absolute bottom-0.5 right-0.5 h-2.5 w-2.5 rounded-full border-2 border-[var(--preview-panel)] shadow-sm ${stateDotClass[connection.stateTone]}`} />}
            {!vertical && connection.stateTone === "waiting" && <span className="ml-auto h-1.5 w-1.5 shrink-0 rounded-full bg-orange-500" />}
          </button>
        );
      })}
      <button type="button" onClick={onAdd} aria-label="添加账号或 API Key" className="grid h-8 w-8 shrink-0 place-items-center rounded-[10px] border border-dashed border-[color:var(--preview-line)] text-[var(--preview-muted)] transition hover:border-emerald-500/35 hover:text-emerald-600"><Plus className="h-3.5 w-3.5" /></button>
    </div>
  );
}

function QuotaRing({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex min-w-0 flex-1 items-center gap-3 rounded-[14px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] px-3 py-3">
      <div className="h-10 w-10 shrink-0 rounded-full p-[5px]" style={{ background: `conic-gradient(var(--preview-green) ${value}%, var(--preview-track) 0)` }}><div className="grid h-full w-full place-items-center rounded-full bg-[var(--preview-card)] text-[8px] font-bold text-[var(--preview-ink)]">{value}</div></div>
      <div><div className="text-[9px] font-bold text-[var(--preview-ink)]">{label}</div><div className="mt-1 text-[8px] text-[var(--preview-muted)]">剩余 {value}%</div></div>
    </div>
  );
}

function AccountHeader({ connection, onFeedback }: { connection: Connection; onFeedback: (message: string) => void }) {
  const [period, renewal] = connection.subscriptionSummary.split(" · ");
  return (
    <section className="px-0.5 py-0.5">
      <div className="flex items-start gap-2.5">
        <ConnectionMark connection={connection} />
        <div className="min-w-0 flex-1 pt-0.5">
          <div className="flex items-center gap-1.5">
            <h3 className="truncate text-[14px] font-bold tracking-[-0.02em] text-[var(--preview-ink)]">{connection.accountName}</h3>
            <span className="rounded-full bg-[var(--preview-green-soft)] px-2 py-0.5 text-[7px] font-bold text-[var(--preview-green)]">{connection.plan}</span>
          </div>
          <div className="mt-0.5 truncate text-[8px] text-[var(--preview-muted)]">{connection.accountEmail}</div>
        </div>
        <span className={`inline-flex shrink-0 items-center gap-1 rounded-full px-2 py-1 text-[7px] font-semibold ${connection.stateTone === "waiting" ? "bg-orange-500/10 text-orange-600" : connection.stateTone === "working" ? "bg-violet-500/10 text-violet-600" : connection.stateTone === "healthy" ? "bg-emerald-500/10 text-emerald-600" : "bg-black/[0.04] text-[var(--preview-muted)]"}`}>
        <span className="h-1.5 w-1.5 rounded-full bg-current" />{connection.state}
        </span>
      </div>
      {connection.kind !== "provider" && (
        <div className="mt-2.5 flex items-center gap-2 border-t border-[color:var(--preview-line)] pt-2">
          <div className="min-w-0 flex flex-1 items-center gap-1.5 text-[7px]"><span className="truncate font-semibold text-[var(--preview-ink)]">{period}</span>{renewal && <><span className="h-0.5 w-0.5 shrink-0 rounded-full bg-[var(--preview-muted)]" /><span className="shrink-0 text-[var(--preview-muted)]">{renewal}</span></>}</div>
          <a href={connection.billingUrl} target="_blank" rel="noreferrer" onClick={() => onFeedback(`正在打开 ${connection.agent} 官方 Billing`)} className="flex shrink-0 items-center gap-0.5 text-[7px] font-bold text-[var(--preview-green)] transition hover:opacity-70">官方 Billing<ChevronRight className="h-2.5 w-2.5" /></a>
        </div>
      )}
    </section>
  );
}

function AccountTaskCard({ connection, onFeedback }: { connection: Connection; onFeedback: (message: string) => void }) {
  return (
    <section className={`mt-3 rounded-[15px] border px-3.5 py-3 ${connection.task ? "border-violet-500/15 bg-[linear-gradient(145deg,rgba(124,58,237,0.05),var(--preview-card))]" : "border-[color:var(--preview-line)] bg-[var(--preview-card)]"}`}>
      <div className="flex items-center justify-between text-[8px] text-[var(--preview-muted)]"><span className="font-bold uppercase tracking-[0.1em]">当前任务</span><span>更新于刚刚</span></div>
      {connection.task ? (
        <>
          <div className="mt-2 text-[13px] font-bold text-[var(--preview-ink)]">{connection.task}</div>
          <div className="mt-1 text-[8px] text-[var(--preview-muted)]">{connection.detail}</div>
          <button type="button" onClick={() => onFeedback(`已准备打开 ${connection.agent} 任务`)} className="mt-2.5 flex w-full items-center justify-between border-t border-[color:var(--preview-line)] pt-2 text-[8px] font-semibold text-violet-600"><span>{connection.state === "待确认" ? "等待你的操作" : "正在运行本地工具"}</span><span className="flex items-center gap-1 text-[var(--preview-ink)]">打开任务 <ChevronRight className="h-3 w-3" /></span></button>
        </>
      ) : (
        <div className="flex h-[58px] flex-col items-center justify-center"><div className="text-[10px] font-bold text-[var(--preview-ink)]">现在很安静</div><div className="mt-1 text-[8px] text-[var(--preview-muted)]">这个账号没有进行中的任务</div></div>
      )}
    </section>
  );
}

function QuotaSection({ connection, onFeedback }: { connection: Connection; onFeedback: (message: string) => void }) {
  return (
    <section className="mt-3">
      <div className="flex items-center justify-between"><span className="text-[10px] font-bold text-[var(--preview-ink)]">额度</span><button type="button" onClick={() => onFeedback(`${connection.agent} 额度已刷新`)} className="flex items-center gap-1 text-[8px] text-[var(--preview-muted)]"><RefreshCw className="h-3 w-3" />刷新</button></div>
      <div className="mt-2 flex gap-2"><QuotaRing label="5 小时" value={connection.shortQuota ?? 0} /><QuotaRing label="本周" value={connection.weeklyQuota ?? 0} /></div>
    </section>
  );
}

function CouponIcon() {
  return (
    <div className="flex h-9 w-9 shrink-0 items-center justify-center rounded-[11px] border border-white/70 bg-[linear-gradient(145deg,#9c9dff,#405dff)] text-white shadow-[0_5px_14px_rgba(76,92,255,0.28)]">
      <svg viewBox="0 0 28 28" aria-hidden className="h-5 w-5" fill="none" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round"><path d="m7.5 6.5 6 7-6 7" strokeWidth="2.4" /><path d="M15.5 20.5h5" strokeWidth="2.4" /></svg>
    </div>
  );
}

function ResetCoupon({ connection }: { connection: Connection }) {
  const work = connection.account === "Work";
  return (
    <section className="mt-3 flex h-[216px] shrink-0 flex-col overflow-hidden rounded-[16px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] shadow-[var(--preview-card-shadow)]">
      <div className="h-[76px] shrink-0 px-4 pt-3">
        <div className="flex items-center justify-between"><span className="text-[10px] font-bold text-[var(--preview-ink)]">重置券有效期</span><span className="text-[8px] font-semibold text-[var(--preview-muted)]">{work ? "2 张" : "1 张"} · 按到期排序</span></div>
        <div className="relative mt-4 h-1 rounded-full bg-[var(--preview-track)]"><span className="absolute left-[26%] top-1/2 h-4 w-4 -translate-x-1/2 -translate-y-1/2 rounded-full border-[3px] border-[#c8f2d2] bg-[var(--preview-green)] shadow-sm" /><span className="absolute right-2 top-1/2 h-3 w-3 -translate-y-1/2 rounded-full border-[2px] border-white bg-[#d6dce5] shadow-sm" /></div>
        <div className="mt-3 grid grid-cols-[1.15fr_0.85fr] text-[7px] font-semibold text-[var(--preview-muted)]"><span><span className="mr-2 text-[var(--preview-ink)]">类型</span>重置 Codex 速率额度</span><span><span className="mr-2 text-[var(--preview-ink)]">状态</span>available</span></div>
      </div>
      <div className="flex min-h-0 flex-1 flex-col border-t border-[color:var(--preview-line)] px-4 pt-3">
        <div className="flex items-center"><CouponIcon /><div className="ml-3 min-w-0"><div className="truncate text-[10px] font-bold text-[var(--preview-ink)]">{work ? "Codex Team" : "Codex Plus"}</div><div className="text-[7px] font-semibold text-[var(--preview-muted)]">授予 · 7月2日</div></div><span className="ml-auto text-[8px] font-bold text-[var(--preview-muted)]">1/{work ? "2" : "1"}</span></div>
        <div className="mt-2 text-[12px] font-bold leading-none text-[var(--preview-ink)]">Full reset</div>
        <div className="mt-1 truncate text-[7px] font-semibold text-[var(--preview-muted)]">Thanks for using Codex! You&apos;ve been granted one free rate limit reset.</div>
        <div className="-mx-4 mt-auto flex h-10 shrink-0 items-center justify-between rounded-t-[12px] bg-[#f8f9f9] px-4 dark:bg-[#323236]"><span className="text-[7px] font-semibold tabular-nums text-[var(--preview-muted)]">2026-08-01 03:50:25 到期</span><span className="rounded-full border border-[color:var(--preview-green)]/25 bg-[var(--preview-green-soft)] px-2 py-1 text-[7px] font-bold text-[var(--preview-green)]">下一张</span></div>
      </div>
    </section>
  );
}

function CodexContent({ connection, onFeedback }: { connection: Connection; onFeedback: (message: string) => void }) {
  return <><AccountHeader connection={connection} onFeedback={onFeedback} /><AccountTaskCard connection={connection} onFeedback={onFeedback} /><QuotaSection connection={connection} onFeedback={onFeedback} /><ResetCoupon connection={connection} /></>;
}

function KimiContent({ connection, onFeedback }: { connection: Connection; onFeedback: (message: string) => void }) {
  return (
    <><AccountHeader connection={connection} onFeedback={onFeedback} /><AccountTaskCard connection={connection} onFeedback={onFeedback} /><QuotaSection connection={connection} onFeedback={onFeedback} />
      <section className="mt-3 rounded-[15px] border border-blue-500/15 bg-[linear-gradient(145deg,rgba(59,130,246,0.05),var(--preview-card))] p-3.5"><div className="flex items-center justify-between"><span className="text-[10px] font-bold text-[var(--preview-ink)]">Kimi Code 会员</span><span className="rounded-full bg-blue-500/10 px-2 py-1 text-[7px] font-bold text-blue-600">已连接</span></div><div className="mt-3 grid grid-cols-2 gap-2"><div className="rounded-[10px] bg-[var(--preview-sidebar)] p-2.5"><div className="text-[7px] text-[var(--preview-muted)]">Extra Usage</div><div className="mt-1 text-[12px] font-bold text-[var(--preview-ink)]">未启用</div></div><div className="rounded-[10px] bg-[var(--preview-sidebar)] p-2.5"><div className="text-[7px] text-[var(--preview-muted)]">下次刷新</div><div className="mt-1 text-[12px] font-bold text-[var(--preview-ink)]">2h 18m</div></div></div></section>
    </>
  );
}

function ProviderContent({ connection, onFeedback }: { connection: Connection; onFeedback: (message: string) => void }) {
  return (
    <><AccountHeader connection={connection} onFeedback={onFeedback} /><section className="relative mt-4 overflow-hidden rounded-[17px] border border-violet-500/15 bg-[linear-gradient(145deg,rgba(124,58,237,0.07),var(--preview-card))] p-4"><div className="text-[8px] font-bold uppercase tracking-[0.12em] text-[var(--preview-muted)]">可用余额</div><div className="mt-1 text-[32px] font-bold tracking-[-0.05em] text-[var(--preview-ink)]">{connection.balance}</div><div className="text-[8px] text-[var(--preview-muted)]">{connection.balanceDetail}</div><button type="button" onClick={() => onFeedback("DeepSeek 余额已刷新")} className="mt-4 flex h-9 w-full items-center justify-center gap-2 rounded-[10px] bg-[var(--preview-primary)] text-[8px] font-bold text-[var(--preview-on-primary)]"><RefreshCw className="h-3 w-3" />查询官方余额</button></section><section className="mt-3 rounded-[15px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] p-3.5"><div className="text-[9px] font-bold text-[var(--preview-ink)]">API Key 信息</div><div className="mt-3 space-y-2 text-[8px]"><div className="flex justify-between"><span className="text-[var(--preview-muted)]">查询接口</span><span className="font-mono text-[var(--preview-ink)]">GET /user/balance</span></div><div className="flex justify-between"><span className="text-[var(--preview-muted)]">数据来源</span><span className="text-[var(--preview-ink)]">Official API</span></div><div className="flex justify-between"><span className="text-[var(--preview-muted)]">最后更新</span><span className="text-[var(--preview-ink)]">刚刚</span></div></div></section></>
  );
}

function CurrentConnection({ connection, onFeedback }: { connection: Connection; onFeedback: (message: string) => void }) {
  return (
    <div key={connection.id} className="animate-[preview-enter_220ms_ease-out]">
      {connection.agent === "Codex" ? <CodexContent connection={connection} onFeedback={onFeedback} /> : connection.kind === "provider" ? <ProviderContent connection={connection} onFeedback={onFeedback} /> : <KimiContent connection={connection} onFeedback={onFeedback} />}
    </div>
  );
}

function FooterActions({ connection, onFeedback }: { connection: Connection; onFeedback: (message: string) => void }) {
  return (
    <div className="mt-auto flex items-center justify-between pt-3"><span className="text-[8px] text-[var(--preview-muted)]">上次同步：刚刚</span><div className="flex gap-2"><button type="button" onClick={() => onFeedback(`${connection.agent} 设置已打开`)} className="grid h-8 w-8 place-items-center rounded-[9px] bg-[var(--preview-sidebar)] text-[var(--preview-muted)]"><Settings className="h-3.5 w-3.5" /></button><button type="button" onClick={() => onFeedback(`${connection.agent} · ${connection.account} 已刷新`)} className="flex h-8 items-center gap-1.5 rounded-[9px] bg-[var(--preview-primary)] px-3 text-[8px] font-bold text-[var(--preview-on-primary)]"><RefreshCw className="h-3 w-3" />刷新当前账号</button></div></div>
  );
}

type PreviewProps = { active: Connection; onSelect: (id: string) => void; onAdd: () => void; onFeedback: (message: string) => void; tasksOpen: boolean; onTasksEnter: () => void; onTasksLeave: () => void; onTasksToggle: () => void };

function HorizontalPreview({ active, onSelect, onAdd, onFeedback, tasksOpen, onTasksEnter, onTasksLeave, onTasksToggle }: PreviewProps) {
  return (
    <div className="grid h-full grid-cols-[32%_68%] bg-[var(--preview-panel)]"><PetPanel tasksOpen={tasksOpen} onTasksEnter={onTasksEnter} onTasksLeave={onTasksLeave} onTasksToggle={onTasksToggle} /><main className="flex min-w-0 flex-col overflow-y-auto bg-[var(--preview-card)] px-5 pb-4 pt-5"><ConnectionSwitcher activeId={active.id} onSelect={onSelect} onAdd={onAdd} /><CurrentConnection connection={active} onFeedback={onFeedback} /><FooterActions connection={active} onFeedback={onFeedback} /></main></div>
  );
}

function VerticalPreview({ active, onSelect, onAdd, onFeedback, tasksOpen, onTasksEnter, onTasksLeave, onTasksToggle }: PreviewProps) {
  return (
    <div className="flex h-full flex-col bg-[var(--preview-panel)]"><PetPanel vertical tasksOpen={tasksOpen} onTasksEnter={onTasksEnter} onTasksLeave={onTasksLeave} onTasksToggle={onTasksToggle} /><ConnectionSwitcher activeId={active.id} onSelect={onSelect} onAdd={onAdd} vertical /><main className="flex min-h-0 flex-1 flex-col overflow-y-auto bg-[var(--preview-card)] px-4 pb-4 pt-4"><CurrentConnection connection={active} onFeedback={onFeedback} /><FooterActions connection={active} onFeedback={onFeedback} /></main></div>
  );
}

function AddConnection({ onClose, onFeedback }: { onClose: () => void; onFeedback: (message: string) => void }) {
  const [kind, setKind] = useState<"agent" | "provider">("agent");
  return (
    <div className="absolute inset-0 z-20 flex items-center justify-center bg-black/20 p-8 backdrop-blur-[2px]"><button type="button" aria-label="关闭添加连接" className="absolute inset-0" onClick={onClose} /><section className="relative w-[330px] rounded-[20px] border border-white/30 bg-[var(--preview-card)] p-4 shadow-2xl"><div className="flex items-start justify-between"><div><div className="text-[8px] font-bold uppercase tracking-[0.12em] text-emerald-600">New connection</div><h3 className="mt-1 text-[16px] font-bold text-[var(--preview-ink)]">添加账号或 API Key</h3><p className="mt-1 text-[8px] text-[var(--preview-muted)]">同一种 Agent 可以登录多个账号。</p></div><button type="button" onClick={onClose} className="grid h-7 w-7 place-items-center rounded-full bg-black/5 text-[var(--preview-muted)]"><X className="h-3.5 w-3.5" /></button></div><div className="mt-4 grid grid-cols-2 gap-1 rounded-[10px] bg-[var(--preview-sidebar)] p-1"><button type="button" onClick={() => setKind("agent")} className={`rounded-[8px] py-2 text-[8px] font-bold ${kind === "agent" ? "bg-[var(--preview-card)] text-[var(--preview-ink)] shadow-sm" : "text-[var(--preview-muted)]"}`}>Agent 账号</button><button type="button" onClick={() => setKind("provider")} className={`rounded-[8px] py-2 text-[8px] font-bold ${kind === "provider" ? "bg-[var(--preview-card)] text-[var(--preview-ink)] shadow-sm" : "text-[var(--preview-muted)]"}`}>API Key</button></div>{kind === "agent" ? <div className="mt-3 space-y-2">{[connections[0], connections[2]].map((item) => <button key={item.id} type="button" onClick={() => { onFeedback(`已启动 ${item.agent} 官方登录`); onClose(); }} className="flex w-full items-center gap-2 rounded-[11px] border border-[color:var(--preview-line)] p-2.5 text-left"><ConnectionMark connection={item} size="sm" /><span className="flex-1"><span className="block text-[8px] font-bold text-[var(--preview-ink)]">登录另一个 {item.agent} 账号</span><span className="block text-[7px] text-[var(--preview-muted)]">委托官方登录</span></span><ChevronRight className="h-3 w-3 text-[var(--preview-muted)]" /></button>)}</div> : <div className="mt-3"><div className="flex h-10 items-center gap-2 rounded-[10px] border border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] px-3"><KeyRound className="h-3.5 w-3.5 text-[var(--preview-muted)]" /><span className="text-[8px] text-[var(--preview-muted)]">sk-••••••••••••</span></div><button type="button" onClick={() => { onFeedback("API Key 已验证，余额 ¥42.80"); onClose(); }} className="mt-3 flex h-9 w-full items-center justify-center gap-2 rounded-[10px] bg-[var(--preview-primary)] text-[8px] font-bold text-[var(--preview-on-primary)]"><Check className="h-3 w-3" />验证并添加</button></div>}</section></div>
  );
}

export function AccountSwitchingPreview() {
  const [layout, setLayout] = useState<PreviewLayout>("horizontal");
  const [activeId, setActiveId] = useState("codex-work");
  const [showAdd, setShowAdd] = useState(false);
  const [feedback, setFeedback] = useState<string>();
  const [tasksHovered, setTasksHovered] = useState(false);
  const [tasksPinned, setTasksPinned] = useState(false);
  const wrapperRef = useRef<HTMLDivElement>(null);
  const tasksCloseTimer = useRef<number | undefined>(undefined);
  const [scale, setScale] = useState(1);
  const size = PREVIEW_SIZE[layout];
  const active = connections.find((item) => item.id === activeId) ?? connections[0];
  const tasksOpen = tasksHovered || tasksPinned;

  useLayoutEffect(() => {
    const wrapper = wrapperRef.current;
    if (!wrapper) return;
    const updateScale = () => setScale(Math.min(1, wrapper.clientWidth / size.width));
    updateScale();
    const observer = new ResizeObserver(updateScale);
    observer.observe(wrapper);
    return () => observer.disconnect();
  }, [size.width]);

  const showFeedbackMessage = (message: string) => {
    setFeedback(message);
    window.setTimeout(() => setFeedback(undefined), 2200);
  };

  const openTasks = () => {
    if (tasksCloseTimer.current) window.clearTimeout(tasksCloseTimer.current);
    setTasksHovered(true);
  };

  const closeTasksSoon = () => {
    if (tasksCloseTimer.current) window.clearTimeout(tasksCloseTimer.current);
    tasksCloseTimer.current = window.setTimeout(() => setTasksHovered(false), 140);
  };

  const closeTasks = () => {
    if (tasksCloseTimer.current) window.clearTimeout(tasksCloseTimer.current);
    setTasksHovered(false);
    setTasksPinned(false);
  };

  const previewProps = { active, onSelect: setActiveId, onAdd: () => setShowAdd(true), onFeedback: showFeedbackMessage, tasksOpen, onTasksEnter: openTasks, onTasksLeave: closeTasksSoon, onTasksToggle: () => setTasksPinned((value) => !value) };

  return (
    <div className="transition-[margin] duration-300" style={{ marginBottom: tasksOpen && layout === "horizontal" ? 190 * scale : 0 }}>
      <div className="mb-5 flex justify-center" role="group" aria-label="选择应用预览布局"><div className="inline-flex rounded-full border border-border bg-surface/80 p-1 shadow-sm backdrop-blur">{(["horizontal", "vertical"] as const).map((value) => { const selected = layout === value; return <button key={value} type="button" aria-pressed={selected} onClick={() => setLayout(value)} className={`flex min-w-[112px] items-center justify-center gap-2 rounded-full px-4 py-2 text-sm font-medium transition-all ${selected ? "bg-foreground text-background shadow-sm" : "text-muted hover:text-foreground"}`}><LayoutIcon layout={value} />{value === "horizontal" ? "横向布局" : "竖向布局"}</button>; })}</div></div>
      <div ref={wrapperRef} className="relative mx-auto w-full transition-[height] duration-500 ease-out" style={{ height: size.height * scale }}>
        <div className="absolute left-1/2 top-0 overflow-visible transition-[width,height,transform] duration-500 ease-out" style={{ width: size.width, height: size.height, transform: `translateX(-50%) scale(${scale})`, transformOrigin: "top center" }}>
          <div className="relative h-full w-full overflow-hidden rounded-[26px] border border-[color:var(--preview-frame-border)] bg-[var(--preview-bg)] shadow-[var(--preview-shadow)]">
            {layout === "horizontal" ? <HorizontalPreview {...previewProps} /> : <VerticalPreview {...previewProps} />}
            {showAdd && <AddConnection onClose={() => setShowAdd(false)} onFeedback={showFeedbackMessage} />}
            {feedback && <div className="pointer-events-none absolute bottom-4 left-1/2 z-30 flex -translate-x-1/2 items-center gap-2 rounded-full bg-[#17191d]/92 px-4 py-2 text-[8px] font-semibold text-white shadow-xl animate-[preview-toast_240ms_ease-out]"><Check className="h-3 w-3 text-emerald-400" />{feedback}</div>}
          </div>
          {tasksOpen && <PetTasksPopover layout={layout} onSelect={(id) => { setActiveId(id); closeTasks(); }} onFeedback={showFeedbackMessage} onClose={closeTasks} onPointerEnter={openTasks} onPointerLeave={closeTasksSoon} />}
        </div>
      </div>
    </div>
  );
}
