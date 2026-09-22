"use client";

import Image from "next/image";
import {
  useLayoutEffect,
  useRef,
  useState,
  type ReactNode,
} from "react";

type PreviewLayout = "horizontal" | "vertical";

const PREVIEW_SIZE: Record<
  PreviewLayout,
  { width: number; height: number }
> = {
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

function ThinkingCapsule() {
  return (
    <div className="status-edge-glow relative inline-flex h-9 w-fit max-w-full self-center items-center gap-2 overflow-hidden whitespace-nowrap rounded-full px-4 text-[11px] font-bold text-[var(--preview-menubar-pill-fg)] shadow-sm">
      <span className="status-edge-glow__inner" />
      <span className="relative z-10 h-2.5 w-2.5 shrink-0 rounded-full bg-[#7046ff] shadow-[0_0_9px_rgba(112,70,255,0.8)]" />
      <span className="relative z-10">Tomo · 正在思考</span>
    </div>
  );
}

function LayoutIcon({ layout }: { layout: PreviewLayout }) {
  if (layout === "horizontal") {
    return (
      <svg
        viewBox="0 0 20 16"
        aria-hidden
        className="h-4 w-5 shrink-0"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.6"
      >
        <rect x="1.25" y="1.25" width="17.5" height="13.5" rx="2.5" />
        <path d="M7 1.5v13" />
      </svg>
    );
  }

  return (
    <svg
      viewBox="0 0 14 18"
      aria-hidden
      className="h-[18px] w-3.5 shrink-0"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
    >
      <rect x="1.25" y="1.25" width="11.5" height="15.5" rx="2.5" />
      <path d="M1.5 7h11" />
    </svg>
  );
}

function PetPanel({ vertical = false }: { vertical?: boolean }) {
  return (
    <div
      className={
        vertical
          ? "relative flex h-[210px] shrink-0 flex-col items-center justify-end border-b border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] pb-4"
          : "relative flex h-full min-w-0 flex-col border-r border-[color:var(--preview-line)] bg-[var(--preview-sidebar)] px-5 pb-5 pt-4"
      }
    >
      <div className={vertical ? "absolute left-4 top-4" : ""}>
        <WindowDots />
      </div>
      {!vertical && (
        <div className="mt-8 min-w-0">
          <div className="flex items-center gap-2">
            <span className="truncate text-[16px] font-bold text-[var(--preview-ink)]">
              Tomo User
            </span>
            <span className="rounded-[6px] bg-[var(--preview-green-soft)] px-2 py-0.5 text-[10px] font-bold text-[var(--preview-green)]">
              plus
            </span>
          </div>
          <div className="mt-1 truncate text-[11px] text-[var(--preview-muted)]">
            user@example.com
          </div>
          <div className="mt-4 border-t border-[color:var(--preview-line)] pt-3 text-[10px] font-semibold text-[var(--preview-muted)]">
            8月21日 14:22 · 自动续费 ↗
          </div>
        </div>
      )}
      <div
        className={
          vertical
            ? "absolute top-10"
            : "flex flex-1 items-center justify-center"
        }
      >
        <Image
          src="/brand/codexling-logo.webp"
          alt=""
          width={150}
          height={150}
          priority
          className={
            vertical
              ? "h-[112px] w-[112px] drop-shadow-[0_16px_18px_rgba(0,0,0,0.2)]"
              : "h-auto w-[78%] max-w-[150px] drop-shadow-[0_16px_18px_rgba(0,0,0,0.2)]"
          }
        />
      </div>
      <ThinkingCapsule />
      <div className="mt-2 text-center text-[10px] font-medium text-[var(--preview-muted)]">
        今天一起工作 2 小时 21 分钟
      </div>
    </div>
  );
}

function AccountRow() {
  return (
    <div className="flex h-[58px] shrink-0 items-center justify-between gap-4 border-b border-[color:var(--preview-line)] bg-[var(--preview-panel)] px-4">
      <div className="min-w-0">
        <div className="flex items-center gap-2">
          <span className="truncate text-[15px] font-bold text-[var(--preview-ink)]">
            Tomo User
          </span>
          <span className="rounded-[6px] bg-[var(--preview-green-soft)] px-2 py-0.5 text-[9px] font-bold text-[var(--preview-green)]">
            plus
          </span>
        </div>
        <div className="truncate text-[10px] text-[var(--preview-muted)]">
          user@example.com
        </div>
      </div>
      <div className="shrink-0 text-[10px] font-semibold text-[var(--preview-muted)]">
        8月21日 14:22 · 自动续费 ↗
      </div>
    </div>
  );
}

function QuotaRing({
  label,
  percent,
}: {
  label: string;
  percent: number;
}) {
  return (
    <div className="flex min-w-0 flex-1 items-center gap-3 rounded-[14px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] px-4 py-3">
      <div
        className="h-11 w-11 shrink-0 rounded-full p-[6px]"
        style={{
          background: `conic-gradient(var(--preview-green) ${percent}%, var(--preview-track) 0)`,
        }}
      >
        <div className="h-full w-full rounded-full bg-[var(--preview-card)]" />
      </div>
      <div className="min-w-0">
        <div className="text-[19px] font-bold leading-none tabular-nums text-[var(--preview-ink)]">
          {percent}%
        </div>
        <div className="mt-1 truncate text-[10px] font-semibold text-[var(--preview-muted)]">
          {label}
        </div>
      </div>
    </div>
  );
}

function QuotaBar({
  label,
  percent,
}: {
  label: string;
  percent: number;
}) {
  return (
    <div className="flex h-8 items-center">
      <div className="flex w-[72px] shrink-0 items-center gap-2 text-[10px] font-semibold text-[var(--preview-muted)]">
        <span className="h-2 w-2 rounded-full bg-[var(--preview-green)]" />
        {label}
      </div>
      <div className="mx-3 h-1.5 flex-1 overflow-hidden rounded-full bg-[var(--preview-track)]">
        <div
          className="h-full rounded-full bg-[var(--preview-green)]"
          style={{ width: `${percent}%` }}
        />
      </div>
      <span className="w-10 text-right text-[13px] font-bold tabular-nums text-[var(--preview-ink)]">
        {percent}%
      </span>
    </div>
  );
}

function Quota({ variant }: { variant: "rings" | "bars" }) {
  return (
    <>
      <div className="flex items-center justify-between">
        <span className="text-[14px] font-bold text-[var(--preview-ink)]">
          额度
        </span>
        <span className="text-[10px] font-medium text-[var(--preview-muted)]">
          额度重置：8月5日 14:47
        </span>
      </div>
      {variant === "rings" ? (
        <div className="mt-2 flex gap-2">
          <QuotaRing label="5 小时" percent={82} />
          <QuotaRing label="本周" percent={76} />
        </div>
      ) : (
        <div className="mt-2 rounded-[14px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] px-4 py-1">
          <QuotaBar label="5 小时" percent={82} />
          <div className="h-px bg-[var(--preview-line)]/70" />
          <QuotaBar label="本周" percent={76} />
        </div>
      )}
    </>
  );
}

function CouponIcon() {
  return (
    <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-[12px] border border-white/70 bg-[linear-gradient(145deg,#9c9dff,#405dff)] text-white shadow-[0_5px_14px_rgba(76,92,255,0.32)]">
      <svg
        viewBox="0 0 28 28"
        aria-hidden
        className="h-[23px] w-[23px]"
        fill="none"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <path d="m7.5 6.5 6 7-6 7" strokeWidth="2.4" />
        <path d="M15.5 20.5h5" strokeWidth="2.4" />
      </svg>
    </div>
  );
}

function ResetCoupon({ compact = false }: { compact?: boolean }) {
  return (
    <section
      className={`mt-3 flex shrink-0 flex-col overflow-hidden rounded-[16px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] shadow-[var(--preview-card-shadow)] ${
        compact ? "h-[252px]" : "h-[266px]"
      }`}
    >
      <div className="h-[92px] shrink-0 px-4 pt-3">
        <div className="flex items-center justify-between">
          <span className="text-[12px] font-bold text-[var(--preview-ink)]">
            重置券有效期
          </span>
          <span className="text-[9px] font-semibold text-[var(--preview-muted)]">
            2 张 · 按到期排序
          </span>
        </div>
        <div className="relative mt-5 h-1 rounded-full bg-[var(--preview-track)]">
          <span className="absolute left-[26%] top-1/2 h-5 w-5 -translate-x-1/2 -translate-y-1/2 rounded-full border-[4px] border-[#c8f2d2] bg-[var(--preview-green)] shadow-sm" />
          <span className="absolute right-2 top-1/2 h-3.5 w-3.5 -translate-y-1/2 rounded-full border-[3px] border-white bg-[#d6dce5] shadow-sm" />
        </div>
        <div className="mt-4 grid grid-cols-[1.15fr_0.85fr] text-[8.5px] font-semibold text-[var(--preview-muted)]">
          <span>
            <span className="mr-2 text-[var(--preview-ink)]">类型</span>
            重置 Codex 速率额度
          </span>
          <span>
            <span className="mr-2 text-[var(--preview-ink)]">状态</span>
            available
          </span>
        </div>
      </div>
      <div className="flex min-h-0 flex-1 flex-col border-t border-[color:var(--preview-line)] px-4 pt-3">
        <div className="flex items-center">
          <CouponIcon />
          <div className="ml-3 min-w-0">
            <div className="truncate text-[12px] font-bold text-[var(--preview-ink)]">
              Codex Team
            </div>
            <div className="text-[9px] font-semibold text-[var(--preview-muted)]">
              授予 · 7月2日
            </div>
          </div>
          <span className="ml-auto text-[10px] font-bold text-[var(--preview-muted)]">
            1/2
          </span>
        </div>
        <div className="mt-2 text-[14px] font-bold leading-none text-[var(--preview-ink)]">
          Full reset
        </div>
        <div className="mt-1 truncate text-[9px] font-semibold text-[var(--preview-muted)]">
          Thanks for using Codex! You&apos;ve been granted one free rate limit reset.
        </div>
        <div className="-mx-4 mt-auto flex h-12 shrink-0 items-center justify-between rounded-t-[14px] bg-[#f8f9f9] px-4 dark:bg-[#323236]">
          <span className="text-[9px] font-semibold tabular-nums text-[var(--preview-muted)]">
            2026-08-01 03:50:25 到期
          </span>
          <div className="flex items-center gap-2">
            <span className="h-1.5 w-3 rounded-full bg-[var(--preview-green)]" />
            <span className="h-1.5 w-1.5 rounded-full bg-[var(--preview-line)]" />
            <span className="rounded-full border border-[color:var(--preview-green)]/25 bg-[var(--preview-green-soft)] px-2 py-1 text-[9px] font-bold text-[var(--preview-green)]">
              下一张
            </span>
          </div>
        </div>
      </div>
    </section>
  );
}

function ActivityCard() {
  return (
    <>
      <div className="flex items-center justify-between gap-3">
        <h3 className="truncate text-[20px] font-bold text-[var(--preview-ink)]">
          正在处理 1 个任务
        </h3>
        <div className="flex shrink-0 items-center gap-2 rounded-full border border-[color:var(--preview-green)]/20 bg-[var(--preview-green-soft)] px-3 py-1.5 text-[11px] font-bold text-[var(--preview-green)]">
          <span className="h-2 w-2 rounded-full bg-[var(--preview-green)]" />
          本周 76%
        </div>
      </div>
      <div className="mt-4 rounded-[16px] border border-[color:var(--preview-line)] bg-[var(--preview-card)] px-4 py-4">
        <div className="flex items-center justify-between text-[11px]">
          <span className="font-bold text-[#7046ff]">●&nbsp; 思考中</span>
          <span className="font-medium text-[var(--preview-muted)]">
            任务 1 / 1
          </span>
        </div>
        <div className="mt-3 text-[16px] font-bold text-[var(--preview-ink)]">
          优化 Tomo 落地页预览
        </div>
        <div className="mt-1 text-[11px] font-medium text-[var(--preview-muted)]">
          正在运行本地命令
        </div>
        <div className="mt-3 flex items-center gap-5 text-[9.5px] font-semibold text-[var(--preview-muted)]">
          <span>▱&nbsp; Tomo</span>
          <span>⑂&nbsp; main</span>
          <span>▣&nbsp; gpt-5.6-sol</span>
        </div>
        <div className="mt-4 flex items-center justify-between border-t border-[color:var(--preview-line)] pt-3 text-[10px] text-[var(--preview-muted)]">
          <span>分析任务</span>
          <span>更新于刚刚</span>
        </div>
      </div>
    </>
  );
}

function ActionButton({
  children,
  primary = false,
}: {
  children: ReactNode;
  primary?: boolean;
}) {
  return (
    <div
      className={`flex h-9 items-center justify-center rounded-[10px] text-[10px] font-bold ${
        primary
          ? "bg-[var(--preview-primary)] px-4 text-[var(--preview-on-primary)]"
          : "w-9 bg-[#f7f8f8] text-[var(--preview-muted)] dark:bg-[#343438]"
      }`}
    >
      {children}
    </div>
  );
}

function ActionIcon({
  name,
}: {
  name: "settings" | "external" | "power";
}) {
  if (name === "settings") {
    return (
      <svg
        viewBox="0 0 24 24"
        aria-hidden
        className="h-[18px] w-[18px]"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <circle cx="12" cy="12" r="3" />
        <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.12 2.12-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.55V20.3h-3v-.09a1.7 1.7 0 0 0-1.03-1.55 1.7 1.7 0 0 0-1.88.34l-.06.06-2.12-2.12.06-.06A1.7 1.7 0 0 0 7 15a1.7 1.7 0 0 0-1.55-1.03H5.3v-3h.15A1.7 1.7 0 0 0 7 9.94a1.7 1.7 0 0 0-.34-1.88L6.6 8l2.12-2.12.06.06a1.7 1.7 0 0 0 1.88.34A1.7 1.7 0 0 0 11.7 4.7V4.6h3v.1a1.7 1.7 0 0 0 1.03 1.55 1.7 1.7 0 0 0 1.88-.34l.06-.06L19.8 8l-.06.06a1.7 1.7 0 0 0-.34 1.88A1.7 1.7 0 0 0 20.95 11h.15v3h-.15A1.7 1.7 0 0 0 19.4 15Z" />
      </svg>
    );
  }

  if (name === "external") {
    return (
      <svg
        viewBox="0 0 24 24"
        aria-hidden
        className="h-[18px] w-[18px]"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinecap="round"
        strokeLinejoin="round"
      >
        <rect x="4" y="4" width="16" height="16" rx="3" />
        <path d="M10 14 16 8M11 8h5v5" />
      </svg>
    );
  }

  return (
    <svg
      viewBox="0 0 24 24"
      aria-hidden
      className="h-[19px] w-[19px]"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
    >
      <path d="M12 3v9" />
      <path d="M7.05 5.95a8 8 0 1 0 9.9 0" />
    </svg>
  );
}

function FooterActions() {
  return (
    <div className="mt-auto flex items-center justify-between pt-3">
      <span className="text-[9px] text-[var(--preview-muted)]">
        上次同步：今天 22:29
      </span>
      <div className="flex gap-2">
        <ActionButton>
          <ActionIcon name="settings" />
        </ActionButton>
        <ActionButton>
          <ActionIcon name="external" />
        </ActionButton>
        <ActionButton>
          <ActionIcon name="power" />
        </ActionButton>
        <ActionButton primary>立即刷新</ActionButton>
      </div>
    </div>
  );
}

function HorizontalPreview() {
  return (
    <div className="grid h-full grid-cols-[32%_68%] bg-[var(--preview-panel)]">
      <PetPanel />
      <main className="flex min-w-0 flex-col bg-[var(--preview-card)] px-5 pb-4 pt-5">
        <ActivityCard />
        <div className="mt-4">
          <Quota variant="rings" />
        </div>
        <ResetCoupon compact />
        <FooterActions />
      </main>
    </div>
  );
}

function VerticalPreview() {
  return (
    <div className="flex h-full flex-col bg-[var(--preview-panel)]">
      <PetPanel vertical />
      <AccountRow />
      <main className="flex min-h-0 flex-1 flex-col bg-[var(--preview-card)] px-4 pb-4 pt-4">
        <ActivityCard />
        <div className="mt-4">
          <Quota variant="bars" />
        </div>
        <ResetCoupon compact />
        <FooterActions />
      </main>
    </div>
  );
}

export function MenuBarPreview() {
  const [layout, setLayout] = useState<PreviewLayout>("horizontal");
  const wrapperRef = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(1);
  const size = PREVIEW_SIZE[layout];

  useLayoutEffect(() => {
    const wrapper = wrapperRef.current;
    if (!wrapper) return;

    const updateScale = () => {
      setScale(Math.min(1, wrapper.clientWidth / size.width));
    };
    updateScale();
    const observer = new ResizeObserver(updateScale);
    observer.observe(wrapper);
    return () => observer.disconnect();
  }, [size.width]);

  return (
    <div>
      <div
        className="mb-5 flex justify-center"
        role="group"
        aria-label="选择应用预览布局"
      >
        <div className="inline-flex rounded-full border border-border bg-surface/80 p-1 shadow-sm backdrop-blur">
          {(
            [
              ["horizontal", "横向布局"],
              ["vertical", "竖向布局"],
            ] as const
          ).map(([value, label]) => {
            const active = layout === value;
            return (
              <button
                key={value}
                type="button"
                aria-pressed={active}
                onClick={() => setLayout(value)}
                className={`flex min-w-[112px] items-center justify-center gap-2 rounded-full px-4 py-2 text-sm font-medium transition-all ${
                  active
                    ? "bg-foreground text-background shadow-sm"
                    : "text-muted hover:text-foreground"
                }`}
              >
                <LayoutIcon layout={value} />
                {label}
              </button>
            );
          })}
        </div>
      </div>

      <div
        ref={wrapperRef}
        className="relative mx-auto w-full transition-[height] duration-500 ease-out"
        style={{ height: size.height * scale }}
      >
        <div
          className="absolute left-1/2 top-0 overflow-hidden rounded-[26px] border border-[color:var(--preview-frame-border)] bg-[var(--preview-bg)] shadow-[var(--preview-shadow)] transition-[width,height,transform] duration-500 ease-out"
          style={{
            width: size.width,
            height: size.height,
            transform: `translateX(-50%) scale(${scale})`,
            transformOrigin: "top center",
          }}
          aria-hidden="true"
        >
          {layout === "horizontal" ? (
            <HorizontalPreview />
          ) : (
            <VerticalPreview />
          )}
        </div>
      </div>
    </div>
  );
}
