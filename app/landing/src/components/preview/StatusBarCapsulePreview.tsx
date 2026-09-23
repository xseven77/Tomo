"use client";

import Image from "next/image";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { useEffect, useState } from "react";

const quotaAccounts = [
  {
    id: "codex-work",
    name: "Codex",
    account: "Work",
    logo: "/brand-assets/codex/color.svg",
    state: "工作中",
    dot: "bg-violet-500",
    compact: "5h 82% · 周 76%",
    statusText: "Codex 工作中",
    taskText: "重构账户切换逻辑",
    primary: "82%",
    secondary: "76%",
  },
  {
    id: "codex-personal",
    name: "Codex",
    account: "Personal",
    logo: "/brand-assets/codex/color.svg",
    state: "空闲",
    dot: "bg-slate-300",
    compact: "5h 54% · 周 91%",
    statusText: "Codex 空闲",
    taskText: "当前没有运行任务",
    primary: "54%",
    secondary: "91%",
  },
  {
    id: "kimi",
    name: "Kimi Code",
    account: "Personal",
    logo: "/brand-assets/kimi-code/color.svg",
    state: "待确认",
    dot: "bg-orange-500",
    compact: "5h 28% · 周 63%",
    statusText: "Kimi 待确认",
    taskText: "等待你确认完整测试",
    primary: "28%",
    secondary: "63%",
  },
  {
    id: "deepseek",
    name: "DeepSeek",
    account: "Personal Key",
    logo: "/brand-assets/deepseek/color.svg",
    state: "余额正常",
    dot: "bg-emerald-500",
    compact: "¥42.80",
    statusText: "DeepSeek 正常",
    taskText: "API Key 余额正常",
    primary: "¥42.80",
    secondary: "API Key",
    api: true,
  },
] as const;

