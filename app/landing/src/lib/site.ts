import { GITHUB_RELEASES_URL, GITHUB_REPO_URL } from "./github";

export const siteConfig = {
  name: "Tomo",
  title: "Tomo — 在 macOS 菜单栏查看 Codex 状态与额度",
  description:
    "Tomo 是一款原生 macOS 菜单栏 App，可查看 Codex 任务状态与额度，并在任务运行时主动展示 Pet 和进度摘要。",
  shortDescription:
    "在 macOS 菜单栏查看 Codex 任务、Pet 和额度；任务运行时，动态浮窗会主动跟进进度。通过 OpenAI 官方页面登录，源码公开可审阅。",
  url: process.env.NEXT_PUBLIC_SITE_URL ?? "https://tomo.qiizo.cn",
  locale: "zh_CN",
  author: "xseven77",
  keywords: [
    "Tomo",
    "Codex",
    "OpenAI Codex",
    "ChatGPT Codex",
    "macOS 菜单栏",
    "Codex 额度",
    "Codex usage",
    "Codex Pet",
    "Codex 任务状态",
    "Codex companion",
    "状态栏工具",
    "Swift",
    "OAuth",
  ],
  github: GITHUB_REPO_URL,
  releases: GITHUB_RELEASES_URL,
} as const;

export function absoluteUrl(path = "/") {
  return new URL(path, siteConfig.url).toString();
}
