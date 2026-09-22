"use client";

import Image from "next/image";
import { Check, ChevronDown, ChevronLeft, ChevronRight, ChevronUp, CornerUpLeft, Square } from "lucide-react";
import { useState } from "react";
import { StatusBarCapsulePreview } from "./StatusBarCapsulePreview";

type PetEdge = "top" | "right" | "bottom" | "left";

const desktopTasks = [
  { id: "codex-1", agent: "Codex", logo: "/brand-assets/codex/color.svg", title: "重构账户切换逻辑", detail: "正在修改 4 个文件", state: "工作中", dot: "bg-violet-500" },
  { id: "kimi-1", agent: "Kimi Code", logo: "/brand-assets/kimi-code/color.svg", title: "是否执行完整测试？", detail: "等待你的确认", state: "待确认", dot: "bg-orange-500" },
  { id: "qwen-1", agent: "Qwen Code", logo: "/brand-assets/qwen-code/color.svg", title: "补充本地 Hook 兼容层", detail: "正在思考", state: "思考中", dot: "bg-blue-500" },
  { id: "codex-2", agent: "Codex", logo: "/brand-assets/codex/color.svg", title: "排查 Pet 边缘定位", detail: "运行本地预览", state: "工作中", dot: "bg-violet-500" },
  { id: "kimi-2", agent: "Kimi Code", logo: "/brand-assets/kimi-code/color.svg", title: "验证横竖屏布局", detail: "已完成", state: "已完成", dot: "bg-emerald-500" },
  { id: "qwen-2", agent: "Qwen Code", logo: "/brand-assets/qwen-code/color.svg", title: "整理任务摘要", detail: "Hooks 已就绪", state: "空闲", dot: "bg-slate-300" },
] as const;

const edgeLabels: Array<{ id: PetEdge; label: string }> = [
  { id: "top", label: "靠上" },
  { id: "right", label: "靠右" },
  { id: "bottom", label: "靠下" },
  { id: "left", label: "靠左" },
];

const petPlacement: Record<PetEdge, string> = {
  top: "left-1/2 top-12 -translate-x-1/2",
  right: "right-5 top-1/2 -translate-y-1/2",
  bottom: "bottom-5 left-1/2 -translate-x-1/2",
  left: "left-5 top-1/2 -translate-y-1/2",
};

const stackPlacement: Record<PetEdge, string> = {
  top: "left-1/2 top-[178px] -translate-x-1/2",
  right: "right-[158px] top-1/2 -translate-y-1/2",
  bottom: "bottom-[158px] left-1/2 -translate-x-1/2",
  left: "left-[158px] top-1/2 -translate-y-1/2",
};

function EdgeChevron({ edge, expanded }: { edge: PetEdge; expanded: boolean }) {
  const className = "h-3.5 w-3.5";
  if (!expanded) {
    if (edge === "top") return <ChevronDown className={className} />;
    if (edge === "bottom") return <ChevronUp className={className} />;
    if (edge === "left") return <ChevronRight className={className} />;
    return <ChevronLeft className={className} />;
  }
  if (edge === "top") return <ChevronUp className={className} />;
  if (edge === "bottom") return <ChevronDown className={className} />;
  if (edge === "left") return <ChevronLeft className={className} />;
  return <ChevronRight className={className} />;
}

