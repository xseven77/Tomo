"use client";

import { ChevronLeft, ChevronRight, ExternalLink } from "lucide-react";
import { useState } from "react";
import type { GitHubRelease } from "@/lib/github";
import { formatBytes, formatDate, GITHUB_RELEASES_URL } from "@/lib/github";

const PAGE_SIZE = 5;

function summarizeRelease(
  body: string,
  releaseName: string,
  tagName: string,
): string {
  const ignored = new Set([
    releaseName.trim().toLowerCase(),
    tagName.trim().toLowerCase(),
  ]);
  const summary = body
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/[`*_>#]/g, "")
    .split("\n")
    .map((line) => line.replace(/^[-+]\s*/, "").trim())
    .find((line) => {
      const normalized = line.toLowerCase();
      return (
        line.length > 0 &&
        !ignored.has(normalized) &&
        !/^(downloads?|assets?|下载|安装包)$/i.test(line) &&
        !/^tomo\s+v?\d[\w.-]*$/i.test(line) &&
        !/\.(dmg|zip)\b/i.test(line)
      );
    });

  return summary
    ? summary.slice(0, 180)
    : "提供 DMG 与 ZIP 安装包，可在下方直接选择格式下载。";
}

export function GitHubReleasesSection({ releases }: { releases: GitHubRelease[] }) {
  const [page, setPage] = useState(1);
  const latest = releases[0];
  const totalPages = Math.max(1, Math.ceil(releases.length / PAGE_SIZE));
  const currentPage = Math.min(page, totalPages);
  const start = (currentPage - 1) * PAGE_SIZE;
  const visibleReleases = releases.slice(start, start + PAGE_SIZE);

  return (
    <section id="releases" className="border-t border-border/70 bg-surface/40">
      <div className="mx-auto max-w-6xl px-4 py-16 sm:px-6 sm:py-24">
        <div className="mb-8 flex flex-col gap-5 sm:mb-10 sm:flex-row sm:flex-wrap sm:items-end sm:justify-between sm:gap-6">
          <div className="max-w-2xl">
            <p className="text-sm font-medium tracking-[0.16em] text-accent">
              版本下载
            </p>
            <h2 className="mt-3 text-2xl font-semibold tracking-tight sm:text-4xl">
              下载 Tomo
            </h2>
            <p className="mt-4 text-base text-muted sm:text-lg">
              建议优先下载最新的 DMG。需要 ZIP 或历史版本时，可以在下方翻页查找。
            </p>
          </div>

          <a
            href={GITHUB_RELEASES_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex w-full items-center justify-center gap-2 rounded-full bg-accent px-5 py-3 text-sm font-medium text-black transition-transform hover:scale-[1.02] active:scale-[0.98] sm:w-auto"
          >
            前往 GitHub 查看全部版本
            <ExternalLink aria-hidden="true" size={16} />
          </a>
        </div>

        <div className="overflow-hidden rounded-2xl border border-[var(--github-border)] bg-[var(--github-bg)] shadow-[0_30px_80px_rgba(0,0,0,0.35)] sm:rounded-[28px]">
          <div className="flex items-center gap-2 border-b border-[var(--github-border)] bg-[#010409] px-4 py-3">
            <span className="h-3 w-3 rounded-full bg-[#ff5f57]" />
            <span className="h-3 w-3 rounded-full bg-[#febc2e]" />
            <span className="h-3 w-3 rounded-full bg-[#28c840]" />
            <span className="ml-3 truncate text-xs text-[var(--github-muted)]">
              github.com/xseven77/Tomo/releases
            </span>
          </div>

          <div className="border-b border-[var(--github-border)] px-5 py-4">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <h3 className="text-lg font-semibold text-white">Releases</h3>
              <span className="text-sm text-[var(--github-muted)]">
                共 {releases.length} 个版本 · {currentPage}/{totalPages} 页
              </span>
            </div>
          </div>

          <div
            className="divide-y divide-[var(--github-border)]"
            aria-live="polite"
            aria-label={`Release 列表，第 ${currentPage} 页`}
          >
            {visibleReleases.length > 0 ? (
              visibleReleases.map((release) => {
                const downloadAssets = release.assets.filter((asset) =>
                  /\.(dmg|zip)$/i.test(asset.name),
                );

                return (
                  <article
                    key={release.tagName}
                    className="grid gap-3 px-4 py-5 sm:gap-4 sm:px-5 sm:py-6 lg:grid-cols-[180px_1fr]"
                  >
                    <div>
                      <div className="text-sm text-[var(--github-muted)]">
                        {formatDate(release.publishedAt)}
                      </div>
                      <div className="mt-2 flex items-center gap-2">
                        <span className="font-mono text-sm text-[#58a6ff]">
                          {release.tagName}
                        </span>
                        {release.isLatest && (
                          <span className="rounded-full border border-[#238636] bg-[#238636]/20 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-[#3fb950]">
                            Latest
                          </span>
                        )}
                      </div>
                    </div>

                    <div>
                      <h4 className="text-lg font-semibold text-white sm:text-xl">
                        {release.name}
                      </h4>
                      <p className="mt-2 text-sm leading-6 text-[var(--github-muted)]">
                        {summarizeRelease(
                          release.body,
                          release.name,
                          release.tagName,
                        )}
                      </p>
                      {downloadAssets.length > 0 && (
                        <div className="mt-3 flex flex-wrap gap-2">
                          {downloadAssets.map((asset) => (
                            <a
                              key={asset.name}
                              href={asset.url}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="rounded-md border border-[var(--github-border)] bg-white/[0.03] px-2.5 py-1 text-xs text-[var(--github-text)] transition-colors hover:bg-white/[0.07]"
                            >
                              {asset.name.toLowerCase().endsWith(".dmg") ? "DMG" : "ZIP"}
                              {" · "}
                              {formatBytes(asset.size)}
                            </a>
                          ))}
                        </div>
                      )}
                    </div>
                  </article>
                );
              })
            ) : (
              <div className="px-5 py-10 text-center text-sm text-[var(--github-muted)]">
                暂时无法读取 Release 列表，请前往 GitHub 查看。
              </div>
            )}
          </div>

          <div className="border-t border-[var(--github-border)] bg-[#161b22] px-4 py-4 sm:px-5 sm:py-5">
            <div className="flex flex-col gap-4 sm:flex-row sm:flex-wrap sm:items-center sm:justify-between">
              <div className="text-sm text-[var(--github-muted)]">
                {latest
                  ? `最新版本 ${latest.tagName} · 共 ${releases.length} 个版本`
                  : "前往 GitHub 查看所有版本"}
              </div>

              <div className="flex flex-wrap items-center gap-2">
                {releases.length > PAGE_SIZE && (
                  <nav className="flex items-center gap-1" aria-label="Release 分页">
                    <button
                      type="button"
                      onClick={() => setPage((value) => Math.max(1, value - 1))}
                      disabled={currentPage === 1}
                      className="inline-flex h-9 items-center gap-1 rounded-lg border border-[var(--github-border)] px-2.5 text-xs text-[var(--github-text)] transition-colors hover:bg-white/5 disabled:cursor-not-allowed disabled:opacity-35"
                      aria-label="上一页"
                    >
                      <ChevronLeft aria-hidden="true" size={15} />
                      <span className="hidden sm:inline">上一页</span>
                    </button>

                    {Array.from({ length: totalPages }, (_, index) => index + 1).map(
                      (pageNumber) => (
                        <button
                          key={pageNumber}
                          type="button"
                          onClick={() => setPage(pageNumber)}
                          aria-current={currentPage === pageNumber ? "page" : undefined}
                          aria-label={`第 ${pageNumber} 页`}
                          className={`h-9 min-w-9 rounded-lg border px-2 text-xs transition-colors ${
                            currentPage === pageNumber
                              ? "border-[var(--github-green)] bg-[var(--github-green)] text-white"
                              : "border-[var(--github-border)] text-[var(--github-text)] hover:bg-white/5"
                          }`}
                        >
                          {pageNumber}
                        </button>
                      ),
                    )}

                    <button
                      type="button"
                      onClick={() =>
                        setPage((value) => Math.min(totalPages, value + 1))
                      }
                      disabled={currentPage === totalPages}
                      className="inline-flex h-9 items-center gap-1 rounded-lg border border-[var(--github-border)] px-2.5 text-xs text-[var(--github-text)] transition-colors hover:bg-white/5 disabled:cursor-not-allowed disabled:opacity-35"
                      aria-label="下一页"
                    >
                      <span className="hidden sm:inline">下一页</span>
                      <ChevronRight aria-hidden="true" size={15} />
                    </button>
                  </nav>
                )}

                <a
                  href={latest?.url ?? GITHUB_RELEASES_URL}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex h-9 items-center justify-center rounded-lg bg-[var(--github-green)] px-4 text-sm font-medium text-white transition-opacity hover:opacity-90"
                >
                  查看最新版本
                </a>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
