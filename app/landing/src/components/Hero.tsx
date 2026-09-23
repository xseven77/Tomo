import { GITHUB_RELEASES_URL } from "@/lib/github";
import Image from "next/image";
import { MenuBarPreview } from "./MenuBarPreview";

export function Hero() {
  return (
    <section className="relative overflow-hidden" aria-labelledby="hero-heading">
      <div className="hero-glow absolute inset-0 opacity-70" />
      <div className="grid-bg absolute inset-0 opacity-20" />

      <div className="relative mx-auto max-w-6xl px-4 pb-14 pt-28 sm:px-6 sm:pb-20 sm:pt-32 lg:pb-24 lg:pt-36">
        <div className="mx-auto max-w-5xl text-center">
          <div className="mb-5 inline-flex max-w-full items-center gap-2 rounded-full border border-border bg-surface/80 px-3 py-1 text-xs text-muted backdrop-blur sm:mb-6">
            <span className="h-2 w-2 shrink-0 rounded-full bg-accent animate-pulse-soft" />
            <span className="truncate">macOS 菜单栏 · 任务、Pet、额度</span>
          </div>

          <h1
            id="hero-heading"
            className="text-balance text-[2.35rem] font-semibold leading-[1.08] tracking-[-0.04em] sm:text-[3.55rem] lg:text-[4rem]"
          >
            <span className="inline-block whitespace-nowrap">Codex 在忙什么，</span>
            <wbr />
            <span className="inline-block whitespace-nowrap text-accent">
              抬眼就知道
            </span>
          </h1>

          <p className="mx-auto mt-5 max-w-2xl text-base leading-7 text-muted sm:mt-6 sm:text-lg sm:leading-8">
            任务圆灯与额度文字常驻中性透明胶囊。需要时，悬停即可展开 Pet 与摘要；
            Codex 开始工作后，动态浮窗会主动跟进，直到任务告一段落。
          </p>

          <div className="mt-7 flex flex-col justify-center gap-3 sm:mt-8 sm:flex-row sm:flex-wrap sm:items-center sm:gap-4">
            <a
              href={GITHUB_RELEASES_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center justify-center gap-2 rounded-full bg-foreground px-6 py-3 text-sm font-medium text-background transition-transform hover:scale-[1.02] active:scale-[0.98]"
            >
              下载 Tomo
              <span aria-hidden>↗</span>
            </a>
            <a
              href="https://github.com/xseven77/Tomo"
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center justify-center gap-2 rounded-full border border-border px-6 py-3 text-sm transition-colors hover:bg-foreground/5 active:bg-foreground/10"
            >
              查看源码
            </a>
          </div>

          <div className="mt-8 flex flex-wrap items-center justify-center gap-x-6 gap-y-3 text-sm text-muted sm:mt-10">
            <div className="flex items-center gap-2">
              <Image
                src="/brand/tomo-logo.webp"
                alt="Tomo logo"
                width={18}
                height={18}
                className="shrink-0 rounded-[4px]"
              />
              原生 SwiftUI
            </div>
            <div>OpenAI 官方登录</div>
            <div>任务记录仅在本机读取</div>
          </div>
        </div>

        <div className="relative mx-auto mt-11 max-w-[720px] sm:mt-12">
          <MenuBarPreview />
        </div>
      </div>
    </section>
  );
}