export function StatusBarCapsulePreview() {
  const [activeIndex, setActiveIndex] = useState(0);
  const [hovered, setHovered] = useState(false);
  const [pinned, setPinned] = useState(false);
  const open = hovered || pinned;
  const account = quotaAccounts[activeIndex];

  useEffect(() => {
    if (open) return;
    const timer = window.setInterval(() => {
      setActiveIndex((index) => (index + 1) % quotaAccounts.length);
    }, 3200);
    return () => window.clearInterval(timer);
  }, [open]);

  const selectPrevious = () => setActiveIndex((index) => (index - 1 + quotaAccounts.length) % quotaAccounts.length);
  const selectNext = () => setActiveIndex((index) => (index + 1) % quotaAccounts.length);

  return (
    <div
      className="relative z-50 ml-auto"
      onMouseEnter={() => setHovered(true)}
      onMouseLeave={() => setHovered(false)}
      onKeyDown={(event) => {
        if (event.key === "Escape") setPinned(false);
      }}
    >
      <button
        type="button"
        aria-expanded={open}
        aria-label="查看当前任务状态与账号额度"
        onClick={() => setPinned((value) => !value)}
        className="status-edge-glow relative flex h-7 w-[218px] items-center justify-center overflow-hidden rounded-full px-2.5 text-[8px] font-medium text-[var(--preview-ink)] transition hover:-translate-y-px"
      >
        <span className="status-edge-glow__inner" />
        <span key={account.id} className="relative z-10 flex animate-[preview-enter_160ms_ease-out] items-center gap-1.5 whitespace-nowrap">
          <span className={`h-1.5 w-1.5 rounded-full ${account.dot}`} />
          <span className="font-semibold">{account.statusText}</span>
          <span className="h-3 w-px bg-black/10 dark:bg-white/15" />
          <Image src={account.logo} alt="" width={16} height={16} className="h-4 w-4 rounded-[5px] bg-white object-cover" />
          <span className="tabular-nums text-[var(--preview-muted)]">{account.compact}</span>
        </span>
      </button>

      {open && (
        <div className="absolute right-0 top-8 w-[292px] animate-[preview-enter_160ms_ease-out] rounded-[18px] border border-white/60 bg-white/90 p-2.5 text-left shadow-[0_18px_50px_rgba(25,31,29,0.20)] backdrop-blur-2xl dark:border-white/10 dark:bg-[#272a2b]/94">
          <div className="flex items-center justify-between px-1 pb-2">
            <div className="flex min-w-0 items-center gap-2">
              <Image
                src="/brand/tomo-logo.webp"
                alt="Tomo Pet"
                width={38}
                height={38}
                className="h-[38px] w-[38px] shrink-0 object-contain drop-shadow-[0_6px_7px_rgba(20,35,27,0.18)]"
              />
              <div key={account.id} className="min-w-0 animate-[preview-enter_160ms_ease-out]">
                <div className="text-[7px] font-semibold tracking-[0.08em] text-[var(--preview-muted)]">{"api" in account && account.api ? "当前账户" : "当前任务"}</div>
                <div className="mt-1 flex items-center gap-1.5 truncate text-[9px] font-bold text-[var(--preview-ink)]">
                  <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${account.dot}`} />
                  {account.taskText}
                </div>
              </div>
            </div>
            <div className="flex gap-1">
              <button type="button" onClick={selectPrevious} aria-label="上一个账号" className="grid h-6 w-6 place-items-center rounded-full bg-black/[0.045] text-[var(--preview-muted)] transition hover:bg-black/[0.08] dark:bg-white/[0.07] dark:hover:bg-white/10"><ChevronLeft className="h-3 w-3" /></button>
              <button type="button" onClick={selectNext} aria-label="下一个账号" className="grid h-6 w-6 place-items-center rounded-full bg-black/[0.045] text-[var(--preview-muted)] transition hover:bg-black/[0.08] dark:bg-white/[0.07] dark:hover:bg-white/10"><ChevronRight className="h-3 w-3" /></button>
            </div>
          </div>

          <div className="border-t border-black/[0.06] pt-1.5 dark:border-white/[0.07]">
            <div className="px-1 pb-1 text-[7px] font-semibold uppercase tracking-[0.12em] text-[var(--preview-muted)]">账号与额度</div>
            <div className="space-y-0.5">
              {quotaAccounts.map((item, index) => {
                const selected = index === activeIndex;
                return (
                  <button
                    key={item.id}
                    type="button"
                    onClick={() => setActiveIndex(index)}
                    className={`flex w-full items-center gap-2 rounded-xl px-2 py-1.5 text-left transition ${selected ? "bg-emerald-500/[0.09]" : "hover:bg-black/[0.035] dark:hover:bg-white/[0.05]"}`}
                  >
                    <span className="relative h-7 w-7 shrink-0 rounded-[9px] bg-white p-0.5 shadow-sm">
                      <Image src={item.logo} alt={`${item.name} Logo`} width={28} height={28} className="h-full w-full rounded-[7px] object-cover" />
                      <span className={`absolute bottom-0 right-0 h-2 w-2 rounded-full border border-white ${item.dot}`} />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="flex items-baseline gap-1.5">
                        <span className="truncate text-[8.5px] font-bold text-[var(--preview-ink)]">{item.name}</span>
                        <span className="truncate text-[6.5px] text-[var(--preview-muted)]">{item.account}</span>
                      </span>
                      <span className="mt-0.5 block text-[7px] text-[var(--preview-muted)]">{item.state}</span>
                    </span>
                    <span className="shrink-0 text-right tabular-nums">
                      <span className="block text-[8px] font-bold text-[var(--preview-ink)]">{item.primary}</span>
                      <span className="mt-0.5 block text-[6.5px] text-[var(--preview-muted)]">{"api" in item && item.api ? item.secondary : `周 ${item.secondary}`}</span>
                    </span>
                  </button>
                );
              })}
            </div>
          </div>

          <div className="mt-1.5 flex items-center justify-between border-t border-black/[0.06] px-1 pt-2 text-[6.5px] text-[var(--preview-muted)] dark:border-white/[0.07]">
            <span>自动轮播 · 悬停暂停</span>
            <span className="flex gap-1">
              {quotaAccounts.map((item, index) => <button key={item.id} type="button" onClick={() => setActiveIndex(index)} aria-label={`查看 ${item.name} ${item.account}`} className={`h-1.5 rounded-full transition-all ${index === activeIndex ? "w-3 bg-emerald-500" : "w-1.5 bg-black/15 dark:bg-white/20"}`} />)}
            </span>
          </div>
        </div>
      )}
    </div>
  );
}
