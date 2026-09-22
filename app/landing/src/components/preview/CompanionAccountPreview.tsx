"use client";

import Image from "next/image";
import {
  Bot,
  Check,
  ChevronDown,
  ChevronRight,
  CircleDollarSign,
  ExternalLink,
  Eye,
  EyeOff,
  KeyRound,
  Laptop,
  Layers3,
  Link2,
  MoreHorizontal,
  Plus,
  RefreshCw,
  Settings,
  ShieldCheck,
  Sparkles,
  X,
} from "lucide-react";
import { useMemo, useState } from "react";

type ConnectionKind = "agent" | "provider";
type PreviewMode = "companion" | "desktop";

export type Connection = {
  id: string;
  kind: ConnectionKind;
  agent: string;
  account: string;
  accountName: string;
  accountEmail: string;
  subscriptionSummary: string;
  billingUrl: string;
  brand: string;
  plan: string;
  state: string;
  stateTone: "working" | "waiting" | "idle" | "healthy";
  task?: string;
  detail?: string;
  shortQuota?: number;
  weeklyQuota?: number;
  balance?: string;
  balanceDetail?: string;
};

export const connections: Connection[] = [
  {
    id: "codex-work",
    kind: "agent",
    agent: "Codex",
    account: "Work",
    accountName: "Qiizo",
    accountEmail: "qiizo@codexling.dev",
    subscriptionSummary: "当前周期至 8月18日 · 自动续费",
    billingUrl: "https://chatgpt.com/#settings/Billing",
    brand: "codex",
    plan: "Team",
    state: "工作中",
    stateTone: "working",
    task: "优化 Tomo 多账号切换",
    detail: "Tomo · main · gpt-5.6-sol",
    shortQuota: 82,
    weeklyQuota: 76,
  },
  {
    id: "codex-personal",
    kind: "agent",
    agent: "Codex",
    account: "Personal",
    accountName: "Qiizo Personal",
    accountEmail: "me@example.com",
    subscriptionSummary: "当前周期至 8月26日 · 自动续费",
    billingUrl: "https://chatgpt.com/#settings/Billing",
    brand: "codex",
    plan: "Plus",
    state: "空闲",
    stateTone: "idle",
    detail: "me@example.com",
    shortQuota: 54,
    weeklyQuota: 91,
  },
  {
    id: "kimi-personal",
    kind: "agent",
    agent: "Kimi Code",
    account: "Personal",
    accountName: "Qiizo",
    accountEmail: "qiizo@moonshot.cn",
    subscriptionSummary: "会员有效至 9月3日 · 自动续费",
    billingUrl: "https://www.kimi.com/code",
    brand: "kimi-code",
    plan: "会员",
    state: "待确认",
    stateTone: "waiting",
    task: "是否执行完整测试？",
    detail: "Managed Session · ACP",
    shortQuota: 28,
    weeklyQuota: 63,
  },
  {
    id: "deepseek-key",
    kind: "provider",
    agent: "DeepSeek",
    account: "Personal Key",
    accountName: "Personal Key",
    accountEmail: "sk-••••••••7A2F",
    subscriptionSummary: "按量计费 · 当前余额 ¥42.80",
    billingUrl: "https://platform.deepseek.com/usage",
    brand: "deepseek",
    plan: "API Provider",
    state: "余额正常",
    stateTone: "healthy",
    balance: "¥42.80",
    balanceDetail: "充值 ¥38.00 · 赠送 ¥4.80",
    detail: "sk-•••• 7A2F · 刚刚更新",
  },
];

const statusClass = {
  working: "bg-violet-500/10 text-violet-600 dark:text-violet-400",
  waiting: "bg-orange-500/10 text-orange-600 dark:text-orange-400",
  idle: "bg-black/[0.045] text-[var(--preview-muted)] dark:bg-white/[0.07]",
  healthy: "bg-emerald-500/10 text-emerald-600 dark:text-emerald-400",
};

function WindowDots() {
  return (
    <div className="flex gap-2" aria-hidden>
      <span className="h-3 w-3 rounded-full border border-[#df4b45] bg-[#ff5f57]" />
      <span className="h-3 w-3 rounded-full border border-[#d89e24] bg-[#febc2e]" />
      <span className="h-3 w-3 rounded-full border border-[#17a92f] bg-[#28c840]" />
    </div>
  );
}

