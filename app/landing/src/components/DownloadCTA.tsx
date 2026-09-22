import { GITHUB_RELEASES_URL } from "@/lib/github";

export function DownloadCTA() {
  return (
    <section className="mx-auto max-w-6xl px-4 py-16 sm:px-6 sm:py-24">
      <div className="relative overflow-hidden rounded-2xl border border-border bg-gradient-to-br from-[#111] via-[#171717] to-[#0a0a0a] px-5 py-10 text-white sm:rounded-[32px] sm:px-12 sm:py-14">
        <div className="hero-glow absolute inset-0 opacity-70" />
        <div className="relative max-w-2xl">
          <p className="text-sm tracking-[0.16em] text-accent">立即下载</p>
          <h2 className="mt-3 text-2xl font-semibold tracking-tight sm:text-4xl">
            把 Tomo 放进菜单栏
          </h2>
          <p className="mt-4 text-sm leading-7 text-white/70 sm:text-base">
            支持 macOS 14 及以上版本。下载 DMG 后拖进“应用程序”文件夹即可；
            后续可以直接在 Tomo 里检查更新。当前版本尚未经过 Apple 公证，
            首次打开时可能需要在“隐私与安全性”中手动允许。
          </p>
          <div className="mt-7 flex flex-col gap-3 sm:mt-8 sm:flex-row sm:flex-wrap sm:gap-4">
            <a
              href={GITHUB_RELEASES_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center justify-center rounded-full bg-white px-6 py-3 text-sm font-medium text-black"
            >
              下载最新版本
            </a>
            <a
              href="https://github.com/xseven77/Tomo/blob/main/README.md"
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center justify-center rounded-full border border-white/20 px-6 py-3 text-sm text-white/90"
            >
              阅读使用手册
            </a>
          </div>
        </div>
      </div>
    </section>
  );
}
