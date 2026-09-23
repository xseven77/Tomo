"use client";

import Image from "next/image";
import type { CSSProperties } from "react";
import { useEffect, useMemo, useSyncExternalStore, useState } from "react";
import { ChevronDown, ChevronLeft, ChevronRight, Pin } from "lucide-react";
import {
  agents,
  providers,
  agentLabelOf,
  agentDotClassOf,
  agentColorOf,
  activeAgentCount,
  waitingCount,
  type AgentSource,
  type ProviderSource,
} from "./demo-data";
export { agentStateMeta } from "./demo-data";

function subscribeReduceMotion(callback: () => void): () => void {
  const mq = window.matchMedia("(prefers-reduced-motion: reduce)");
  mq.addEventListener("change", callback);
  return () => mq.removeEventListener("change", callback);
}

function getReduceMotionSnapshot(): boolean {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

/** 设备模拟：仅「刘海主屏」允许启用刘海方案 */
type DeviceKind = "notch-primary" | "plain-primary" | "secondary";
type ModeChoice = "auto" | "notch" | "legacy";

const devices: { id: DeviceKind; label: string; hint: string }[] = [
  { id: "notch-primary", label: "刘海主屏", hint: "MacBook 主屏，safeAreaInsets.top > 0" },
  { id: "plain-primary", label: "无刘海主屏", hint: "iMac / 外接屏做主屏" },
  { id: "secondary", label: "副屏", hint: "菜单栏位于副屏或刘海被外接覆盖" },
];

const modeChoices: { id: ModeChoice; label: string }[] = [
  { id: "auto", label: "自动（按设备）" },
  { id: "notch", label: "刘海屏方案" },
  { id: "legacy", label: "降级胶囊" },
];

function resolveMode(device: DeviceKind, choice: ModeChoice): "notch" | "legacy" {
  if (choice !== "auto") return choice;
  return device === "notch-primary" ? "notch" : "legacy";
}

export function NotchCompanionDemo() {
  const [device, setDevice] = useState<DeviceKind>("notch-primary");
  const [choice, setChoice] = useState<ModeChoice>("auto");
  const [agentIndex, setAgentIndex] = useState(0);
  const [providerIndex, setProviderIndex] = useState(0);
  const [hovered, setHovered] = useState(false);
  const [pinned, setPinned] = useState(false);
  const [legacyOpen, setLegacyOpen] = useState(false);

  const reduceMotion = useSyncExternalStore(
    subscribeReduceMotion,
    getReduceMotionSnapshot,
    () => false,
  );

  const mode = resolveMode(device, choice);
  const expanded = hovered || pinned;
  const agent = agents[agentIndex];
  const provider = providers[providerIndex];

  const routingHint = useMemo(() => {
    const reason =
      device === "notch-primary"
        ? "主屏 · safeAreaInsets.top=32pt → 启用刘海屏方案"
        : device === "plain-primary"
          ? "主屏但无刘海（safeAreaInsets.top=0）→ 降级原始胶囊"
          : "非主显示器 → 降级原始胶囊";
    const actual = resolveMode(device, "auto");
    return { reason, actual };
  }, [device]);

  // agent 与 provider 是否处于轮播中（展开态 / 下拉展开时暂停）
  const rotating = mode === "notch" ? !expanded : !legacyOpen;

  // 左区 agent 状态独立轮播（2.8s）
  useEffect(() => {
    if (reduceMotion || !rotating) return;
    const timer = window.setInterval(
      () => setAgentIndex((i) => (i + 1) % agents.length),
      2800,
    );
    return () => window.clearInterval(timer);
  }, [reduceMotion, rotating]);

  // 右区 provider 额度独立轮播（3.6s，节奏错开）
  useEffect(() => {
    if (reduceMotion || !rotating) return;
    const timer = window.setInterval(
      () => setProviderIndex((i) => (i + 1) % providers.length),
      3600,
    );
    return () => window.clearInterval(timer);
  }, [reduceMotion, rotating]);

  // Esc 关闭展开态
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setPinned(false);
        setLegacyOpen(false);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const previousAgent = () => setAgentIndex((i) => (i - 1 + agents.length) % agents.length);
  const nextAgent = () => setAgentIndex((i) => (i + 1) % agents.length);

  return (
    <section className="mt-14">
      {/* 标题 */}
      <div className="mb-4">
        <div className="text-[10px] font-bold uppercase tracking-[0.16em] text-emerald-600 dark:text-emerald-400">
          Notch companion · 运行时分支
        </div>
        <h2 className="mt-1.5 text-xl font-bold tracking-[-0.035em]">刘海屏伴侣 · 布局方案（重构稿）</h2>
        <p className="mt-1.5 max-w-2xl text-sm leading-6 text-[var(--preview-muted)]">
          刘海屏只在 <b className="text-[var(--preview-ink)]">主显示器且为刘海屏</b> 时启用。agent 状态与供应商额度
          <b className="text-[var(--preview-ink)]">各自独立轮播</b>（Codex 可登录多个账号、API Key 无对应 agent）；
          展开后左列用箭头切换 agent、右列点供应商 logo 切换额度。
        </p>
      </div>

      {/* 控制面板 */}
      <div className="flex flex-wrap items-center gap-x-6 gap-y-3 rounded-2xl border border-[color:var(--preview-line)] bg-[var(--preview-card)]/70 p-4 backdrop-blur">
        <div>
          <div className="mb-1.5 text-[9px] font-semibold uppercase tracking-[0.1em] text-[var(--preview-muted)]">① 设备 / 屏幕模拟</div>
          <div className="flex w-fit items-center gap-1 rounded-full border border-[color:var(--preview-line)] bg-[var(--preview-panel)] p-1" role="group" aria-label="选择设备">
            {devices.map((item) => (
              <button
                key={item.id}
                type="button"
                aria-pressed={device === item.id}
                onClick={() => setDevice(item.id)}
                title={item.hint}
                className={`h-7 rounded-full px-3 text-[9px] font-semibold transition ${device === item.id ? "bg-[var(--preview-primary)] text-[var(--preview-on-primary)]" : "text-[var(--preview-muted)] hover:text-[var(--preview-ink)]"}`}
              >
                {item.label}
              </button>
            ))}
          </div>
        </div>
        <div>
          <div className="mb-1.5 text-[9px] font-semibold uppercase tracking-[0.1em] text-[var(--preview-muted)]">② 显示方案（可手动覆盖）</div>
          <div className="flex w-fit items-center gap-1 rounded-full border border-[color:var(--preview-line)] bg-[var(--preview-panel)] p-1" role="group" aria-label="选择显示方案">
            {modeChoices.map((item) => (
              <button
                key={item.id}
                type="button"
                aria-pressed={choice === item.id}
                onClick={() => setChoice(item.id)}
                className={`h-7 rounded-full px-3 text-[9px] font-semibold transition ${choice === item.id ? "bg-[var(--preview-primary)] text-[var(--preview-on-primary)]" : "text-[var(--preview-muted)] hover:text-[var(--preview-ink)]"}`}
              >
                {item.label}
              </button>
            ))}
          </div>
        </div>
        <div className="min-w-0 flex-1">
          <div className="mb-1.5 text-[9px] font-semibold uppercase tracking-[0.1em] text-[var(--preview-muted)]">③ 自动路由结果</div>
          <div className={`flex items-center gap-2 rounded-xl px-3 py-2 text-[10px] ${routingHint.actual === "notch" ? "bg-emerald-500/[0.09] text-emerald-700 dark:text-emerald-400" : "bg-[var(--preview-panel)] text-[var(--preview-muted)]"}`}>
            <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${routingHint.actual === "notch" ? "bg-emerald-500" : "bg-[var(--preview-muted)]"}`} />
            <span className="truncate">
              自动 → <b className={routingHint.actual === "notch" ? "" : "text-[var(--preview-ink)]"}>{routingHint.actual === "notch" ? "刘海屏方案" : "降级胶囊"}</b>
              <span className="ml-2 hidden sm:inline opacity-70">{routingHint.reason}</span>
            </span>
          </div>
        </div>
      </div>

      {/* ==================== 演示画布 ==================== */}
      <div className="relative mx-auto mt-6 w-full max-w-3xl overflow-visible rounded-[26px] border border-white/45 bg-[radial-gradient(circle_at_50%_0%,rgba(88,121,170,0.20),transparent_38%),linear-gradient(160deg,#e6ebea,#c8d4d3_55%,#dcd6cc)] shadow-[0_30px_70px_rgba(28,35,32,0.15)] dark:border-white/10 dark:bg-[radial-gradient(circle_at_50%_0%,rgba(85,105,150,0.12),transparent_38%),linear-gradient(160deg,#202427,#121515_58%,#232222)]">
        {/* 画布主体：菜单栏 / 刘海 / 胶囊 同层叠放 */}
        <div className="relative h-[272px]">
          {/* 菜单栏（z-10）：内容在刘海两侧避让；降级胶囊嵌在右侧与系统图标同级 */}
          <div className="absolute inset-x-0 top-0 z-10 flex h-8 items-center justify-between border-b border-black/[0.06] bg-white/45 px-4 text-[8px] text-black/50 backdrop-blur-xl dark:border-white/[0.06] dark:bg-black/25 dark:text-white/45">
            <span className="truncate">Tomo&nbsp;&nbsp;&nbsp;文件&nbsp;&nbsp;&nbsp;编辑&nbsp;&nbsp;&nbsp;显示&nbsp;&nbsp;&nbsp;窗口&nbsp;&nbsp;&nbsp;帮助</span>
            <span className="flex shrink-0 items-center gap-3">
              {mode === "legacy" && (
                <LegacyCapsule
                  agent={agent}
                  provider={provider}
                  providerIndex={providerIndex}
                  open={legacyOpen}
                  onToggle={() => setLegacyOpen((v) => !v)}
                  onHoverChange={setLegacyOpen}
                  onSelectProvider={setProviderIndex}
                />
              )}
              <span>Wi-Fi</span><span>82%</span><span className="tabular-nums">10:28</span>
            </span>
          </div>

          {mode === "notch" && (
            <NotchCapsule
              agent={agent}
              provider={provider}
              agentIndex={agentIndex}
              providerIndex={providerIndex}
              expanded={expanded}
              onHoverChange={setHovered}
              onTogglePin={() => setPinned((v) => !v)}
              onPreviousAgent={previousAgent}
              onNextAgent={nextAgent}
              onSelectProvider={setProviderIndex}
            />
          )}
        </div>

        {/* 底部说明条 */}
        <div className="absolute bottom-3 left-1/2 z-10 -translate-x-1/2 whitespace-nowrap rounded-full border border-white/35 bg-white/35 px-3 py-1.5 text-[8px] text-black/45 backdrop-blur-xl dark:border-white/10 dark:bg-black/20 dark:text-white/45">
          {mode === "notch"
            ? "刘海自屏幕顶边伸下 · 胶囊悬挂其正下方 · 左区 Agent 状态（2.8s） / 右区供应商额度（3.6s）独立轮播"
            : "降级原始胶囊 · 状态与额度独立轮播 · 边缘流光跟随状态色"}
        </div>
      </div>

      {/* 演示数据说明 */}
      <div className="mt-4 grid gap-3 sm:grid-cols-3">
        <MiniStat label="活跃 Agent（同时工作）" value={activeAgentCount} tone="blue" />
        <MiniStat label="账号 / API Key 数据源" value={providers.length} tone="green" />
        <MiniStat label="待确认任务" value={waitingCount} tone="amber" />
      </div>
    </section>
  );
}

/* ==================== 刘海胶囊 ==================== */

interface NotchCapsuleProps {
  agent: AgentSource;
  provider: ProviderSource;
  agentIndex: number;
  providerIndex: number;
  expanded: boolean;
  onHoverChange: (hovering: boolean) => void;
  onTogglePin: () => void;
  onPreviousAgent: () => void;
  onNextAgent: () => void;
  onSelectProvider: (index: number) => void;
}

function NotchCapsule({
  agent,
  provider,
  agentIndex,
  providerIndex,
  expanded,
  onHoverChange,
  onTogglePin,
  onPreviousAgent,
  onNextAgent,
  onSelectProvider,
}: NotchCapsuleProps) {
  return (
    <div
      className="absolute inset-x-0 top-0 z-30"
      onMouseEnter={() => onHoverChange(true)}
      onMouseLeave={() => onHoverChange(false)}
    >
      {/* 胶囊按钮：从屏幕顶边（top-0）开始，居中；刘海是其顶部中央的视觉元素 */}
      <button
        type="button"
        aria-expanded={expanded}
        aria-label="查看当前任务状态与账号额度"
        onClick={onTogglePin}
        className={`relative mx-auto block text-left text-white transition-[width,height] duration-300 ease-out ${expanded ? "h-[236px] w-[min(452px,calc(100vw-32px))] drop-shadow-[0_18px_30px_rgba(10,12,12,0.30)]" : "h-10 w-[310px] drop-shadow-[0_8px_18px_rgba(10,12,12,0.28)]"}`}
      >
        <span
          aria-hidden="true"
          className={`absolute inset-0 bg-[#090a0b] shadow-[0_10px_26px_rgba(10,12,12,0.28)] ${expanded ? "rounded-b-[26px]" : "rounded-b-[19px]"}`}
        />

        {!expanded && (
          <>
            {/* 刘海：胶囊顶部中央的黑色块 + 摄像头，从屏幕顶边伸下 */}
            <span className="absolute left-1/2 top-0 z-10 h-7 w-[104px] -translate-x-1/2 rounded-b-[15px] bg-black" aria-hidden="true">
              <span className="absolute left-1/2 top-2 h-1.5 w-1.5 -translate-x-1/2 rounded-full bg-[#17191b] ring-1 ring-white/[0.04]" />
            </span>
            {/* 内容：左区 91 / 中央 104 避让 / 右区 91 */}
            <span className="absolute inset-0 z-20 flex items-center whitespace-nowrap px-3 text-[8px]">
              {/* 左区：Agent logo + 状态（91pt，独立轮播） */}
              <span key={`n-agent-${agent.id}`} className="flex w-[91px] animate-[preview-enter_160ms_ease-out] items-center gap-1.5">
                <Image src={agent.logo} alt="" width={14} height={14} className="h-[14px] w-[14px] shrink-0 rounded-[4px] bg-white object-cover" />
                <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${agentDotClassOf(agent)}`} />
                <span className="truncate font-semibold">{agentLabelOf(agent)}</span>
              </span>
              {/* 中央：刘海避让区（104pt） */}
              <span className="w-[104px] shrink-0" aria-hidden="true" />
              {/* 右区：供应商 logo + 额度（91pt，独立轮播） */}
              <span key={`n-provider-${provider.id}`} className="flex w-[91px] animate-[preview-enter_160ms_ease-out] items-center justify-end gap-1.5">
                <Image src={provider.logo} alt="" width={15} height={15} className="h-[15px] w-[15px] shrink-0 rounded-[5px] bg-white object-cover" />
                <span className="truncate tabular-nums text-white/70">{provider.quota.compact}</span>
              </span>
            </span>
          </>
        )}

        {expanded && (
          <span className="absolute inset-0 z-20 flex h-full flex-col px-5 pb-3 pt-2.5 text-left">
            {/* 头部 */}
            <span className="flex h-5 shrink-0 items-center justify-between text-[7px] text-white/45">
              <span className="flex items-center gap-1.5">
                <Image src="/brand/tomo-logo.webp" alt="Tomo Pet" width={16} height={16} className="h-4 w-4 object-contain" />
                TOMO · 内建刘海屏
              </span>
              <span className="flex items-center gap-1.5">
                <span className="h-1.5 w-1.5 rounded-full bg-emerald-400" />
                {providers.length} 个数据源在线
              </span>
            </span>

            {/* 主体：左列 agent（箭头切换） / 右列 provider（logo 切换） */}
            <span className="mt-1.5 flex min-h-0 flex-1 items-stretch gap-3">
              {/* 左列：Agent 运行状态 */}
              <span className="flex min-w-0 flex-1 flex-col border-r border-white/10 pr-3">
                <span key={`e-agent-${agent.id}`} className="flex min-h-0 flex-1 animate-[preview-enter_160ms_ease-out] flex-col">
                  <span className="flex items-center gap-1.5 text-[8px] text-white/50">
                    <Image src={agent.logo} alt="" width={18} height={18} className="h-[18px] w-[18px] shrink-0 rounded-[6px] bg-white object-cover" />
                    <span className="truncate">{agent.agentName} · {agent.accountName}</span>
                  </span>
                  <span className="mt-1.5 flex items-center gap-1.5 text-[9px] font-semibold">
                    <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${agentDotClassOf(agent)}`} />
                    {agentLabelOf(agent)}
                  </span>
                  <span className="mt-1 block truncate text-[11px] font-bold leading-tight">{agent.taskTitle}</span>
                  <span className="mt-0.5 block truncate text-[7.5px] text-white/45">{agent.taskDetail}</span>
                </span>
                <span className="mt-2 flex shrink-0 items-center justify-between">
                  <span role="button" tabIndex={0} aria-label="上一个 Agent" onClick={(e) => { e.stopPropagation(); onPreviousAgent(); }} onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); e.stopPropagation(); onPreviousAgent(); } }} className="grid h-6 w-6 place-items-center rounded-full bg-white/[0.08] text-white/60 transition hover:bg-white/15">
                    <ChevronLeft className="h-3 w-3" />
                  </span>
                  <span className="text-[7px] tabular-nums text-white/40">{agentIndex + 1} / {agents.length}</span>
                  <span role="button" tabIndex={0} aria-label="下一个 Agent" onClick={(e) => { e.stopPropagation(); onNextAgent(); }} onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); e.stopPropagation(); onNextAgent(); } }} className="grid h-6 w-6 place-items-center rounded-full bg-white/[0.08] text-white/60 transition hover:bg-white/15">
                    <ChevronRight className="h-3 w-3" />
                  </span>
                </span>
              </span>

              {/* 右列：供应商额度 */}
              <span className="flex w-[150px] shrink-0 flex-col">
                <span key={`e-provider-${provider.id}`} className="flex min-h-0 flex-1 animate-[preview-enter_160ms_ease-out] flex-col">
                  <span className="flex items-center justify-between gap-1.5">
                    <span className="truncate text-[8px] text-white/50">{provider.providerName} · {provider.accountName}</span>
                    <Image src={provider.logo} alt="" width={18} height={18} className="h-[18px] w-[18px] shrink-0 rounded-[6px] bg-white object-cover" />
                  </span>
                  <span className="mt-1.5 block text-[7px] text-white/45">可用额度</span>
                  <span className="mt-1 block truncate text-[13px] font-bold leading-tight tabular-nums">{provider.quota.primary}</span>
                  <span className="block truncate text-[7.5px] text-white/45">{provider.quota.secondary}</span>
                </span>
                <span className="mt-2 flex shrink-0 items-center gap-1.5">
                  {providers.map((p, index) => (
                    <span
                      key={p.id}
                      role="button"
                      tabIndex={0}
                      aria-label={`${p.providerName} ${p.accountName}`}
                      onClick={(e) => { e.stopPropagation(); onSelectProvider(index); }}
                      onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); e.stopPropagation(); onSelectProvider(index); } }}
                      className={`relative grid h-7 w-7 shrink-0 place-items-center rounded-[9px] transition ${index === providerIndex ? "bg-white/15 ring-1 ring-white/25" : "bg-white/[0.04] hover:bg-white/10"}`}
                    >
                      <Image src={p.logo} alt="" width={20} height={20} className="h-5 w-5 rounded-[6px] bg-white object-cover" />
                      {index === providerIndex && <span className="absolute -bottom-1 left-1/2 h-1 w-1 -translate-x-1/2 rounded-full bg-white" />}
                    </span>
                  ))}
                </span>
              </span>
            </span>

            {/* 底部：本地任务概览 + 固定提示 */}
            <span className="mt-2 flex shrink-0 items-center justify-between border-t border-white/[0.07] pt-2 text-[7px] text-white/45">
              <span className="flex items-center gap-2.5">
                <span>{activeAgentCount} 个本地任务</span>
                {waitingCount > 0 && (
                  <span className="flex items-center gap-1">
                    <span className="h-1.5 w-1.5 rounded-full bg-orange-500" />
                    {waitingCount} 个待确认
                  </span>
                )}
              </span>
              <span className="flex items-center gap-2">
                <span className="rounded-full bg-white/[0.08] px-2.5 py-1 font-semibold text-white/75 transition hover:bg-white/15">打开当前任务&nbsp;›</span>
                <span className="flex items-center gap-1 opacity-70">
                  <Pin className="h-2.5 w-2.5" />
                  已固定 · Esc 收起
                </span>
              </span>
            </span>
          </span>
        )}
      </button>

      {!expanded && (
        <div className="pointer-events-none mx-auto mt-1 flex w-fit items-center gap-1 text-[7px] text-black/35 dark:text-white/35">
          <ChevronDown className="h-3 w-3" />
          悬停展开 · 点击固定
        </div>
      )}
    </div>
  );
}