function ConnectionMark({ connection, small = false }: { connection: Connection; small?: boolean }) {
  return (
    <span className={`grid shrink-0 place-items-center rounded-[11px] bg-[var(--preview-card)] ring-1 ring-[color:var(--preview-line)] ${small ? "h-8 w-8 p-1.5" : "h-10 w-10 p-2"}`}>
      <Image
        src={`/brand-assets/${connection.brand}/color.svg`}
        alt={`${connection.agent} logo`}
        width={small ? 24 : 30}
        height={small ? 24 : 30}
        unoptimized
        className="h-full w-full object-contain"
      />
    </span>
  );
}

function StatusBadge({ connection }: { connection: Connection }) {
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[10px] font-semibold ${statusClass[connection.stateTone]}`}>
      <span className="h-1.5 w-1.5 rounded-full bg-current" />
      {connection.state}
    </span>
  );
}

function ModeSwitch({ mode, onChange }: { mode: PreviewMode; onChange: (mode: PreviewMode) => void }) {
  return (
    <div className="inline-flex rounded-full border border-[color:var(--preview-line)] bg-[color:var(--preview-card)]/80 p-1 shadow-sm backdrop-blur-xl">
      {([
        ["companion", "陪伴窗口", Layers3],
        ["desktop", "桌面 Pet", Laptop],
      ] as const).map(([value, label, Icon]) => (
        <button key={value} type="button" onClick={() => onChange(value)} aria-pressed={mode === value} className={`flex h-8 items-center gap-2 rounded-full px-3.5 text-[10px] font-semibold transition-all ${mode === value ? "bg-[var(--preview-primary)] text-[var(--preview-on-primary)] shadow-sm" : "text-[var(--preview-muted)] hover:text-[var(--preview-ink)]"}`}>
          <Icon className="h-3.5 w-3.5" />
          {label}
        </button>
      ))}
    </div>
  );
}

function ConnectionSwitcher({
  activeId,
  onSelect,
  onAdd,
}: {
  activeId: string;
  onSelect: (id: string) => void;
  onAdd: () => void;
}) {
  return (
    <div className="flex items-center gap-2 border-b border-[color:var(--preview-line)] bg-[color:var(--preview-card)]/70 px-4 py-3 backdrop-blur-xl">
      <span className="mr-1 text-[9px] font-bold uppercase tracking-[0.12em] text-[var(--preview-muted)]">我的连接</span>
      <div className="flex min-w-0 flex-1 gap-2 overflow-x-auto [scrollbar-width:none]">
        {connections.map((connection) => {
          const selected = connection.id === activeId;
          return (
            <button key={connection.id} type="button" onClick={() => onSelect(connection.id)} aria-pressed={selected} className={`flex shrink-0 items-center gap-2 rounded-[11px] border px-2.5 py-2 text-left transition-all ${selected ? "border-emerald-500/25 bg-emerald-500/[0.07] shadow-sm" : "border-transparent hover:border-[color:var(--preview-line)] hover:bg-[var(--preview-card)]"}`}>
              <ConnectionMark connection={connection} small />
              <span>
                <span className="block text-[10px] font-bold text-[var(--preview-ink)]">{connection.agent}</span>
                <span className="block text-[8px] text-[var(--preview-muted)]">{connection.account}</span>
              </span>
              {connection.stateTone === "waiting" && <span className="h-2 w-2 rounded-full bg-orange-500 shadow-[0_0_8px_rgba(249,115,22,0.45)]" />}
            </button>
          );
        })}
      </div>
      <button type="button" onClick={onAdd} className="grid h-9 w-9 shrink-0 place-items-center rounded-[11px] border border-dashed border-[color:var(--preview-line)] text-[var(--preview-muted)] transition hover:border-emerald-500/35 hover:bg-emerald-500/[0.06] hover:text-emerald-600" aria-label="添加账号或 API Key">
        <Plus className="h-4 w-4" />
      </button>
    </div>
  );
}

function PetSidebar({ onShowTasks }: { onShowTasks: () => void }) {
  return (
    <aside className="relative flex w-[245px] shrink-0 flex-col overflow-hidden border-r border-[color:var(--preview-line)] bg-[linear-gradient(160deg,var(--preview-sidebar),var(--preview-card))] p-5">
      <div className="pointer-events-none absolute -left-16 top-28 h-56 w-56 rounded-full bg-emerald-400/10 blur-3xl" />
      <div className="relative">
        <div className="flex items-center gap-2 text-[11px] font-bold text-[var(--preview-ink)]">
          <Sparkles className="h-3.5 w-3.5 text-emerald-500" /> Pet 正在陪伴
        </div>
        <p className="mt-1 text-[9px] leading-4 text-[var(--preview-muted)]">自动跟随最需要你注意的本地任务</p>
      </div>
      <div className="relative flex flex-1 flex-col items-center justify-center">
        <div className="pointer-events-none absolute h-36 w-36 rounded-full bg-emerald-300/15 blur-3xl" />
        <Image src="/brand/codexling-logo.webp" alt="Tomo Pet" width={160} height={160} priority className="relative h-[148px] w-[148px] animate-float drop-shadow-[0_20px_22px_rgba(0,0,0,0.2)]" />
        <div className="status-edge-glow relative mt-3 inline-flex h-9 items-center gap-2 overflow-hidden rounded-full px-4 text-[10px] font-bold text-[var(--preview-ink)]">
          <span className="status-edge-glow__inner" />
          <span className="relative z-10 h-2 w-2 rounded-full bg-orange-500 shadow-[0_0_8px_rgba(249,115,22,0.5)]" />
          <span className="relative z-10">Kimi 等待你确认</span>
        </div>
        <span className="mt-2 text-[9px] text-[var(--preview-muted)]">今天一起工作 2 小时 21 分钟</span>
      </div>
      <button type="button" onClick={onShowTasks} className="relative flex w-full items-center justify-between rounded-[13px] border border-[color:var(--preview-line)] bg-[color:var(--preview-card)]/84 p-3 text-left shadow-sm transition hover:-translate-y-0.5 hover:shadow-md active:translate-y-0">
        <span>
          <span className="block text-[10px] font-bold text-[var(--preview-ink)]">3 个本地 Agent</span>
          <span className="mt-0.5 block text-[8px] text-[var(--preview-muted)]">2 工作中 · 1 待确认</span>
        </span>
        <span className="flex -space-x-1.5">
          {connections.filter((item) => item.kind === "agent").map((item) => <ConnectionMark key={item.id} connection={item} small />)}
        </span>
      </button>
    </aside>
  );
}

function QuotaRing({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex flex-1 items-center gap-3 rounded-[15px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] p-3">
      <div className="h-11 w-11 shrink-0 rounded-full p-[5px]" style={{ background: `conic-gradient(var(--preview-green) ${value}%, var(--preview-track) 0)` }}>
        <div className="grid h-full w-full place-items-center rounded-full bg-[var(--preview-card)] text-[9px] font-bold text-[var(--preview-ink)]">{value}</div>
      </div>
      <div>
        <div className="text-[10px] font-bold text-[var(--preview-ink)]">{label}</div>
        <div className="mt-1 text-[8px] text-[var(--preview-muted)]">剩余 {value}%</div>
      </div>
    </div>
  );
}

function AgentAccountView({ connection, onAction }: { connection: Connection; onAction: (message: string) => void }) {
  const hasTask = Boolean(connection.task);
  return (
    <div className="animate-[preview-enter_240ms_ease-out]">
      <div className="flex items-start justify-between gap-4">
        <div className="flex items-center gap-3">
          <ConnectionMark connection={connection} />
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-[20px] font-bold tracking-[-0.035em] text-[var(--preview-ink)]">{connection.agent}</h1>
              <span className="rounded-[6px] bg-[var(--preview-green-soft)] px-2 py-0.5 text-[9px] font-bold text-[var(--preview-green)]">{connection.plan}</span>
            </div>
            <button type="button" onClick={() => onAction("账号菜单已展开")} className="mt-0.5 flex items-center gap-1 text-[9px] text-[var(--preview-muted)] hover:text-[var(--preview-ink)]">
              {connection.account} <ChevronDown className="h-3 w-3" />
            </button>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <StatusBadge connection={connection} />
          <button type="button" onClick={() => onAction("账号操作菜单已打开")} className="grid h-8 w-8 place-items-center rounded-[9px] border border-[color:var(--preview-line)] text-[var(--preview-muted)]"><MoreHorizontal className="h-4 w-4" /></button>
        </div>
      </div>

      <section className={`mt-5 rounded-[18px] border p-4 ${hasTask ? "border-violet-500/15 bg-[linear-gradient(145deg,rgba(124,58,237,0.055),var(--preview-card))]" : "border-[color:var(--preview-line)] bg-[var(--preview-card)]"}`}>
        <div className="flex items-center justify-between">
          <span className="text-[9px] font-bold uppercase tracking-[0.12em] text-[var(--preview-muted)]">当前任务</span>
          <span className="text-[9px] text-[var(--preview-muted)]">更新于刚刚</span>
        </div>
        {hasTask ? (
          <>
            <div className="mt-3 text-[16px] font-bold text-[var(--preview-ink)]">{connection.task}</div>
            <div className="mt-1 text-[9px] text-[var(--preview-muted)]">{connection.detail}</div>
            <div className="mt-4 flex items-center justify-between border-t border-[color:var(--preview-line)] pt-3">
              <span className="flex items-center gap-2 text-[9px] font-semibold text-violet-600 dark:text-violet-400"><span className="h-2 w-2 rounded-full bg-current" />{connection.state === "待确认" ? "等待你的操作" : "正在运行本地工具"}</span>
              <button type="button" onClick={() => onAction(`已准备打开 ${connection.agent} 任务`)} className="flex items-center gap-1 text-[9px] font-bold text-[var(--preview-ink)]">打开任务 <ExternalLink className="h-3 w-3" /></button>
            </div>
          </>
        ) : (
          <div className="flex h-[94px] flex-col items-center justify-center text-center">
            <div className="text-[12px] font-bold text-[var(--preview-ink)]">现在很安静</div>
            <div className="mt-1 text-[9px] text-[var(--preview-muted)]">这个账号暂时没有进行中的任务</div>
          </div>
        )}
      </section>

      <section className="mt-4">
        <div className="flex items-center justify-between">
          <h2 className="text-[12px] font-bold text-[var(--preview-ink)]">额度</h2>
          <button type="button" onClick={() => onAction(`${connection.agent} 额度已刷新`)} className="flex items-center gap-1 text-[9px] font-semibold text-[var(--preview-muted)] hover:text-[var(--preview-ink)]"><RefreshCw className="h-3 w-3" /> 刷新</button>
        </div>
        <div className="mt-2 flex gap-2">
          <QuotaRing label="5 小时" value={connection.shortQuota ?? 0} />
          <QuotaRing label="本周" value={connection.weeklyQuota ?? 0} />
        </div>
        <div className="mt-2 flex items-center justify-between rounded-[12px] bg-[var(--preview-sidebar)] px-3 py-2 text-[8px] text-[var(--preview-muted)]">
          <span>来源：{connection.agent} 官方账号</span>
          <span>下次重置：8月5日 14:47</span>
        </div>
      </section>
    </div>
  );
}

function ProviderAccountView({ connection, onAction }: { connection: Connection; onAction: (message: string) => void }) {
  return (
    <div className="animate-[preview-enter_240ms_ease-out]">
      <div className="flex items-start justify-between">
        <div className="flex items-center gap-3">
          <ConnectionMark connection={connection} />
          <div>
            <h1 className="text-[20px] font-bold tracking-[-0.035em] text-[var(--preview-ink)]">{connection.agent}</h1>
            <div className="mt-0.5 text-[9px] text-[var(--preview-muted)]">{connection.account} · {connection.detail}</div>
          </div>
        </div>
        <StatusBadge connection={connection} />
      </div>
      <section className="relative mt-5 overflow-hidden rounded-[20px] border border-violet-500/15 bg-[linear-gradient(145deg,rgba(124,58,237,0.07),var(--preview-card))] p-5">
        <div className="pointer-events-none absolute -right-10 -top-10 h-36 w-36 rounded-full bg-violet-400/10 blur-3xl" />
        <div className="relative text-[9px] font-bold uppercase tracking-[0.12em] text-[var(--preview-muted)]">可用余额</div>
        <div className="relative mt-2 text-[36px] font-bold tracking-[-0.055em] text-[var(--preview-ink)]">{connection.balance}</div>
        <div className="relative mt-1 text-[9px] text-[var(--preview-muted)]">{connection.balanceDetail}</div>
        <div className="relative mt-5 flex gap-2 border-t border-[color:var(--preview-line)] pt-4">
          <button type="button" onClick={() => onAction("DeepSeek 余额已更新")} className="flex h-9 flex-1 items-center justify-center gap-2 rounded-[10px] bg-[var(--preview-primary)] text-[9px] font-bold text-[var(--preview-on-primary)]"><RefreshCw className="h-3.5 w-3.5" /> 查询余额</button>
          <button type="button" onClick={() => onAction("API Key 设置已打开")} className="grid h-9 w-9 place-items-center rounded-[10px] border border-[color:var(--preview-line)] text-[var(--preview-muted)]"><Settings className="h-3.5 w-3.5" /></button>
        </div>
      </section>
      <section className="mt-4 rounded-[16px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] p-4">
        <div className="flex items-center justify-between">
          <h2 className="text-[11px] font-bold text-[var(--preview-ink)]">正在使用这个 Key</h2>
          <span className="text-[8px] text-[var(--preview-muted)]">2 个 Agent</span>
        </div>
        <div className="mt-3 flex gap-2">
          {[connections[1], connections[2]].map((agent) => <div key={agent.id} className="flex flex-1 items-center gap-2 rounded-[12px] bg-[var(--preview-sidebar)] p-2.5"><ConnectionMark connection={agent} small /><div><div className="text-[9px] font-bold text-[var(--preview-ink)]">{agent.agent}</div><div className="text-[8px] text-[var(--preview-muted)]">{agent.account}</div></div></div>)}
        </div>
        <p className="mt-3 flex items-start gap-2 text-[8px] leading-4 text-[var(--preview-muted)]"><ShieldCheck className="mt-0.5 h-3 w-3 shrink-0 text-emerald-500" />Key 保存在 macOS Keychain，只用于查询官方余额接口。</p>
      </section>
    </div>
  );
}

function LocalTaskStrip({ onSelect }: { onSelect: (id: string) => void }) {
  const tasks = connections.filter((item) => item.kind === "agent");
  return (
    <div className="border-t border-[color:var(--preview-line)] bg-[color:var(--preview-card)]/74 px-4 py-3 backdrop-blur-xl">
      <div className="flex items-center gap-2">
        <span className="mr-1 text-[9px] font-bold text-[var(--preview-muted)]">本地任务</span>
        {tasks.map((task) => (
          <button key={task.id} type="button" onClick={() => onSelect(task.id)} className="flex min-w-0 flex-1 items-center gap-2 rounded-[11px] px-2.5 py-2 text-left transition hover:bg-[var(--preview-sidebar)]">
            <span className={`h-2 w-2 shrink-0 rounded-full ${task.stateTone === "waiting" ? "bg-orange-500" : task.stateTone === "working" ? "bg-violet-500" : "bg-gray-300"}`} />
            <span className="min-w-0"><span className="block truncate text-[9px] font-bold text-[var(--preview-ink)]">{task.agent} · {task.account}</span><span className="block truncate text-[8px] text-[var(--preview-muted)]">{task.task ?? "空闲"}</span></span>
          </button>
        ))}
      </div>
    </div>
  );
}

function CompanionWindow({ active, onSelect, onAdd, onFeedback, onDesktop }: { active: Connection; onSelect: (id: string) => void; onAdd: () => void; onFeedback: (message: string) => void; onDesktop: () => void }) {
  return (
    <div className="flex h-full flex-col overflow-hidden rounded-[26px] border border-white/50 bg-[var(--preview-panel)] shadow-[0_38px_100px_rgba(28,32,36,0.22)] ring-1 ring-black/[0.04] dark:border-white/10">
      <header className="flex h-[52px] shrink-0 items-center border-b border-[color:var(--preview-line)] bg-[color:var(--preview-card)]/78 px-4 backdrop-blur-xl">
        <WindowDots />
        <div className="mx-auto flex items-center gap-2 text-[10px] font-bold text-[var(--preview-ink)]"><Image src="/brand/codexling-logo.webp" alt="" width={22} height={22} className="h-[22px] w-[22px] rounded-[7px]" />Tomo</div>
        <button type="button" onClick={onDesktop} className="flex items-center gap-1.5 rounded-[9px] px-2.5 py-1.5 text-[9px] font-semibold text-[var(--preview-muted)] transition hover:bg-[var(--preview-sidebar)] hover:text-[var(--preview-ink)]"><Laptop className="h-3.5 w-3.5" /> 放到桌面</button>
      </header>
      <ConnectionSwitcher activeId={active.id} onSelect={onSelect} onAdd={onAdd} />
      <div className="flex min-h-0 flex-1">
        <PetSidebar onShowTasks={() => onFeedback("已显示全部本地任务")} />
        <main className="min-w-0 flex-1 overflow-auto bg-[var(--preview-panel)] p-5">
          {active.kind === "agent" ? <AgentAccountView connection={active} onAction={onFeedback} /> : <ProviderAccountView connection={active} onAction={onFeedback} />}
        </main>
      </div>
      <LocalTaskStrip onSelect={onSelect} />
    </div>
  );
}

function DesktopPet({ onOpenAccount, onBack, onFeedback }: { onOpenAccount: (id: string) => void; onBack: () => void; onFeedback: (message: string) => void }) {
  const [panelOpen, setPanelOpen] = useState(true);
  return (
    <div className="relative h-full overflow-hidden rounded-[26px] border border-white/40 bg-[radial-gradient(circle_at_30%_20%,rgba(255,255,255,0.84),transparent_32%),linear-gradient(145deg,#dfeae6,#d8ddd9_52%,#e8e5df)] shadow-[0_38px_100px_rgba(28,32,36,0.2)] dark:bg-[radial-gradient(circle_at_30%_20%,rgba(255,255,255,0.06),transparent_32%),linear-gradient(145deg,#222827,#171a1b)]">
      <div className="absolute inset-x-0 top-0 flex h-8 items-center border-b border-black/[0.06] bg-white/50 px-3 text-[9px] text-black/65 backdrop-blur-xl dark:bg-black/30 dark:text-white/70">
        <span className="font-bold">Tomo</span><span className="ml-4">文件</span><span className="ml-4">窗口</span>
        <button type="button" onClick={() => setPanelOpen((value) => !value)} className="ml-auto flex items-center gap-2 rounded-full bg-black/[0.06] px-3 py-1 dark:bg-white/10"><span className="h-1.5 w-1.5 rounded-full bg-orange-500" />Kimi 待确认 · Codex 工作中</button>
      </div>
      <button type="button" onClick={onBack} className="absolute left-4 top-12 flex items-center gap-2 rounded-full border border-white/60 bg-white/60 px-3 py-2 text-[9px] font-semibold text-black/65 shadow-sm backdrop-blur-xl transition hover:bg-white/80 dark:border-white/10 dark:bg-black/25 dark:text-white/70"><Layers3 className="h-3.5 w-3.5" />返回陪伴窗口</button>
      <div className="absolute bottom-14 right-[17%] flex flex-col items-center">
        {panelOpen && (
          <div className="mb-3 w-[350px] overflow-hidden rounded-[20px] border border-white/60 bg-white/80 p-3 shadow-[0_22px_60px_rgba(35,42,39,0.2)] backdrop-blur-2xl animate-[preview-enter_220ms_ease-out] dark:border-white/10 dark:bg-[#25282a]/85">
            <div className="flex items-center justify-between px-1">
              <div><div className="text-[11px] font-bold text-[var(--preview-ink)]">Pet 看到了 3 个 Agent</div><div className="mt-0.5 text-[8px] text-[var(--preview-muted)]">所有状态都来自本机 Hooks 或会话记录</div></div>
              <button type="button" onClick={() => setPanelOpen(false)} className="grid h-7 w-7 place-items-center rounded-full bg-black/5 text-[var(--preview-muted)] dark:bg-white/10"><X className="h-3.5 w-3.5" /></button>
            </div>
            <div className="mt-3 space-y-1.5">
              {connections.filter((item) => item.kind === "agent").map((task) => (
                <button key={task.id} type="button" onClick={() => onOpenAccount(task.id)} className="group flex w-full items-center gap-2.5 rounded-[12px] p-2 text-left transition hover:bg-black/[0.04] dark:hover:bg-white/[0.06]">
                  <ConnectionMark connection={task} small />
                  <div className="min-w-0 flex-1"><div className="flex items-center gap-2"><span className="text-[9px] font-bold text-[var(--preview-ink)]">{task.agent}</span><StatusBadge connection={task} /></div><div className="mt-0.5 truncate text-[8px] text-[var(--preview-muted)]">{task.task ?? "当前空闲"}</div></div>
                  <ChevronRight className="h-3.5 w-3.5 text-[var(--preview-muted)] transition-transform group-hover:translate-x-0.5" />
                </button>
              ))}
            </div>
            <button type="button" onClick={() => onFeedback("已打开桌面 Pet 设置")} className="mt-2 flex w-full items-center justify-center gap-2 rounded-[10px] border border-[color:var(--preview-line)] py-2 text-[8px] font-semibold text-[var(--preview-muted)]"><Settings className="h-3 w-3" />桌面 Pet 设置</button>
          </div>
        )}
        <button type="button" onClick={() => setPanelOpen((value) => !value)} aria-label="打开 Pet 任务悬浮卡片" className="group relative">
          <span className="absolute -right-1 top-2 h-3 w-3 rounded-full bg-orange-500 ring-4 ring-white/70 dark:ring-black/40" />
          <Image src="/brand/codexling-logo.webp" alt="桌面 Tomo Pet" width={150} height={150} className="h-[142px] w-[142px] animate-float drop-shadow-[0_24px_22px_rgba(26,36,30,0.25)] transition-transform group-hover:scale-105" />
        </button>
        <span className="mt-2 rounded-full bg-white/55 px-3 py-1 text-[8px] font-medium text-black/55 backdrop-blur dark:bg-black/25 dark:text-white/55">悬停或点击查看任务</span>
      </div>
    </div>
  );
}

function AddConnectionSheet({ onClose, onFeedback }: { onClose: () => void; onFeedback: (message: string) => void }) {
  const [choice, setChoice] = useState<"agent" | "provider">("agent");
  const [showKey, setShowKey] = useState(false);
  return (
    <div className="absolute inset-0 z-40 flex items-center justify-center bg-black/20 p-8 backdrop-blur-[3px]">
      <button type="button" aria-label="关闭添加连接" className="absolute inset-0" onClick={onClose} />
      <section className="relative w-[430px] rounded-[22px] border border-white/35 bg-[var(--preview-card)] p-5 shadow-[0_30px_90px_rgba(0,0,0,0.28)]">
        <div className="flex items-start justify-between"><div><div className="text-[9px] font-bold uppercase tracking-[0.13em] text-emerald-600 dark:text-emerald-400">New connection</div><h2 className="mt-1 text-[19px] font-bold tracking-[-0.035em] text-[var(--preview-ink)]">添加你日常使用的连接</h2><p className="mt-1 text-[9px] text-[var(--preview-muted)]">同一种 Agent 可以添加多个账号。</p></div><button type="button" onClick={onClose} className="grid h-8 w-8 place-items-center rounded-full bg-black/5 text-[var(--preview-muted)] dark:bg-white/10"><X className="h-4 w-4" /></button></div>
        <div className="mt-5 grid grid-cols-2 gap-2 rounded-[12px] bg-[var(--preview-sidebar)] p-1">
          <button type="button" onClick={() => setChoice("agent")} className={`flex items-center justify-center gap-2 rounded-[9px] py-2.5 text-[9px] font-bold ${choice === "agent" ? "bg-[var(--preview-card)] text-[var(--preview-ink)] shadow-sm" : "text-[var(--preview-muted)]"}`}><Bot className="h-3.5 w-3.5" />Agent 账号</button>
          <button type="button" onClick={() => setChoice("provider")} className={`flex items-center justify-center gap-2 rounded-[9px] py-2.5 text-[9px] font-bold ${choice === "provider" ? "bg-[var(--preview-card)] text-[var(--preview-ink)] shadow-sm" : "text-[var(--preview-muted)]"}`}><KeyRound className="h-3.5 w-3.5" />API Key</button>
        </div>
        {choice === "agent" ? (
          <div className="mt-4 space-y-2">
            {[connections[0], connections[2]].map((item) => <button key={item.id} type="button" onClick={() => { onFeedback(`已启动 ${item.agent} 官方登录`); onClose(); }} className="flex w-full items-center gap-3 rounded-[13px] border border-[color:var(--preview-line)] p-3 text-left transition hover:border-emerald-500/25 hover:bg-emerald-500/[0.04]"><ConnectionMark connection={item} small /><div className="flex-1"><div className="text-[10px] font-bold text-[var(--preview-ink)]">登录另一个 {item.agent} 账号</div><div className="mt-0.5 text-[8px] text-[var(--preview-muted)]">委托官方登录，不读取 token 文件</div></div><ExternalLink className="h-3.5 w-3.5 text-[var(--preview-muted)]" /></button>)}
            <button type="button" onClick={() => onFeedback("更多本地 Agent 列表已展开")} className="flex w-full items-center justify-center gap-2 rounded-[11px] py-2 text-[9px] font-semibold text-[var(--preview-muted)]"><Plus className="h-3 w-3" />选择其他 Agent</button>
          </div>
        ) : (
          <div className="mt-4">
            <label className="text-[9px] font-bold text-[var(--preview-ink)]">Provider</label>
            <button type="button" className="mt-2 flex h-10 w-full items-center justify-between rounded-[11px] border border-[color:var(--preview-line)] px-3 text-[9px] text-[var(--preview-ink)]"><span className="flex items-center gap-2"><CircleDollarSign className="h-3.5 w-3.5 text-violet-500" />DeepSeek</span><ChevronDown className="h-3.5 w-3.5 text-[var(--preview-muted)]" /></button>
            <label className="mt-3 block text-[9px] font-bold text-[var(--preview-ink)]">API Key</label>
            <div className="mt-2 flex h-10 items-center rounded-[11px] border border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] px-3"><KeyRound className="h-3.5 w-3.5 text-[var(--preview-muted)]" /><input aria-label="API Key" type={showKey ? "text" : "password"} defaultValue="sk-demo-preview-key" className="min-w-0 flex-1 bg-transparent px-2 text-[9px] text-[var(--preview-ink)] outline-none" /><button type="button" aria-label={showKey ? "隐藏 API Key" : "显示 API Key"} onClick={() => setShowKey((value) => !value)} className="text-[var(--preview-muted)]">{showKey ? <EyeOff className="h-3.5 w-3.5" /> : <Eye className="h-3.5 w-3.5" />}</button></div>
            <button type="button" onClick={() => { onFeedback("API Key 已验证，余额 ¥42.80"); onClose(); }} className="mt-4 flex h-10 w-full items-center justify-center gap-2 rounded-[11px] bg-[var(--preview-primary)] text-[9px] font-bold text-[var(--preview-on-primary)]"><Link2 className="h-3.5 w-3.5" />验证并添加余额卡</button>
          </div>
        )}
      </section>
    </div>
  );
}

export function CompanionAccountPreview() {
  const [activeId, setActiveId] = useState("codex-work");
  const [mode, setMode] = useState<PreviewMode>("companion");
  const [showAdd, setShowAdd] = useState(false);
  const [feedback, setFeedback] = useState<string>();
  const active = useMemo(() => connections.find((item) => item.id === activeId) ?? connections[0], [activeId]);

  const showFeedback = (message: string) => {
    setFeedback(message);
    window.setTimeout(() => setFeedback(undefined), 2300);
  };

  const selectFromDesktop = (id: string) => {
    setActiveId(id);
    setMode("companion");
  };

  return (
    <div className="relative flex min-h-screen items-center overflow-hidden bg-[linear-gradient(145deg,var(--preview-desktop),var(--preview-desktop-end))] px-4 py-7 text-[var(--preview-ink)] sm:px-6 lg:px-10">
      <div className="pointer-events-none absolute left-[5%] top-[8%] h-72 w-72 rounded-full bg-emerald-400/[0.08] blur-[95px]" />
      <div className="pointer-events-none absolute bottom-[5%] right-[6%] h-80 w-80 rounded-full bg-blue-400/[0.06] blur-[100px]" />
      <div className="relative mx-auto w-full max-w-[960px]">
        <div className="mb-4 flex items-center justify-between">
          <div><div className="text-[11px] font-bold text-[var(--preview-ink)]">Tomo</div><div className="mt-0.5 text-[9px] text-[var(--preview-muted)]">一个 Pet，陪着你用过的每个 Agent</div></div>
          <ModeSwitch mode={mode} onChange={setMode} />
        </div>
        <div className="relative h-[min(735px,calc(100vh-100px))] min-h-[660px]">
          {mode === "companion" ? <CompanionWindow active={active} onSelect={setActiveId} onAdd={() => setShowAdd(true)} onFeedback={showFeedback} onDesktop={() => setMode("desktop")} /> : <DesktopPet onOpenAccount={selectFromDesktop} onBack={() => setMode("companion")} onFeedback={showFeedback} />}
          {showAdd && <AddConnectionSheet onClose={() => setShowAdd(false)} onFeedback={showFeedback} />}
          {feedback && <div className="pointer-events-none absolute bottom-5 left-1/2 z-50 flex -translate-x-1/2 items-center gap-2 rounded-full bg-[#17191d]/92 px-4 py-2.5 text-[9px] font-semibold text-white shadow-2xl backdrop-blur-xl animate-[preview-toast_260ms_ease-out]"><Check className="h-3.5 w-3.5 text-emerald-400" />{feedback}</div>}
        </div>
      </div>
    </div>
  );
}
