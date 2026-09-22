"use client";

import Image from "next/image";
import {
  Activity,
  Bot,
  Bell,
  Check,
  ChevronRight,
  CircleAlert,
  Command,
  ExternalLink,
  Eye,
  EyeOff,
  KeyRound,
  LayoutDashboard,
  Link2,
  Plus,
  RefreshCw,
  Search,
  Settings,
  ShieldCheck,
  Sparkles,
  Terminal,
  Wifi,
  X,
} from "lucide-react";
import { useEffect, useMemo, useState, type ComponentType } from "react";

type View = "overview" | "agents" | "providers";
type Tone = "green" | "purple" | "blue" | "orange" | "gray" | "red";

type Agent = {
  id: string;
  name: string;
  brand: string;
  tone: Tone;
  state: string;
  stateTone: Tone;
  activity: string;
  detail: string;
  auth: string;
  observation: string;
  quota: string;
  connected: boolean;
};

type Provider = {
  id: string;
  name: string;
  brand: string;
  tone: Tone;
  state: string;
  stateTone: Tone;
  balance: string;
  secondary: string;
  endpoint: string;
  scope: string;
  connected: boolean;
};

const agents: Agent[] = [
  {
    id: "codex",
    name: "Codex",
    brand: "codex",
    tone: "green",
    state: "工作中",
    stateTone: "purple",
    activity: "优化多 Agent 控制台",
    detail: "2 个任务 · 更新于刚刚",
    auth: "ChatGPT OAuth PKCE",
    observation: "本地只读 · SQLite / JSONL",
    quota: "5h 82% · 周 76%",
    connected: true,
  },
  {
    id: "kimi",
    name: "Kimi Code",
    brand: "kimi-code",
    tone: "blue",
    state: "待确认",
    stateTone: "orange",
    activity: "是否执行完整测试？",
    detail: "Managed Session · ACP",
    auth: "委托 kimi login",
    observation: "ACP / WebSocket",
    quota: "会员额度 · 实验读取",
    connected: true,
  },
  {
    id: "qwen",
    name: "Qwen Code",
    brand: "qwen-code",
    tone: "purple",
    state: "空闲",
    stateTone: "gray",
    activity: "Hooks 已就绪",
    detail: "Attached Session",
    auth: "官方 CLI / API Key",
    observation: "官方 Hooks",
    quota: "计划页 ↗",
    connected: true,
  },
  {
    id: "claude",
    name: "Claude Code",
    brand: "claude-code",
    tone: "orange",
    state: "未连接",
    stateTone: "gray",
    activity: "连接官方 CLI 后显示活动",
    detail: "支持 Hooks / Agent SDK",
    auth: "委托 claude 登录",
    observation: "Hooks / SDK",
    quota: "会话成本",
    connected: false,
  },
  {
    id: "qoder",
    name: "Qoder",
    brand: "qoder",
    tone: "red",
    state: "未安装",
    stateTone: "gray",
    activity: "发现 CLI 后可启用",
    detail: "Managed + Attached",
    auth: "qodercliAuth() / PAT",
    observation: "ACP + Hooks",
    quota: "Usage 页面 ↗",
    connected: false,
  },
];

const providers: Provider[] = [
  {
    id: "deepseek",
    name: "DeepSeek",
    brand: "deepseek",
    tone: "blue",
    state: "可用",
    stateTone: "green",
    balance: "¥42.80",
    secondary: "充值 ¥38.00 · 赠送 ¥4.80",
    endpoint: "GET /user/balance",
    scope: "API Key · Official API",
    connected: true,
  },
  {
    id: "openrouter",
    name: "OpenRouter",
    brand: "openrouter",
    tone: "purple",
    state: "可用",
    stateTone: "green",
    balance: "$8.20",
    secondary: "本月已用 $11.80 · 限额 $20",
    endpoint: "GET /api/v1/key",
    scope: "API Key · Official API",
    connected: true,
  },
  {
    id: "moonshot",
    name: "Moonshot",
    brand: "moonshot",
    tone: "gray",
    state: "需要 Key",
    stateTone: "orange",
    balance: "—",
    secondary: "与 Kimi Code 会员额度分开",
    endpoint: "GET /v1/users/me/balance",
    scope: "API Key · Official API",
    connected: false,
  },
  {
    id: "siliconflow",
    name: "SiliconFlow",
    brand: "siliconflow",
    tone: "orange",
    state: "凭证失效",
    stateTone: "red",
    balance: "上次 ¥16.42",
    secondary: "18 分钟前 · 已过期",
    endpoint: "GET /v1/user/info",
    scope: "API Key · Official API",
    connected: true,
  },
];

const toneStyles: Record<Tone, string> = {
  green: "bg-emerald-500/12 text-emerald-600 dark:text-emerald-400",
  purple: "bg-violet-500/12 text-violet-600 dark:text-violet-400",
  blue: "bg-blue-500/12 text-blue-600 dark:text-blue-400",
  orange: "bg-orange-500/12 text-orange-600 dark:text-orange-400",
  gray: "bg-black/[0.045] text-[var(--preview-muted)] dark:bg-white/[0.07]",
  red: "bg-red-500/12 text-red-600 dark:text-red-400",
};

function Mark({
  brand,
  large = false,
}: {
  brand: string;
  large?: boolean;
}) {
  return (
    <span
      className={`grid shrink-0 place-items-center rounded-[12px] bg-[var(--preview-card)] ring-1 ring-[color:var(--preview-line)] ${
        large ? "h-11 w-11 p-2" : "h-9 w-9 p-1.5"
      }`}
    >
      <Image
        src={`/brand-assets/${brand}/color.svg`}
        alt=""
        width={large ? 34 : 28}
        height={large ? 34 : 28}
        unoptimized
        onError={(event) => {
          event.currentTarget.onerror = null;
          event.currentTarget.src = `/brand-assets/${brand}/icon.svg`;
        }}
        className="h-full w-full object-contain"
      />
    </span>
  );
}

