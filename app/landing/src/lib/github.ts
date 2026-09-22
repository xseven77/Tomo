const REPO = "xseven77/Tomo";
const GITHUB_API = "https://api.github.com";

export const GITHUB_REPO_URL = "https://github.com/xseven77/Tomo";
export const GITHUB_RELEASES_URL = `${GITHUB_REPO_URL}/releases`;

export type GitHubRepo = {
  owner: string;
  name: string;
  fullName: string;
  description: string;
  stars: number;
  forks: number;
  language: string;
  updatedAt: string;
  defaultBranch: string;
  url: string;
};

export type ReleaseAsset = {
  name: string;
  size: number;
  downloadCount: number;
  url: string;
};

export type GitHubRelease = {
  tagName: string;
  name: string;
  publishedAt: string;
  body: string;
  isLatest: boolean;
  assets: ReleaseAsset[];
  url: string;
};

const FALLBACK_REPO: GitHubRepo = {
  owner: "xseven77",
  name: "Tomo",
  fullName: "xseven77/Tomo",
  description:
    "A native macOS menu bar app for Codex tasks, Pets, and usage.",
  stars: 0,
  forks: 0,
  language: "Swift",
  updatedAt: "2026-07-09T08:56:06Z",
  defaultBranch: "main",
  url: "https://github.com/xseven77/Tomo",
};

const FALLBACK_RELEASES: GitHubRelease[] = [];

async function fetchJson<T>(url: string): Promise<T | null> {
  try {
    const headers: HeadersInit = {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
    };

    if (process.env.GITHUB_TOKEN) {
      headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
    }

    const response = await fetch(url, {
      headers,
      next: { revalidate: 300 },
    });

    if (!response.ok) return null;
    return (await response.json()) as T;
  } catch {
    return null;
  }
}

export async function getRepo(): Promise<GitHubRepo> {
  type ApiRepo = {
    full_name: string;
    description: string | null;
    stargazers_count: number;
    forks_count: number;
    language: string | null;
    updated_at: string;
    default_branch: string;
    html_url: string;
  };

  const data = await fetchJson<ApiRepo>(`${GITHUB_API}/repos/${REPO}`);
  if (!data) return FALLBACK_REPO;

  const [owner, name] = data.full_name.split("/");

  return {
    owner,
    name,
    fullName: data.full_name,
    description:
      data.description ??
      "A native macOS menu bar app for Codex tasks, Pets, and usage.",
    stars: data.stargazers_count,
    forks: data.forks_count,
    language: data.language ?? "Swift",
    updatedAt: data.updated_at,
    defaultBranch: data.default_branch,
    url: data.html_url,
  };
}

export async function getReleases(): Promise<GitHubRelease[]> {
  type ApiAsset = {
    name: string;
    size: number;
    download_count: number;
    browser_download_url: string;
  };

  type ApiRelease = {
    tag_name: string;
    name: string;
    published_at: string;
    body: string | null;
    html_url: string;
    assets: ApiAsset[];
  };

  const data = await fetchJson<ApiRelease[]>(
    `${GITHUB_API}/repos/${REPO}/releases?per_page=100`,
  );
  if (!data?.length) return FALLBACK_RELEASES;

  return data.map((release, index) => ({
    tagName: release.tag_name,
    name: release.name,
    publishedAt: release.published_at,
    body: release.body ?? "",
    isLatest: index === 0,
    url: release.html_url,
    assets: release.assets.map((asset) => ({
      name: asset.name,
      size: asset.size,
      downloadCount: asset.download_count,
      url: asset.browser_download_url,
    })),
  }));
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function formatDate(iso: string): string {
  return new Intl.DateTimeFormat("zh-CN", {
    year: "numeric",
    month: "short",
    day: "numeric",
  }).format(new Date(iso));
}

export function formatRelative(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const days = Math.floor(diff / (1000 * 60 * 60 * 24));
  if (days <= 0) return "今天";
  if (days === 1) return "昨天";
  if (days < 30) return `${days} 天前`;
  return formatDate(iso);
}