/* ==================== 降级胶囊（原始方案） ==================== */

interface LegacyCapsuleProps {
  agent: AgentSource;
  provider: ProviderSource;
  providerIndex: number;
  open: boolean;
  onToggle: () => void;
  onHoverChange: (open: boolean) => void;
  onSelectProvider: (index: number) => void;
}

function LegacyCapsule({ agent, provider, providerIndex, open, onToggle, onHoverChange, onSelectProvider }: LegacyCapsuleProps) {
  return (
    <div
      className="relative shrink-0"
      onMouseEnter={() => onHoverChange(true)}
      onMouseLeave={() => onHoverChange(false)}
    >
      <button
        type="button"
        aria-expanded={open}
        aria-label="查看当前任务状态与账号额度"
        onClick={onToggle}
        className="status-capsule-flow relative flex h-7 w-[218px] items-center justify-center overflow-hidden rounded-full px-2.5 text-[8px] font-medium text-[var(--preview-ink)] transition hover:-translate-y-px"
        style={{ "--capsule-flow-color": agentColorOf(agent) } as CSSProperties}
      >
        <span className="status-capsule-flow__inner" />
        <span className="relative z-10 flex items-center gap-1.5 whitespace-nowrap">
          <span key={`l-agent-${agent.id}`} className="flex shrink-0 animate-[preview-enter_160ms_ease-out] items-center gap-1.5">
            <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${agentDotClassOf(agent)}`} />
            <span className="truncate font-semibold">{agent.agentName} {agentLabelOf(agent)}</span>
          </span>
          <span className="h-3 w-px shrink-0 bg-black/10 dark:bg-white/15" />
          <span key={`l-provider-${provider.id}`} className="flex shrink-0 animate-[preview-enter_160ms_ease-out] items-center gap-1.5">
            <Image src={provider.logo} alt="" width={16} height={16} className="h-4 w-4 shrink-0 rounded-[5px] bg-white object-cover" />
            <span className="truncate tabular-nums text-[var(--preview-muted)]">{provider.quota.compact}</span>
          </span>
        </span>
      </button>

      {open && (
        <div className="absolute right-0 top-[30px] z-30 w-[300px] animate-[preview-enter_160ms_ease-out] rounded-[18px] border border-white/60 bg-white/90 p-2.5 text-left shadow-[0_18px_50px_rgba(25,31,29,0.20)] backdrop-blur-2xl dark:border-white/10 dark:bg-[#272a2b]/94">
          <div className="flex items-center justify-between px-1 pb-2">
            <div className="flex min-w-0 items-center gap-2">
              <Image
                src="/brand/tomo-logo.webp"
                alt="Tomo Pet"
                width={38}
                height={38}
                className="h-[38px] w-[38px] shrink-0 object-contain drop-shadow-[0_6px_7px_rgba(20,35,27,0.18)]"
              />
              <div key={agent.id} className="min-w-0 animate-[preview-enter_160ms_ease-out]">
                <div className="text-[7px] font-semibold tracking-[0.08em] text-[var(--preview-muted)]">当前任务</div>
                <div className="mt-1 flex items-center gap-1.5 truncate text-[9px] font-bold text-[var(--preview-ink)]">
                  <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${agentDotClassOf(agent)}`} />
                  {agent.taskTitle}
                </div>
              </div>
            </div>
          </div>

          <div className="border-t border-black/[0.06] pt-1.5 dark:border-white/[0.07]">
            <div className="px-1 pb-1 text-[7px] font-semibold uppercase tracking-[0.12em] text-[var(--preview-muted)]">账号与额度（多账号 / 多 Key）</div>
            <div className="space-y-0.5">
              {providers.map((item, index) => {
                const selected = index === providerIndex;
                return (
                  <button
                    key={item.id}
                    type="button"
                    onClick={() => onSelectProvider(index)}
                    className={`flex w-full items-center gap-2 rounded-xl px-2 py-1.5 text-left transition ${selected ? "bg-emerald-500/[0.09]" : "hover:bg-black/[0.035] dark:hover:bg-white/[0.05]"}`}
                  >
                    <span className="relative h-7 w-7 shrink-0 rounded-[9px] bg-white p-0.5 shadow-sm">
                      <Image src={item.logo} alt={`${item.providerName} Logo`} width={28} height={28} className="h-full w-full rounded-[7px] object-cover" />
                      <span className={`absolute bottom-0 right-0 h-2 w-2 rounded-full border border-white ${item.quota.kind === "apiKey" ? "bg-emerald-500" : "bg-[#28c04e]"}`} />
                    </span>
                    <span className="min-w-0 flex-1">
                      <span className="flex items-baseline gap-1.5">
                        <span className="truncate text-[8.5px] font-bold text-[var(--preview-ink)]">{item.providerName}</span>
                        <span className="truncate text-[6.5px] text-[var(--preview-muted)]">{item.accountName}</span>
                      </span>
                      <span className="mt-0.5 block text-[7px] text-[var(--preview-muted)]">{item.quota.kind === "apiKey" ? "API Key 余额" : "账号额度"}</span>
                    </span>
                    <span className="shrink-0 text-right tabular-nums">
                      <span className="block text-[8px] font-bold text-[var(--preview-ink)]">{item.quota.primary}</span>
                      <span className="mt-0.5 block text-[6.5px] text-[var(--preview-muted)]">{item.quota.secondary}</span>
                    </span>
                  </button>
                );
              })}
            </div>
          </div>

          <div className="mt-1.5 flex items-center justify-between border-t border-black/[0.06] px-1 pt-2 text-[6.5px] text-[var(--preview-muted)] dark:border-white/[0.07]">
            <span>状态 / 额度独立轮播 · 悬停暂停</span>
            <span className="flex gap-1">
              {providers.map((item, index) => (
                <button
                  key={item.id}
                  type="button"
                  onClick={() => onSelectProvider(index)}
                  aria-label={`查看 ${item.providerName} ${item.accountName}`}
                  className={`h-1.5 rounded-full transition-all ${index === providerIndex ? "w-3 bg-emerald-500" : "w-1.5 bg-black/15 dark:bg-white/20"}`}
                />
              ))}
            </span>
          </div>
        </div>
      )}
    </div>
  );
}

/* ==================== 小统计 ==================== */

function MiniStat({ label, value, tone }: { label: string; value: number; tone: "blue" | "green" | "amber" }) {
  const toneClass =
    tone === "blue"
      ? "bg-[#2e6bff]"
      : tone === "green"
        ? "bg-[#1fa55a]"
        : "bg-[#f27314]";
  return (
    <div className="flex items-center gap-3 rounded-2xl border border-[color:var(--preview-line)] bg-[var(--preview-card)]/70 px-4 py-3 backdrop-blur">
      <span className={`h-2 w-2 shrink-0 rounded-full ${toneClass}`} />
      <div className="min-w-0">
        <div className="text-[9px] text-[var(--preview-muted)]">{label}</div>
        <div className="text-sm font-bold tabular-nums text-[var(--preview-ink)]">{value}</div>
      </div>
    </div>
  );
}
