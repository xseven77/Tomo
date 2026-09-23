"use client";

import Image from "next/image";
import { ChevronDown, ChevronLeft, ChevronRight } from "lucide-react";
import { useEffect, useState } from "react";
import { StatusBarCapsulePreview } from "./StatusBarCapsulePreview";

const notchItems = [
  { id: "codex-work", name: "Codex", account: "Work", logo: "/brand-assets/codex/color.svg", status: "工作中", task: "重构账户切换逻辑", detail: "正在修改 4 个文件", quota: "5h 82% · 周 76%", dot: "bg-[#2e6bff]" },
  { id: "codex-personal", name: "Codex", account: "Personal", logo: "/brand-assets/codex/color.svg", status: "空闲", task: "当前没有运行任务", detail: "最近同步于 2 分钟前", quota: "5h 54% · 周 91%", dot: "bg-[#aeb5b3]" },
  { id: "kimi", name: "Kimi Code", account: "Personal", logo: "/brand-assets/kimi-code/color.svg", status: "待确认", task: "是否执行完整测试？", detail: "确认后继续运行测试", quota: "5h 28% · 周 63%", dot: "bg-[#f27314]" },
  { id: "deepseek", name: "DeepSeek", account: "Personal Key", logo: "/brand-assets/deepseek/color.svg", status: "余额正常", task: "API Key 可继续使用", detail: "官方余额接口刚刚更新", quota: "¥42.80", dot: "bg-[#1fa55a]" },
] as const;

type DisplayMode = "notch" | "floating";