export function DesktopPetTaskPreview() {
  const [edge, setEdge] = useState<PetEdge>("bottom");
  const [expanded, setExpanded] = useState(true);
  const [selectedId, setSelectedId] = useState("kimi-1");
  const [taskLimit, setTaskLimit] = useState<3 | 6>(6);
  const [feedback, setFeedback] = useState<string>();
  const visibleTasks = desktopTasks.slice(0, taskLimit);

  const showFeedback = (message: string) => {
    setFeedback(message);
    window.setTimeout(() => setFeedback(undefined), 1800);
  };

  return (
    <section className="mt-28">
      <div className="mb-5 flex flex-col gap-3 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <div className="text-[10px] font-bold uppercase tracking-[0.16em] text-emerald-600 dark:text-emerald-400">Desktop Pet</div>
          <h2 className="mt-1.5 text-xl font-bold tracking-[-0.035em]">多任务与屏幕边缘适配</h2>
          <p className="mt-1.5 text-sm text-[var(--preview-muted)]">Pet 根据屏幕可用空间自动调整任务栈方向；账号 Tab 不影响这里的本地任务。</p>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <div className="flex items-center gap-1 rounded-full border border-[color:var(--preview-line)] bg-[var(--preview-card)]/75 p-1 shadow-sm backdrop-blur" role="group" aria-label="选择 Pet 所在的屏幕边缘">
            {edgeLabels.map((item) => <button key={item.id} type="button" aria-pressed={edge === item.id} onClick={() => setEdge(item.id)} className={`h-7 rounded-full px-2.5 text-[9px] font-semibold transition ${edge === item.id ? "bg-[var(--preview-primary)] text-[var(--preview-on-primary)]" : "text-[var(--preview-muted)] hover:text-[var(--preview-ink)]"}`}>{item.label}</button>)}
          </div>
          <div className="flex items-center gap-1 rounded-full border border-[color:var(--preview-line)] bg-[var(--preview-card)]/75 p-1 shadow-sm backdrop-blur" role="group" aria-label="选择任务数量">
            {([3, 6] as const).map((count) => <button key={count} type="button" aria-pressed={taskLimit === count} onClick={() => { setTaskLimit(count); setExpanded(true); }} className={`h-7 rounded-full px-2.5 text-[9px] font-semibold transition ${taskLimit === count ? "bg-[var(--preview-primary)] text-[var(--preview-on-primary)]" : "text-[var(--preview-muted)] hover:text-[var(--preview-ink)]"}`}>{count === 3 ? "少量任务" : "多任务"}</button>)}
          </div>
        </div>
      </div>

      <div className="relative aspect-[720/470] min-h-[410px] overflow-hidden rounded-[26px] border border-white/45 bg-[radial-gradient(circle_at_75%_65%,rgba(71,179,128,0.15),transparent_31%),linear-gradient(145deg,#e8eeeb,#dde4e0_56%,#e9e6e1)] shadow-[0_30px_80px_rgba(28,35,32,0.16)] dark:border-white/10 dark:bg-[radial-gradient(circle_at_75%_65%,rgba(35,190,120,0.11),transparent_31%),linear-gradient(145deg,#242a28,#171a1a_58%,#202020)]">
        <div className="absolute inset-x-0 top-0 flex h-9 items-center border-b border-black/[0.06] bg-white/48 px-4 text-[9px] text-black/60 backdrop-blur-xl dark:border-white/[0.07] dark:bg-black/20 dark:text-white/60">
          <span className="font-bold text-black/75 dark:text-white/80">Tomo</span><span className="ml-4">Pet</span><span className="ml-4">设置</span>
          <StatusBarCapsulePreview />
        </div>

        <div className="absolute left-[7%] top-[23%] h-[31%] w-[35%] rounded-[18px] border border-white/35 bg-white/15 backdrop-blur-[2px] dark:border-white/[0.05] dark:bg-white/[0.02]" />
        <div className="absolute left-[11%] top-[30%] h-2 w-[21%] rounded-full bg-black/[0.05] dark:bg-white/[0.05]" />
        <div className="absolute left-[11%] top-[36%] h-2 w-[15%] rounded-full bg-black/[0.03] dark:bg-white/[0.035]" />

        <div className={`absolute z-20 ${petPlacement[edge]}`}>
          <button type="button" onClick={() => setExpanded((value) => !value)} aria-label={expanded ? "收起 Pet 任务" : `展开 ${visibleTasks.length} 个 Pet 任务`} className="group relative block">
            {!expanded && <span className="absolute -right-1 top-0 z-10 grid h-7 min-w-7 place-items-center rounded-full border border-white/55 bg-blue-500/80 px-1.5 text-[10px] font-bold text-white shadow-lg backdrop-blur dark:border-white/15">{visibleTasks.length}</span>}
            <Image src="/brand/codexling-logo.webp" alt="桌面 Tomo Pet" width={126} height={126} className="h-[116px] w-[116px] animate-float drop-shadow-[0_22px_20px_rgba(20,35,27,0.24)] transition-transform group-hover:scale-[1.03]" />
          </button>
          <button type="button" onClick={() => setExpanded((value) => !value)} aria-label={expanded ? "收起任务栈" : "展开任务栈"} className={`absolute grid h-7 w-7 place-items-center rounded-full border border-white/55 bg-white/45 text-black/45 shadow-sm backdrop-blur-xl dark:border-white/15 dark:bg-white/10 dark:text-white/60 ${edge === "top" ? "-right-3 top-0" : edge === "bottom" ? "-right-3 top-0" : edge === "left" ? "right-0 -top-2" : "left-0 -top-2"}`}><EdgeChevron edge={edge} expanded={expanded} /></button>
        </div>

        {expanded && (
          <div className={`absolute z-10 w-[min(340px,calc(100%-32px))] animate-[preview-enter_190ms_ease-out] ${stackPlacement[edge]}`}>
            <div className={`overflow-y-auto overscroll-contain pr-1 [scrollbar-color:rgba(120,130,140,0.28)_transparent] [scrollbar-width:thin] ${taskLimit > 3 ? "max-h-[205px] [mask-image:linear-gradient(to_bottom,transparent_0,black_10px,black_calc(100%-14px),transparent_100%)] py-2.5" : "max-h-[205px]"}`}>
              <div className="space-y-1.5">
                {visibleTasks.map((task) => {
                  const selected = task.id === selectedId;
                  return (
                    <button key={task.id} type="button" onClick={() => setSelectedId(task.id)} className={`group relative flex min-h-[50px] w-full items-center gap-2.5 rounded-full border px-3 py-1.5 text-left shadow-[0_8px_22px_rgba(30,38,34,0.09)] backdrop-blur-xl transition ${selected ? "border-white/80 bg-white/88 dark:border-white/15 dark:bg-white/14" : "border-white/50 bg-white/68 hover:bg-white/82 dark:border-white/10 dark:bg-white/[0.075] dark:hover:bg-white/10"}`}>
                      <span className="relative h-7 w-7 shrink-0 overflow-hidden rounded-[9px] bg-white dark:bg-white/90"><Image src={task.logo} alt={`${task.agent} Logo`} width={28} height={28} className="h-full w-full object-cover" /><span className={`absolute bottom-0.5 right-0.5 h-2 w-2 rounded-full border border-white ${task.dot}`} /></span>
                      <span className="min-w-0 flex-1"><span className="flex items-center gap-1.5"><span className="truncate text-[9.5px] font-bold text-[var(--preview-ink)]">{task.title}</span><span className="shrink-0 text-[6.5px] font-semibold text-[var(--preview-muted)]">{task.agent}</span></span><span className="mt-0.5 block truncate text-[7.5px] text-[var(--preview-muted)]">{task.state} · {task.detail}</span></span>
                      {selected ? <span className="flex shrink-0 gap-1"><span onClick={(event) => { event.stopPropagation(); showFeedback(`${task.agent} 任务已退回`); }} className="grid h-6 w-6 place-items-center rounded-full bg-black/[0.055] text-[var(--preview-muted)] dark:bg-white/10"><CornerUpLeft className="h-3 w-3" /></span><span onClick={(event) => { event.stopPropagation(); showFeedback(`${task.agent} 任务已停止`); }} className="grid h-6 w-6 place-items-center rounded-full bg-black/[0.055] text-[var(--preview-muted)] dark:bg-white/10"><Square className="h-2.5 w-2.5 fill-current" /></span></span> : <ChevronRight className="h-3 w-3 shrink-0 text-[var(--preview-muted)] opacity-0 transition group-hover:opacity-100" />}
                    </button>
                  );
                })}
              </div>
            </div>
          </div>
        )}

        <div className="absolute bottom-4 left-4 flex items-center gap-3 rounded-full border border-white/45 bg-white/42 px-3 py-2 text-[8px] text-black/55 backdrop-blur-xl dark:border-white/10 dark:bg-black/15 dark:text-white/55">
          <span className="flex items-center gap-1"><span className="h-1.5 w-1.5 rounded-full bg-violet-500" />工作中</span><span className="flex items-center gap-1"><span className="h-1.5 w-1.5 rounded-full bg-blue-500" />思考中</span><span className="flex items-center gap-1"><span className="h-1.5 w-1.5 rounded-full bg-orange-500" />待确认</span><span className="flex items-center gap-1"><span className="h-1.5 w-1.5 rounded-full bg-emerald-500" />已完成</span>
        </div>
        {feedback && <div className="pointer-events-none absolute bottom-4 left-1/2 z-40 flex -translate-x-1/2 items-center gap-1.5 rounded-full bg-[#17191d]/92 px-3.5 py-2 text-[8px] font-semibold text-white shadow-xl animate-[preview-toast_220ms_ease-out]"><Check className="h-3 w-3 text-emerald-400" />{feedback}</div>}
      </div>
    </section>
  );
}