function StateBadge({ label, tone }: { label: string; tone: Tone }) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-semibold ${toneStyles[tone]}`}
    >
      <span className="h-1.5 w-1.5 rounded-full bg-current" />
      {label}
    </span>
  );
}

function NavButton({
  active,
  icon: Icon,
  label,
  count,
  onClick,
}: {
  active: boolean;
  icon: ComponentType<{ className?: string }>;
  label: string;
  count?: number;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={`group flex w-full items-center gap-3 rounded-[12px] px-3 py-2.5 text-left text-[13px] font-medium transition-all duration-200 active:scale-[0.985] ${
        active
          ? "bg-[var(--preview-primary)] text-[var(--preview-on-primary)] shadow-[0_7px_18px_rgba(20,24,28,0.16)]"
          : "text-[var(--preview-muted)] hover:translate-x-0.5 hover:bg-black/[0.045] hover:text-[var(--preview-ink)] dark:hover:bg-white/[0.06]"
      }`}
    >
      <Icon className="h-4 w-4" />
      <span className="flex-1">{label}</span>
      {count !== undefined && (
        <span
          className={`grid min-w-5 place-items-center rounded-full px-1.5 py-0.5 text-[10px] ${
            active ? "bg-white/15" : "bg-black/5 dark:bg-white/10"
          }`}
        >
          {count}
        </span>
      )}
    </button>
  );
}

function Sidebar({
  view,
  setView,
  onUtility,
}: {
  view: View;
  setView: (view: View) => void;
  onUtility: (utility: "diagnostics" | "settings") => void;
}) {
  return (
    <aside className="relative flex w-[218px] shrink-0 flex-col overflow-hidden border-r border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] p-3">
      <div className="pointer-events-none absolute -left-20 top-20 h-56 w-56 rounded-full bg-emerald-400/[0.08] blur-3xl" />
      <div className="flex h-12 items-center gap-3 px-2">
        <Image
          src="/brand/codexling-logo.webp"
          alt=""
          width={34}
          height={34}
          priority
          className="h-[34px] w-[34px] rounded-[10px] shadow-sm"
        />
        <div>
          <div className="text-[14px] font-bold tracking-[-0.02em] text-[var(--preview-ink)]">
            Tomo
          </div>
          <div className="text-[10px] text-[var(--preview-muted)]">
            Local Control Plane
          </div>
        </div>
      </div>

      <div className="mt-5 space-y-1">
        <NavButton
          active={view === "overview"}
          icon={LayoutDashboard}
          label="总览"
          onClick={() => setView("overview")}
        />
        <NavButton
          active={view === "agents"}
          icon={Bot}
          label="Agents"
          count={5}
          onClick={() => setView("agents")}
        />
        <NavButton
          active={view === "providers"}
          icon={KeyRound}
          label="API Providers"
          count={4}
          onClick={() => setView("providers")}
        />
      </div>

      <div className="mt-6 px-3 text-[9px] font-bold uppercase tracking-[0.16em] text-[var(--preview-muted)]">
        Workspace
      </div>
      <div className="mt-2 rounded-[12px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] p-3">
        <div className="flex items-center gap-2 text-[11px] font-semibold text-[var(--preview-ink)]">
          <span className="h-2 w-2 rounded-full bg-emerald-500" />
          全部本地运行
        </div>
        <p className="mt-1.5 text-[9px] leading-4 text-[var(--preview-muted)]">
          不上传 prompt、命令参数或 API Key
        </p>
      </div>

      <div className="mt-auto space-y-1 border-t border-[color:var(--preview-line)] pt-3">
        <NavButton
          active={false}
          icon={Activity}
          label="诊断"
          onClick={() => onUtility("diagnostics")}
        />
        <NavButton
          active={false}
          icon={Settings}
          label="设置"
          onClick={() => onUtility("settings")}
        />
      </div>
    </aside>
  );
}

function PageHeader({
  eyebrow,
  title,
  description,
  action,
}: {
  eyebrow: string;
  title: string;
  description: string;
  action?: React.ReactNode;
}) {
  return (
    <div className="flex items-start justify-between gap-6">
      <div>
        <div className="text-[10px] font-bold uppercase tracking-[0.16em] text-[var(--preview-muted)]">
          {eyebrow}
        </div>
        <h1 className="mt-1 text-[26px] font-bold tracking-[-0.045em] text-[var(--preview-ink)]">
          {title}
        </h1>
        <p className="mt-1 text-[11px] text-[var(--preview-muted)]">
          {description}
        </p>
      </div>
      {action}
    </div>
  );
}

function AppToolbar({
  onSearch,
  onNotice,
}: {
  onSearch: () => void;
  onNotice: () => void;
}) {
  return (
    <div className="flex h-[58px] shrink-0 items-center border-b border-[color:var(--preview-line)] bg-[color:var(--preview-card)]/78 px-5 backdrop-blur-xl">
      <div className="flex gap-2" aria-hidden>
        <span className="h-3 w-3 rounded-full border border-[#df4b45] bg-[#ff5f57]" />
        <span className="h-3 w-3 rounded-full border border-[#d89e24] bg-[#febc2e]" />
        <span className="h-3 w-3 rounded-full border border-[#17a92f] bg-[#28c840]" />
      </div>
      <button
        type="button"
        onClick={onSearch}
        className="mx-auto flex h-8 w-[260px] items-center gap-2 rounded-[10px] border border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] px-3 text-[10px] text-[var(--preview-muted)] transition hover:border-black/15 hover:bg-[var(--preview-card)] dark:hover:border-white/20"
      >
        <Search className="h-3.5 w-3.5" />
        <span className="flex-1 text-left">搜索 Agent、Provider 或设置</span>
        <span className="flex items-center gap-0.5 rounded border border-[color:var(--preview-line)] px-1.5 py-0.5 text-[8px]">
          <Command className="h-2.5 w-2.5" />K
        </span>
      </button>
      <div className="flex items-center gap-2">
        <button
          type="button"
          onClick={onNotice}
          className="relative grid h-8 w-8 place-items-center rounded-[9px] text-[var(--preview-muted)] transition hover:bg-black/5 hover:text-[var(--preview-ink)] dark:hover:bg-white/10"
          aria-label="通知"
        >
          <Bell className="h-4 w-4" />
          <span className="absolute right-1.5 top-1.5 h-1.5 w-1.5 rounded-full bg-orange-500 ring-2 ring-[var(--preview-card)]" />
        </button>
        <span className="h-6 w-px bg-[var(--preview-line)]" />
        <div className="grid h-8 w-8 place-items-center rounded-full bg-[linear-gradient(145deg,#d8f8e1,#8ee4a8)] text-[10px] font-bold text-emerald-800 shadow-sm">
          CU
        </div>
      </div>
    </div>
  );
}

function Overview({
  openAgent,
  openProvider,
  onRefresh,
}: {
  openAgent: (id?: string) => void;
  openProvider: (id?: string) => void;
  onRefresh: () => void;
}) {
  return (
    <div>
      <PageHeader
        eyebrow="Friday · 22:29"
        title="晚上好，Tomo User"
        description="2 个 Agent 正在工作，1 个任务等待你的确认。"
        action={
          <button
            type="button"
            onClick={onRefresh}
            className="flex items-center gap-2 rounded-full border border-emerald-500/15 bg-emerald-500/[0.08] px-3 py-1.5 text-[10px] font-semibold text-emerald-600 transition hover:bg-emerald-500/[0.14] active:scale-95 dark:text-emerald-400"
          >
            <Wifi className="h-3 w-3" /> 本地服务正常
          </button>
        }
      />

      <div className="mt-6 grid grid-cols-[1.12fr_0.88fr] gap-4">
        <section className="rounded-[20px] border border-[color:var(--preview-line)] bg-[color:var(--preview-card)]/92 p-4 shadow-[var(--preview-card-shadow)] transition-shadow hover:shadow-[0_16px_38px_rgba(36,41,51,0.1)]">
          <div className="flex items-center justify-between">
            <h2 className="text-[13px] font-bold text-[var(--preview-ink)]">
              Agents
            </h2>
            <button
              type="button"
              onClick={() => openAgent()}
              className="flex items-center text-[10px] font-semibold text-[var(--preview-muted)] hover:text-[var(--preview-ink)]"
            >
              管理 <ChevronRight className="h-3.5 w-3.5" />
            </button>
          </div>
          <div className="mt-3 space-y-2">
            {agents.slice(0, 3).map((agent) => (
              <button
                key={agent.id}
                type="button"
                onClick={() => openAgent(agent.id)}
                className="group flex w-full items-center gap-3 rounded-[14px] border border-[color:var(--preview-line)] px-3 py-3 text-left transition-all duration-200 hover:-translate-y-0.5 hover:border-black/15 hover:shadow-sm active:translate-y-0 dark:hover:border-white/20"
              >
                <Mark brand={agent.brand} />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span className="text-[12px] font-bold text-[var(--preview-ink)]">
                      {agent.name}
                    </span>
                    <StateBadge label={agent.state} tone={agent.stateTone} />
                  </div>
                  <div className="mt-1 truncate text-[10px] text-[var(--preview-muted)]">
                    {agent.activity}
                  </div>
                </div>
                <ChevronRight className="h-4 w-4 text-[var(--preview-muted)] transition-transform group-hover:translate-x-0.5" />
              </button>
            ))}
          </div>
        </section>

        <section className="relative overflow-hidden rounded-[20px] border border-emerald-500/15 bg-[linear-gradient(145deg,var(--preview-sidebar),var(--preview-card))] p-4 shadow-[var(--preview-card-shadow)]">
          <div className="pointer-events-none absolute -right-12 -top-12 h-40 w-40 rounded-full bg-emerald-400/15 blur-3xl" />
          <div className="relative z-10 flex items-center justify-between">
            <div>
              <div className="text-[10px] font-semibold text-[var(--preview-muted)]">
                Pet 当前跟随
              </div>
              <div className="mt-1 text-[16px] font-bold text-[var(--preview-ink)]">
                Kimi Code
              </div>
            </div>
            <StateBadge label="等待你确认" tone="orange" />
          </div>
          <div className="relative z-10 mt-3 flex items-center justify-center">
            <Image
              src="/brand/codexling-logo.webp"
              alt=""
              width={124}
              height={124}
              className="h-[124px] w-[124px] animate-float drop-shadow-[0_18px_18px_rgba(0,0,0,0.16)]"
            />
          </div>
          <div className="relative z-10 text-center text-[10px] text-[var(--preview-muted)]">
            今天一起工作 2 小时 21 分钟
          </div>
        </section>
      </div>

      <section className="mt-4 rounded-[20px] border border-[color:var(--preview-line)] bg-[color:var(--preview-card)]/92 p-4 shadow-[var(--preview-card-shadow)]">
        <div className="flex items-center justify-between">
          <div>
            <h2 className="text-[13px] font-bold text-[var(--preview-ink)]">
              Budget
            </h2>
            <p className="mt-0.5 text-[9px] text-[var(--preview-muted)]">
              订阅额度与 API 余额按来源分别显示
            </p>
          </div>
          <button
            type="button"
            onClick={() => openProvider()}
            className="flex items-center text-[10px] font-semibold text-[var(--preview-muted)] hover:text-[var(--preview-ink)]"
          >
            查看全部 <ChevronRight className="h-3.5 w-3.5" />
          </button>
        </div>
        <div className="mt-3 grid grid-cols-3 gap-3">
          <BudgetCard name="Codex" value="76%" detail="周额度 · 8月5日重置" tone="green" onClick={() => openAgent("codex")} />
          <BudgetCard name="DeepSeek" value="¥42.80" detail="官方 API · 刚刚" tone="blue" onClick={() => openProvider("deepseek")} />
          <BudgetCard name="OpenRouter" value="$8.20" detail="Key 剩余额度 · 2 分钟前" tone="purple" onClick={() => openProvider("openrouter")} />
        </div>
      </section>
    </div>
  );
}

function BudgetCard({
  name,
  value,
  detail,
  tone,
  onClick,
}: {
  name: string;
  value: string;
  detail: string;
  tone: Tone;
  onClick: () => void;
}) {
  return (
    <button type="button" onClick={onClick} className="group rounded-[15px] border border-[color:var(--preview-line)] p-3 text-left transition-all duration-200 hover:-translate-y-0.5 hover:border-black/15 hover:shadow-md active:translate-y-0 dark:hover:border-white/20">
      <div className="flex items-center gap-2 text-[10px] font-semibold text-[var(--preview-muted)]">
        <span className={`h-2 w-2 rounded-full ${toneStyles[tone]}`} />
        {name}
      </div>
      <div className="mt-2 text-[20px] font-bold tracking-[-0.04em] text-[var(--preview-ink)]">
        {value}
      </div>
      <div className="mt-1 text-[9px] text-[var(--preview-muted)]">{detail}</div>
      <div className="mt-2 h-1 overflow-hidden rounded-full bg-[var(--preview-track)]">
        <div className={`h-full w-[72%] rounded-full ${toneStyles[tone]}`} />
      </div>
    </button>
  );
}

function AgentsView({
  selected,
  setSelected,
  onConnect,
  onFeedback,
}: {
  selected: string;
  setSelected: (id: string) => void;
  onConnect: (id: string) => void;
  onFeedback: (message: string) => void;
}) {
  const [query, setQuery] = useState("");
  const agent = agents.find((item) => item.id === selected) ?? agents[0];
  const filteredAgents = agents.filter((item) =>
    `${item.name} ${item.state} ${item.observation}`
      .toLowerCase()
      .includes(query.toLowerCase()),
  );

  return (
    <div>
      <PageHeader
        eyebrow="Integrations"
        title="Agents"
        description="用官方登录、Hooks 或 ACP 连接你正在使用的 Coding Agent。"
        action={
          <div className="flex items-center gap-2">
            <button type="button" onClick={() => onFeedback("已重新扫描本机 Agent")} className="flex h-9 items-center gap-2 rounded-[11px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] px-3 text-[10px] font-semibold text-[var(--preview-muted)] transition hover:bg-[var(--preview-sidebar)] hover:text-[var(--preview-ink)] active:scale-95">
              <RefreshCw className="h-3.5 w-3.5" /> 重新扫描
            </button>
            <button type="button" onClick={() => onConnect("claude")} className="flex h-9 items-center gap-2 rounded-[11px] bg-[var(--preview-primary)] px-3.5 text-[11px] font-bold text-[var(--preview-on-primary)] shadow-sm transition hover:-translate-y-0.5 hover:shadow-lg active:translate-y-0">
              <Plus className="h-3.5 w-3.5" /> 添加 Agent
            </button>
          </div>
        }
      />
      <div className="mt-5 grid grid-cols-[1fr_270px] gap-4">
        <section className="overflow-hidden rounded-[18px] border border-[color:var(--preview-line)] bg-[var(--preview-card)]">
          <div className="flex h-12 items-center gap-2 border-b border-[color:var(--preview-line)] px-4">
            <Search className="h-3.5 w-3.5 text-[var(--preview-muted)]" />
            <input
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              aria-label="搜索 Agent"
              placeholder="搜索已安装或支持的 Agent"
              className="min-w-0 flex-1 bg-transparent text-[10px] text-[var(--preview-ink)] outline-none placeholder:text-[var(--preview-muted)]"
            />
            <span className="ml-auto text-[9px] font-semibold text-[var(--preview-muted)]">
              3 已连接
            </span>
          </div>
          <div className="divide-y divide-[color:var(--preview-line)]">
            {filteredAgents.map((item) => (
              <button
                key={item.id}
                type="button"
                onClick={() => setSelected(item.id)}
                className={`group flex w-full items-center gap-3 px-4 py-3.5 text-left transition-all ${
                  selected === item.id
                    ? "bg-[var(--preview-sidebar)]"
                    : "hover:bg-black/[0.02] dark:hover:bg-white/[0.03]"
                }`}
              >
                <Mark brand={item.brand} />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-2">
                    <span className="text-[12px] font-bold text-[var(--preview-ink)]">
                      {item.name}
                    </span>
                    <StateBadge label={item.state} tone={item.stateTone} />
                  </div>
                  <div className="mt-1 truncate text-[10px] text-[var(--preview-muted)]">
                    {item.activity}
                  </div>
                </div>
                <div className="text-right">
                  <div className="text-[9px] font-semibold text-[var(--preview-ink)]">
                    {item.quota}
                  </div>
                  <div className="mt-1 text-[9px] text-[var(--preview-muted)]">
                    {item.detail}
                  </div>
                </div>
                <ChevronRight className="h-4 w-4 text-[var(--preview-muted)] transition-transform group-hover:translate-x-0.5" />
              </button>
            ))}
            {filteredAgents.length === 0 && (
              <div className="px-4 py-12 text-center text-[10px] text-[var(--preview-muted)]">
                没有找到匹配的 Agent
              </div>
            )}
          </div>
        </section>

        <DetailPanel
          brand={agent.brand}
          name={agent.name}
          state={<StateBadge label={agent.state} tone={agent.stateTone} />}
          rows={[
            ["登录", agent.auth],
            ["活动来源", agent.observation],
            ["额度", agent.quota],
          ]}
          note={
            agent.connected
              ? "Tomo 只保存连接状态，不读取官方 CLI 的 token 文件。"
              : "登录将交给官方 CLI 或 SDK 完成，Tomo 不接触账号密码。"
          }
          actionLabel={agent.connected ? "管理集成" : "连接 Agent"}
          onAction={() => onConnect(agent.id)}
          onOfficial={() => onFeedback(`已准备打开 ${agent.name} 官方页面`)}
        />
      </div>
    </div>
  );
}

function ProvidersView({
  selected,
  setSelected,
  onConnect,
  onFeedback,
}: {
  selected: string;
  setSelected: (id: string) => void;
  onConnect: (id: string) => void;
  onFeedback: (message: string) => void;
}) {
  const provider =
    providers.find((item) => item.id === selected) ?? providers[0];

  return (
    <div>
      <PageHeader
        eyebrow="Connections"
        title="API Providers"
        description="连接推理 Key，并分别查看余额、消费与限流状态。"
        action={
          <div className="flex items-center gap-2">
            <button type="button" onClick={() => onFeedback("4 个 Provider 额度已刷新")} className="flex h-9 items-center gap-2 rounded-[11px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] px-3 text-[10px] font-semibold text-[var(--preview-muted)] transition hover:bg-[var(--preview-sidebar)] hover:text-[var(--preview-ink)] active:scale-95">
              <RefreshCw className="h-3.5 w-3.5" /> 刷新额度
            </button>
            <button
              type="button"
              onClick={() => onConnect("moonshot")}
              className="flex h-9 items-center gap-2 rounded-[11px] bg-[var(--preview-primary)] px-3.5 text-[11px] font-bold text-[var(--preview-on-primary)] shadow-sm transition hover:-translate-y-0.5 hover:shadow-lg active:translate-y-0"
            >
              <Plus className="h-3.5 w-3.5" /> 连接 Provider
            </button>
          </div>
        }
      />
      <div className="mt-5 grid grid-cols-[1fr_270px] gap-4">
        <section className="overflow-hidden rounded-[18px] border border-[color:var(--preview-line)] bg-[var(--preview-card)]">
          <div className="grid grid-cols-[1.2fr_0.8fr_0.9fr] border-b border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] px-4 py-2.5 text-[9px] font-bold uppercase tracking-[0.11em] text-[var(--preview-muted)]">
            <span>Provider</span>
            <span>余额 / 限额</span>
            <span>状态</span>
          </div>
          <div className="divide-y divide-[color:var(--preview-line)]">
            {providers.map((item) => (
              <button
                key={item.id}
                type="button"
                onClick={() => setSelected(item.id)}
                className={`grid w-full grid-cols-[1.2fr_0.8fr_0.9fr] items-center px-4 py-4 text-left transition ${
                  selected === item.id
                    ? "bg-[var(--preview-sidebar)]"
                    : "hover:bg-black/[0.02] dark:hover:bg-white/[0.03]"
                }`}
              >
                <div className="flex items-center gap-3">
                  <Mark brand={item.brand} />
                  <div>
                    <div className="text-[12px] font-bold text-[var(--preview-ink)]">
                      {item.name}
                    </div>
                    <div className="mt-1 text-[9px] text-[var(--preview-muted)]">
                      {item.scope}
                    </div>
                  </div>
                </div>
                <div>
                  <div className="text-[14px] font-bold text-[var(--preview-ink)]">
                    {item.balance}
                  </div>
                  <div className="mt-1 max-w-[125px] text-[9px] leading-3.5 text-[var(--preview-muted)]">
                    {item.secondary}
                  </div>
                </div>
                <div className="flex items-center justify-between gap-2">
                  <StateBadge label={item.state} tone={item.stateTone} />
                  <ChevronRight className="h-4 w-4 text-[var(--preview-muted)]" />
                </div>
              </button>
            ))}
          </div>
        </section>

        <DetailPanel
          brand={provider.brand}
          name={provider.name}
          state={<StateBadge label={provider.state} tone={provider.stateTone} />}
          rows={[
            ["查询接口", provider.endpoint],
            ["查询范围", provider.scope],
            ["最近结果", provider.secondary],
          ]}
          note="Key 只写入 macOS Keychain。卡片始终标记数据来源、scope 与最后更新时间。"
          actionLabel={provider.connected ? "更新 API Key" : "添加 API Key"}
          onAction={() => onConnect(provider.id)}
          onOfficial={() => onFeedback(`已准备打开 ${provider.name} 控制台`)}
        />
      </div>
    </div>
  );
}

function DetailPanel({
  brand,
  name,
  state,
  rows,
  note,
  actionLabel,
  onAction,
  onOfficial,
}: {
  brand: string;
  name: string;
  state: React.ReactNode;
  rows: [string, string][];
  note: string;
  actionLabel: string;
  onAction: () => void;
  onOfficial: () => void;
}) {
  return (
    <aside className="flex min-h-[460px] flex-col rounded-[18px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] p-4 shadow-[var(--preview-card-shadow)]">
      <div className="flex items-center gap-3">
        <Mark brand={brand} large />
        <div className="min-w-0">
          <div className="truncate text-[15px] font-bold text-[var(--preview-ink)]">
            {name}
          </div>
          <div className="mt-1">{state}</div>
        </div>
      </div>
      <div className="mt-5 space-y-4">
        {rows.map(([label, value]) => (
          <div key={label}>
            <div className="text-[9px] font-bold uppercase tracking-[0.12em] text-[var(--preview-muted)]">
              {label}
            </div>
            <div className="mt-1.5 text-[11px] font-semibold leading-4 text-[var(--preview-ink)]">
              {value}
            </div>
          </div>
        ))}
      </div>
      <div className="mt-5 rounded-[12px] bg-[var(--preview-sidebar)] p-3">
        <div className="flex items-start gap-2">
          <ShieldCheck className="mt-0.5 h-3.5 w-3.5 shrink-0 text-emerald-500" />
          <p className="text-[9px] leading-4 text-[var(--preview-muted)]">{note}</p>
        </div>
      </div>
      <button
        type="button"
        onClick={onAction}
        className="mt-auto flex h-10 w-full items-center justify-center gap-2 rounded-[11px] bg-[var(--preview-primary)] text-[11px] font-bold text-[var(--preview-on-primary)]"
      >
        <Link2 className="h-3.5 w-3.5" />
        {actionLabel}
      </button>
      <button
        type="button"
        onClick={onOfficial}
        className="mt-2 flex h-9 w-full items-center justify-center gap-2 rounded-[11px] border border-[color:var(--preview-line)] text-[10px] font-semibold text-[var(--preview-muted)]"
      >
        打开官方页面 <ExternalLink className="h-3 w-3" />
      </button>
    </aside>
  );
}

function ConnectionSheet({
  kind,
  itemId,
  onClose,
  onComplete,
}: {
  kind: "agent" | "provider";
  itemId: string;
  onClose: () => void;
  onComplete: (message: string) => void;
}) {
  const [showKey, setShowKey] = useState(false);
  const [phase, setPhase] = useState<"form" | "checking" | "success">("form");
  const item =
    kind === "agent"
      ? agents.find((agent) => agent.id === itemId)
      : providers.find((provider) => provider.id === itemId);

  const isAgent = kind === "agent";
  const name = item?.name ?? "Connection";
  const brand = item?.brand ?? "codex";

  const submit = () => {
    setPhase("checking");
    window.setTimeout(() => setPhase("success"), 850);
  };

  return (
    <div className="absolute inset-0 z-30 flex items-center justify-end bg-black/25 p-3 backdrop-blur-[2px]">
      <button
        type="button"
        aria-label="关闭连接面板"
        className="absolute inset-0"
        onClick={onClose}
      />
      <section className="relative flex h-full w-[342px] flex-col rounded-[19px] border border-white/20 bg-[var(--preview-card)] p-5 shadow-2xl">
        <div className="flex items-start justify-between">
          <div className="flex items-center gap-3">
            <Mark brand={brand} large />
            <div>
              <div className="text-[10px] text-[var(--preview-muted)]">
                {isAgent ? "连接 Agent" : "连接 API Provider"}
              </div>
              <h2 className="text-[17px] font-bold text-[var(--preview-ink)]">
                {name}
              </h2>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="grid h-8 w-8 place-items-center rounded-full bg-black/5 text-[var(--preview-muted)] dark:bg-white/10"
          >
            <X className="h-4 w-4" />
          </button>
        </div>

        {phase === "success" ? (
          <div className="flex flex-1 flex-col items-center justify-center text-center">
            <div className="grid h-14 w-14 place-items-center rounded-full bg-emerald-500/12 text-emerald-500">
              <Check className="h-7 w-7" />
            </div>
            <div className="mt-4 text-[17px] font-bold text-[var(--preview-ink)]">
              连接验证成功
            </div>
            <p className="mt-2 max-w-[240px] text-[10px] leading-5 text-[var(--preview-muted)]">
              {isAgent
                ? "已确认官方会话。下一步可以安装活动 Hooks。"
                : "Key 可用，已取得最新额度快照。明文不会写入页面或缓存。"}
            </p>
            <button
              type="button"
              onClick={() => {
                onComplete(`${name} 已连接并完成验证`);
                onClose();
              }}
              className="mt-6 h-10 w-full rounded-[11px] bg-[var(--preview-primary)] text-[11px] font-bold text-[var(--preview-on-primary)]"
            >
              完成
            </button>
          </div>
        ) : (
          <>
            <div className="mt-6 flex rounded-[11px] bg-[var(--preview-sidebar)] p-1 text-[10px] font-semibold">
              <span className="flex-1 rounded-[8px] bg-[var(--preview-card)] px-3 py-2 text-center text-[var(--preview-ink)] shadow-sm">
                {isAgent ? "官方登录" : "API Key"}
              </span>
              <span className="flex-1 px-3 py-2 text-center text-[var(--preview-muted)]">
                {isAgent ? "API Key / PAT" : "高级凭证"}
              </span>
            </div>

            {isAgent ? (
              <div className="mt-5">
                <div className="rounded-[14px] border border-[color:var(--preview-line)] p-4">
                  <div className="flex items-center gap-3">
                    <div className="grid h-10 w-10 place-items-center rounded-[11px] bg-[var(--preview-sidebar)]">
                      <Terminal className="h-5 w-5 text-[var(--preview-ink)]" />
                    </div>
                    <div>
                      <div className="text-[11px] font-bold text-[var(--preview-ink)]">
                        委托官方 CLI
                      </div>
                      <div className="mt-1 text-[9px] text-[var(--preview-muted)]">
                        {name === "Kimi Code" ? "kimi login" : `${name.toLowerCase()} login`}
                      </div>
                    </div>
                  </div>
                  <p className="mt-3 text-[9px] leading-4 text-[var(--preview-muted)]">
                    Tomo 只启动官方登录流程并观察是否完成，不读取 token 文件。
                  </p>
                </div>
                <div className="mt-3 rounded-[12px] bg-blue-500/[0.08] p-3 text-[9px] leading-4 text-blue-600 dark:text-blue-300">
                  登录完成后，可单独预览并安装 Hooks。卸载时只移除 Tomo 自己写入的配置块。
                </div>
              </div>
            ) : (
              <div className="mt-5">
                <label className="text-[10px] font-bold text-[var(--preview-ink)]">
                  API Key
                </label>
                <div className="mt-2 flex h-11 items-center rounded-[11px] border border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] px-3">
                  <KeyRound className="h-3.5 w-3.5 text-[var(--preview-muted)]" />
                  <input
                    aria-label={`${name} API Key`}
                    type={showKey ? "text" : "password"}
                    defaultValue="sk-demo-key-for-interface-preview"
                    className="min-w-0 flex-1 bg-transparent px-2 text-[10px] text-[var(--preview-ink)] outline-none"
                  />
                  <button
                    type="button"
                    aria-label={showKey ? "隐藏 API Key" : "显示 API Key"}
                    onClick={() => setShowKey((value) => !value)}
                    className="text-[var(--preview-muted)]"
                  >
                    {showKey ? (
                      <EyeOff className="h-3.5 w-3.5" />
                    ) : (
                      <Eye className="h-3.5 w-3.5" />
                    )}
                  </button>
                </div>
                <div className="mt-3 rounded-[12px] border border-[color:var(--preview-line)] p-3">
                  <div className="flex items-center justify-between text-[9px]">
                    <span className="font-bold text-[var(--preview-ink)]">
                      查询接口
                    </span>
                    <span className="font-mono text-[var(--preview-muted)]">
                      {"endpoint" in (item ?? {}) ? (item as Provider).endpoint : ""}
                    </span>
                  </div>
                  <div className="mt-2 flex items-center justify-between text-[9px]">
                    <span className="font-bold text-[var(--preview-ink)]">
                      本地保存
                    </span>
                    <span className="flex items-center gap-1 text-emerald-600 dark:text-emerald-400">
                      <ShieldCheck className="h-3 w-3" /> macOS Keychain
                    </span>
                  </div>
                </div>
              </div>
            )}

            <div className="mt-auto rounded-[12px] bg-[var(--preview-sidebar)] p-3">
              <div className="flex gap-2">
                <CircleAlert className="mt-0.5 h-3.5 w-3.5 shrink-0 text-orange-500" />
                <p className="text-[9px] leading-4 text-[var(--preview-muted)]">
                  这是界面交互原型，不会发送凭证或更改本机 Agent 配置。
                </p>
              </div>
            </div>
            <button
              type="button"
              onClick={submit}
              disabled={phase === "checking"}
              className="mt-3 flex h-10 items-center justify-center gap-2 rounded-[11px] bg-[var(--preview-primary)] text-[11px] font-bold text-[var(--preview-on-primary)] disabled:opacity-70"
            >
              {phase === "checking" ? (
                <>
                  <RefreshCw className="h-3.5 w-3.5 animate-spin" />
                  正在验证…
                </>
              ) : (
                <>
                  {isAgent ? <ExternalLink className="h-3.5 w-3.5" /> : <ShieldCheck className="h-3.5 w-3.5" />}
                  {isAgent ? "启动官方登录" : "验证并查询额度"}
                </>
              )}
            </button>
          </>
        )}
      </section>
    </div>
  );
}

function UtilitySheet({
  type,
  onClose,
  onFeedback,
}: {
  type: "diagnostics" | "settings" | "search" | "notices";
  onClose: () => void;
  onFeedback: (message: string) => void;
}) {
  const copy = {
    diagnostics: ["运行诊断", "所有适配器运行正常", "最近 24 小时没有隐私过滤或 Bridge 错误。"],
    settings: ["快速设置", "让 Tomo 更贴合你的节奏", "这些开关只用于预览交互，不会更改本机偏好。"],
    search: ["快速查找", "跳到任何连接", "搜索 Agent、Provider 或设置。"],
    notices: ["通知", "1 个任务需要你", "Kimi Code 正在等待确认，DeepSeek 余额状态已刷新。"],
  } as const;
  const [title, subtitle, description] = copy[type];
  const [searchValue, setSearchValue] = useState("");
  const [petFollowsActivity, setPetFollowsActivity] = useState(true);
  const [privacyMode, setPrivacyMode] = useState(true);

  return (
    <div className="absolute inset-0 z-30 flex items-center justify-center bg-black/20 p-8 backdrop-blur-[3px]">
      <button type="button" aria-label="关闭" className="absolute inset-0" onClick={onClose} />
      <section className="relative w-full max-w-[440px] overflow-hidden rounded-[22px] border border-white/25 bg-[var(--preview-card)] p-5 shadow-[0_30px_90px_rgba(0,0,0,0.28)]">
        <div className="pointer-events-none absolute -right-16 -top-16 h-44 w-44 rounded-full bg-emerald-400/10 blur-3xl" />
        <div className="relative flex items-start justify-between">
          <div>
            <div className="text-[10px] font-semibold text-emerald-600 dark:text-emerald-400">{subtitle}</div>
            <h2 className="mt-1 text-[20px] font-bold tracking-[-0.035em] text-[var(--preview-ink)]">{title}</h2>
            <p className="mt-1 text-[10px] leading-4 text-[var(--preview-muted)]">{description}</p>
          </div>
          <button type="button" onClick={onClose} className="grid h-8 w-8 place-items-center rounded-full bg-black/5 text-[var(--preview-muted)] transition hover:bg-black/10 dark:bg-white/10 dark:hover:bg-white/15">
            <X className="h-4 w-4" />
          </button>
        </div>

        {type === "search" && (
          <div className="relative mt-5">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-[var(--preview-muted)]" />
            <input autoFocus value={searchValue} onChange={(event) => setSearchValue(event.target.value)} placeholder="例如 Kimi、余额、隐私…" className="h-11 w-full rounded-[12px] border border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] pl-10 pr-3 text-[11px] text-[var(--preview-ink)] outline-none transition focus:border-emerald-500/45 focus:ring-4 focus:ring-emerald-500/10" />
            {searchValue && (
              <button type="button" onClick={() => { onFeedback(`已搜索“${searchValue}”`); onClose(); }} className="mt-3 flex w-full items-center justify-between rounded-[12px] border border-[color:var(--preview-line)] px-3 py-3 text-left transition hover:bg-[var(--preview-sidebar)]">
                <span className="text-[11px] font-semibold text-[var(--preview-ink)]">在所有连接中搜索 “{searchValue}”</span>
                <ChevronRight className="h-4 w-4 text-[var(--preview-muted)]" />
              </button>
            )}
          </div>
        )}

        {type === "diagnostics" && (
          <div className="mt-5 grid grid-cols-3 gap-2">
            {[['8', '适配器'], ['24ms', 'Bridge'], ['0', '错误']].map(([value, label]) => (
              <div key={label} className="rounded-[13px] border border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] p-3">
                <div className="text-[18px] font-bold text-[var(--preview-ink)]">{value}</div>
                <div className="mt-1 text-[9px] text-[var(--preview-muted)]">{label}</div>
              </div>
            ))}
          </div>
        )}

        {type === "notices" && (
          <div className="mt-5 space-y-2">
            <button type="button" onClick={() => onFeedback('已定位 Kimi Code 待确认任务')} className="flex w-full items-center gap-3 rounded-[13px] border border-orange-500/15 bg-orange-500/[0.06] p-3 text-left transition hover:bg-orange-500/[0.1]">
              <span className="h-2 w-2 rounded-full bg-orange-500" />
              <span className="flex-1 text-[10px] font-semibold text-[var(--preview-ink)]">Kimi Code 等待你确认测试</span>
              <span className="text-[9px] text-[var(--preview-muted)]">刚刚</span>
            </button>
            <div className="flex items-center gap-3 rounded-[13px] border border-[color:var(--preview-line)] p-3">
              <Check className="h-4 w-4 text-emerald-500" />
              <span className="flex-1 text-[10px] text-[var(--preview-ink)]">DeepSeek 余额刷新成功</span>
              <span className="text-[9px] text-[var(--preview-muted)]">2 分钟</span>
            </div>
          </div>
        )}

        {type === "settings" && (
          <div className="mt-5 space-y-2">
            <ToggleRow label="Pet 自动跟随最高优先级 Agent" checked={petFollowsActivity} onChange={setPetFollowsActivity} />
            <ToggleRow label="隐藏所有内容字段" checked={privacyMode} onChange={setPrivacyMode} />
          </div>
        )}

        {type !== "search" && (
          <button type="button" onClick={() => { onFeedback(type === 'diagnostics' ? '诊断已刷新，一切正常' : type === 'settings' ? '预览设置已保存' : '通知已全部读'); onClose(); }} className="mt-5 flex h-10 w-full items-center justify-center gap-2 rounded-[11px] bg-[var(--preview-primary)] text-[11px] font-bold text-[var(--preview-on-primary)] transition hover:-translate-y-0.5 hover:shadow-lg active:translate-y-0">
            {type === "diagnostics" && <RefreshCw className="h-3.5 w-3.5" />}
            {type === "settings" && <Check className="h-3.5 w-3.5" />}
            {type === "notices" && <Check className="h-3.5 w-3.5" />}
            {type === "diagnostics" ? "重新检查" : type === "settings" ? "保存设置" : "全部标为已读"}
          </button>
        )}
      </section>
    </div>
  );
}

function ToggleRow({ label, checked, onChange }: { label: string; checked: boolean; onChange: (checked: boolean) => void }) {
  return (
    <button type="button" aria-pressed={checked} onClick={() => onChange(!checked)} className="flex w-full items-center justify-between rounded-[13px] border border-[color:var(--preview-line)] px-3 py-3 text-left">
      <span className="text-[10px] font-semibold text-[var(--preview-ink)]">{label}</span>
      <span className={`relative h-5 w-9 rounded-full transition ${checked ? 'bg-emerald-500' : 'bg-[var(--preview-track)]'}`}>
        <span className={`absolute top-0.5 h-4 w-4 rounded-full bg-white shadow-sm transition ${checked ? 'left-[18px]' : 'left-0.5'}`} />
      </span>
    </button>
  );
}

export function MultiAgentPreview() {
  const [view, setView] = useState<View>("overview");
  const [selectedAgent, setSelectedAgent] = useState("kimi");
  const [selectedProvider, setSelectedProvider] = useState("deepseek");
  const [utility, setUtility] = useState<
    "diagnostics" | "settings" | "search" | "notices" | undefined
  >();
  const [feedback, setFeedback] = useState<string>();
  const [sheet, setSheet] = useState<
    { kind: "agent" | "provider"; itemId: string } | undefined
  >();

  const title = useMemo(() => {
    if (view === "agents") return "Agents";
    if (view === "providers") return "API Providers";
    return "总览";
  }, [view]);

  const showFeedback = (message: string) => {
    setFeedback(message);
    window.setTimeout(() => setFeedback(undefined), 2400);
  };

  const openAgent = (id?: string) => {
    if (id) setSelectedAgent(id);
    setView("agents");
  };

  const openProvider = (id?: string) => {
    if (id) setSelectedProvider(id);
    setView("providers");
  };

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault();
        setUtility("search");
      }
      if (event.key === "Escape") {
        setUtility(undefined);
        setSheet(undefined);
      }
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, []);

  return (
    <div className="relative flex min-h-screen items-center overflow-hidden bg-[linear-gradient(145deg,var(--preview-desktop),var(--preview-desktop-end))] px-4 py-7 text-[var(--preview-ink)] sm:px-6 lg:px-10">
      <div className="pointer-events-none absolute left-[8%] top-[8%] h-72 w-72 rounded-full bg-emerald-400/[0.08] blur-[90px]" />
      <div className="pointer-events-none absolute bottom-[4%] right-[8%] h-80 w-80 rounded-full bg-violet-400/[0.07] blur-[100px]" />
      <div className="relative mx-auto flex h-[min(790px,calc(100vh-56px))] min-h-[690px] w-full max-w-[1180px] flex-col overflow-hidden rounded-[26px] border border-white/45 bg-[color:var(--preview-panel)]/92 shadow-[0_42px_110px_rgba(24,28,32,0.2)] ring-1 ring-black/[0.04] backdrop-blur-xl dark:border-white/10">
        <AppToolbar
          onSearch={() => setUtility("search")}
          onNotice={() => setUtility("notices")}
        />
        <div className="flex min-h-0 flex-1">
          <Sidebar view={view} setView={setView} onUtility={setUtility} />
          <main className="relative min-w-0 flex-1 overflow-auto bg-[linear-gradient(145deg,var(--preview-panel),color-mix(in_srgb,var(--preview-panel)_94%,white))] p-6">
            <div key={view} className="animate-[preview-enter_260ms_ease-out]">
              {view === "overview" && (
                <Overview
                  openAgent={openAgent}
                  openProvider={openProvider}
                  onRefresh={() => showFeedback("所有本地状态已刷新")}
                />
              )}
              {view === "agents" && (
                <AgentsView
                  selected={selectedAgent}
                  setSelected={setSelectedAgent}
                  onConnect={(itemId) => setSheet({ kind: "agent", itemId })}
                  onFeedback={showFeedback}
                />
              )}
              {view === "providers" && (
                <ProvidersView
                  selected={selectedProvider}
                  setSelected={setSelectedProvider}
                  onConnect={(itemId) => setSheet({ kind: "provider", itemId })}
                  onFeedback={showFeedback}
                />
              )}
            </div>
            <div className="pointer-events-none absolute bottom-4 right-5 flex items-center gap-2 text-[8px] font-medium text-[var(--preview-muted)] opacity-65">
              <Sparkles className="h-3 w-3" /> {title} · Interactive preview
            </div>
          </main>
        </div>
        {sheet && (
          <ConnectionSheet
            kind={sheet.kind}
            itemId={sheet.itemId}
            onClose={() => setSheet(undefined)}
            onComplete={showFeedback}
          />
        )}
        {utility && (
          <UtilitySheet
            type={utility}
            onClose={() => setUtility(undefined)}
            onFeedback={showFeedback}
          />
        )}
        {feedback && (
          <div className="pointer-events-none absolute bottom-5 left-1/2 z-50 flex -translate-x-1/2 items-center gap-2 rounded-full border border-white/15 bg-[#17191d]/92 px-4 py-2.5 text-[10px] font-semibold text-white shadow-2xl backdrop-blur-xl animate-[preview-toast_280ms_ease-out]">
            <Check className="h-3.5 w-3.5 text-emerald-400" />
            {feedback}
          </div>
        )}
      </div>
    </div>
  );
}