export function NotchStatusPreview() {
  const [mode, setMode] = useState<DisplayMode>("notch");
  const [activeIndex, setActiveIndex] = useState(0);
  const [hovered, setHovered] = useState(false);
  const [pinned, setPinned] = useState(false);
  const expanded = hovered || pinned;
  const item = notchItems[activeIndex];

  useEffect(() => {
    const timer = window.setInterval(() => {
      setActiveIndex((index) => (index + 1) % notchItems.length);
    }, 3200);
    return () => window.clearInterval(timer);
  }, []);

  const previous = () => setActiveIndex((index) => (index - 1 + notchItems.length) % notchItems.length);
  const next = () => setActiveIndex((index) => (index + 1) % notchItems.length);

  return (
    <section className="mt-28">
      <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <div className="text-[10px] font-bold uppercase tracking-[0.16em] text-emerald-600 dark:text-emerald-400">Notch companion</div>
          <h2 className="mt-1.5 text-xl font-bold tracking-[-0.035em]">把状态与额度收进刘海</h2>
          <p className="mt-1.5 max-w-xl text-sm text-[var(--preview-muted)]">固定宽度避免轮播跳动；悬停刘海向下展开，普通显示器自动使用居中胶囊。</p>
        </div>
        <div className="flex w-fit items-center gap-1 rounded-full border border-[color:var(--preview-line)] bg-[var(--preview-card)]/75 p-1 shadow-sm backdrop-blur" role="group" aria-label="选择显示器类型">
          {([['notch', '刘海屏'], ['floating', '无刘海屏']] as const).map(([id, label]) => (
            <button key={id} type="button" aria-pressed={mode === id} onClick={() => { setMode(id); setPinned(false); setHovered(false); }} className={`h-7 rounded-full px-3 text-[9px] font-semibold transition ${mode === id ? "bg-[var(--preview-primary)] text-[var(--preview-on-primary)]" : "text-[var(--preview-muted)] hover:text-[var(--preview-ink)]"}`}>{label}</button>
          ))}
        </div>
      </div>

      <div className="relative aspect-[720/410] min-h-[410px] overflow-hidden rounded-[28px] border border-white/45 bg-[radial-gradient(circle_at_50%_0%,rgba(88,121,170,0.22),transparent_35%),linear-gradient(145deg,#dce4e5,#bfcfd0_58%,#d8d3cc)] shadow-[0_30px_80px_rgba(28,35,32,0.17)] dark:border-white/10 dark:bg-[radial-gradient(circle_at_50%_0%,rgba(85,105,150,0.13),transparent_35%),linear-gradient(145deg,#1e2325,#111414_60%,#202020)]">
        <div className="absolute inset-x-0 top-0 h-8 border-b border-black/[0.06] bg-white/42 px-4 text-[8px] text-black/50 backdrop-blur-xl dark:border-white/[0.06] dark:bg-black/20 dark:text-white/45">
          <span className="absolute left-4 top-2">Tomo&nbsp;&nbsp;&nbsp; 文件&nbsp;&nbsp;&nbsp; 编辑</span>
          {mode === "notch" ? <span className="absolute right-4 top-2">Wi-Fi&nbsp;&nbsp; 82%&nbsp;&nbsp; 10:28</span> : <div className="absolute right-4 top-0.5"><StatusBarCapsulePreview /></div>}
        </div>

        <div className="absolute left-[8%] top-[24%] h-[44%] w-[38%] rounded-[20px] border border-white/35 bg-white/15 backdrop-blur-[2px] dark:border-white/[0.05] dark:bg-white/[0.02]" />
        <div className="absolute right-[9%] top-[30%] h-[11%] w-[28%] rounded-[14px] bg-white/18 dark:bg-white/[0.025]" />
        <div className="absolute right-[13%] top-[46%] h-[7%] w-[24%] rounded-[12px] bg-white/12 dark:bg-white/[0.02]" />

        {mode === "notch" && <div
          className="absolute left-1/2 top-0 z-30 -translate-x-1/2"
          onMouseEnter={() => setHovered(true)}
          onMouseLeave={() => setHovered(false)}
        >
          <button
            type="button"
            aria-expanded={expanded}
            onClick={() => setPinned((value) => !value)}
            className={`relative block text-white transition-[width,height] duration-300 ease-out ${expanded ? "h-[198px] w-[min(430px,calc(100vw-48px))] drop-shadow-[0_14px_22px_rgba(10,12,12,0.24)]" : mode === "notch" ? "h-10 w-[310px]" : "mt-1 h-8 w-[248px]"}`}
          >
              <span className={`absolute inset-0 bg-[#090a0b] shadow-[0_14px_36px_rgba(10,12,12,0.26)] ${expanded ? "rounded-b-[28px]" : "rounded-b-[19px]"}`} aria-hidden="true" />

            {!expanded && mode === "notch" && <span className="absolute left-1/2 top-0 z-10 h-7 w-[104px] -translate-x-1/2 rounded-b-[15px] bg-black" aria-hidden="true"><span className="absolute left-1/2 top-2 h-1.5 w-1.5 -translate-x-1/2 rounded-full bg-[#17191b] ring-1 ring-white/[0.04]" /></span>}

            {!expanded && (
              <span key={`${mode}-${item.id}`} className="absolute inset-0 z-20 flex animate-[preview-enter_160ms_ease-out] items-center whitespace-nowrap px-3 text-[8px] text-white">
                {mode === "notch" ? (
                  <>
                    <span className="flex w-[91px] items-center gap-1.5"><span className={`h-1.5 w-1.5 rounded-full ${item.dot}`} /><span className="truncate font-semibold">{item.status}</span></span>
                    <span className="w-[104px]" />
                    <span className="flex w-[91px] items-center justify-end gap-1.5"><Image src={item.logo} alt="" width={15} height={15} className="h-[15px] w-[15px] rounded-[5px] bg-white object-cover" /><span className="truncate tabular-nums text-white/70">{item.quota}</span></span>
                  </>
                ) : (
                  <span className="flex w-full items-center justify-center gap-2"><span className={`h-1.5 w-1.5 rounded-full ${item.dot}`} /><span className="font-semibold">{item.status}</span><span className="h-3 w-px bg-white/15" /><Image src={item.logo} alt="" width={15} height={15} className="h-[15px] w-[15px] rounded-[5px] bg-white object-cover" /><span className="tabular-nums text-white/70">{item.quota}</span></span>
                )}
              </span>
            )}

            {expanded && (
              <span className="absolute inset-0 z-20 flex h-full flex-col px-5 pb-3 pt-2.5 text-left text-white">
                <span className="flex h-5 shrink-0 items-center justify-between text-[7px] text-white/45">
                  <span>TOMO · {mode === "notch" ? "内建刘海屏" : "顶部悬浮模式"}</span>
                  <span className="flex items-center gap-1.5"><span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />4 个数据源在线</span>
                </span>

                <span key={item.id} className="mt-1.5 flex shrink-0 animate-[preview-enter_160ms_ease-out] items-center gap-3">
                  <Image src="/brand/tomo-logo.webp" alt="Tomo Pet" width={56} height={56} className="h-14 w-14 shrink-0 object-contain drop-shadow-[0_10px_12px_rgba(0,0,0,0.32)]" />
                  <span className="min-w-0 flex-1">
                    <span className="flex items-center gap-1.5 text-[8px] text-white/50"><span className={`h-1.5 w-1.5 rounded-full ${item.dot}`} />{item.name} · {item.account}</span>
                    <span className="mt-1 block truncate text-[12px] font-bold">{item.task}</span>
                    <span className="mt-1 block truncate text-[8px] text-white/45">{item.status} · {item.detail}</span>
                  </span>
                  <span className="min-w-[98px] rounded-2xl bg-white/[0.08] px-3 py-2 text-right">
                    <span className="block text-[7px] text-white/45">可用额度</span>
                    <span className="mt-1 block text-[11px] font-bold tabular-nums">{item.quota}</span>
                  </span>
                </span>

                <span className="mt-2 flex shrink-0 items-center justify-between border-t border-white/10 pt-2">
                  <span className="flex items-center gap-1.5">
                    {notchItems.map((account, index) => (
                      <span key={account.id} role="button" tabIndex={0} onClick={(event) => { event.stopPropagation(); setActiveIndex(index); }} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); event.stopPropagation(); setActiveIndex(index); } }} className={`relative grid h-8 w-8 place-items-center rounded-[10px] transition ${index === activeIndex ? "bg-white/15" : "bg-white/[0.04] hover:bg-white/10"}`}>
                        <Image src={account.logo} alt={`${account.name} ${account.account}`} width={24} height={24} className="h-6 w-6 rounded-[7px] bg-white object-cover" />
                        <span className={`absolute bottom-0.5 right-0.5 h-2 w-2 rounded-full border border-[#151617] ${account.dot}`} />
                      </span>
                    ))}
                  </span>
                  <span className="flex gap-1.5">
                    <span role="button" tabIndex={0} onClick={(event) => { event.stopPropagation(); previous(); }} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); event.stopPropagation(); previous(); } }} className="grid h-7 w-7 place-items-center rounded-full bg-white/[0.08] text-white/60 transition hover:bg-white/15"><ChevronLeft className="h-3.5 w-3.5" /></span>
                    <span role="button" tabIndex={0} onClick={(event) => { event.stopPropagation(); next(); }} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") { event.preventDefault(); event.stopPropagation(); next(); } }} className="grid h-7 w-7 place-items-center rounded-full bg-white/[0.08] text-white/60 transition hover:bg-white/15"><ChevronRight className="h-3.5 w-3.5" /></span>
                  </span>
                </span>

                <span className="mt-auto flex shrink-0 items-center justify-between border-t border-white/[0.07] pt-2 text-[7px] text-white/45">
                  <span className="flex items-center gap-2.5"><span>3 个本地任务</span><span className="flex items-center gap-1"><span className="h-1.5 w-1.5 rounded-full bg-orange-500" />1 个待确认</span></span>
                  <span role="button" tabIndex={0} onClick={(event) => event.stopPropagation()} onKeyDown={(event) => { if (event.key === "Enter" || event.key === " ") event.stopPropagation(); }} className="rounded-full bg-white/[0.08] px-2.5 py-1 font-semibold text-white/75 transition hover:bg-white/15">打开当前任务&nbsp; ›</span>
                </span>
              </span>
            )}
          </button>
          {!expanded && <div className="pointer-events-none mx-auto mt-1 flex w-fit items-center gap-1 text-[7px] text-black/35 dark:text-white/35"><ChevronDown className="h-3 w-3" />悬停展开</div>}
        </div>}

        <div className="absolute bottom-5 left-1/2 -translate-x-1/2 whitespace-nowrap rounded-full border border-white/35 bg-white/30 px-3 py-1.5 text-[8px] text-black/45 backdrop-blur-xl dark:border-white/10 dark:bg-black/15 dark:text-white/45">{mode === "notch" ? "中央避让摄像头 · 悬停向下展开" : "回退到原始状态栏胶囊 · 保留原有流光"}</div>
      </div>
    </section>
  );
}
