"use client";

import { GITHUB_RELEASES_URL } from "@/lib/github";
import Image from "next/image";
import Link from "next/link";
import { useEffect, useState } from "react";
import { ThemeToggle } from "./ThemeToggle";

const nav = [
  { href: "#features", label: "功能" },
  { href: "#how-it-works", label: "怎么工作" },
  { href: "#github", label: "源码" },
  { href: "#releases", label: "版本" },
];

function MenuIcon({ open }: { open: boolean }) {
  return (
    <svg
      viewBox="0 0 24 24"
      className="size-5"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      aria-hidden
    >
      {open ? (
        <path d="M6 6l12 12M18 6L6 18" strokeLinecap="round" />
      ) : (
        <>
          <path d="M4 7h16M4 12h16M4 17h16" strokeLinecap="round" />
        </>
      )}
    </svg>
  );
}

export function Header() {
  const [menuOpen, setMenuOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    document.body.style.overflow = menuOpen ? "hidden" : "";
    return () => {
      document.body.style.overflow = "";
    };
  }, [menuOpen]);

  useEffect(() => {
    const updateScrolled = () => setScrolled(window.scrollY > 24);
    updateScrolled();
    window.addEventListener("scroll", updateScrolled, { passive: true });
    return () => window.removeEventListener("scroll", updateScrolled);
  }, []);

  const closeMenu = () => setMenuOpen(false);
  const elevated = scrolled || menuOpen;

  return (
    <header className="fixed inset-x-0 top-0 z-50 supports-[padding:max(0px)]:pt-[env(safe-area-inset-top)]">
      <div className="mx-auto max-w-[1180px] px-3 pt-2.5 sm:px-5 sm:pt-3">
        <div
          className={[
            "flex h-14 items-center justify-between gap-3 rounded-[18px] px-3 sm:h-[58px] sm:px-4",
            "transition-[background-color,border-color,box-shadow,backdrop-filter] duration-300 ease-out",
            elevated
              ? "border border-black/[0.07] bg-background/78 shadow-[0_12px_36px_rgba(15,23,42,0.09),0_1px_0_rgba(255,255,255,0.5)_inset] backdrop-blur-2xl dark:border-white/[0.1] dark:shadow-[0_14px_42px_rgba(0,0,0,0.38)]"
              : "border border-transparent bg-transparent shadow-none",
          ].join(" ")}
        >
          <Link
            href="/"
            className="group flex min-w-0 items-center gap-2.5 rounded-full pr-2 sm:gap-3"
          >
            <span className="relative grid size-9 shrink-0 place-items-center rounded-[11px] bg-background/55 shadow-[0_1px_0_rgba(255,255,255,0.7)_inset] ring-1 ring-black/[0.05] backdrop-blur-md transition-transform duration-200 group-hover:scale-[1.04] dark:ring-white/[0.09]">
              <Image
                src="/brand/codexling-logo.webp"
                alt="Tomo"
                width={29}
                height={29}
                className="rounded-[7px]"
              />
            </span>
            <span className="truncate text-sm font-semibold tracking-[-0.015em]">
              Tomo
            </span>
          </Link>

          <nav
            className="hidden items-center rounded-full bg-background/25 p-1 backdrop-blur-sm md:flex"
            aria-label="主导航"
          >
            {nav.map((item) => (
              <a
                key={item.href}
                href={item.href}
                className="rounded-full px-3.5 py-2 text-[13px] font-medium text-muted transition-[color,background-color] hover:bg-background/65 hover:text-foreground"
              >
                {item.label}
              </a>
            ))}
          </nav>

          <div className="flex shrink-0 items-center gap-1.5 sm:gap-2">
            <ThemeToggle />
            <a
              href="https://github.com/xseven77/Tomo"
              target="_blank"
              rel="noopener noreferrer"
              className="hidden rounded-full px-3.5 py-2 text-[13px] font-medium text-muted transition-colors hover:bg-background/60 hover:text-foreground sm:inline-flex"
            >
              GitHub
            </a>
            <a
              href={GITHUB_RELEASES_URL}
              target="_blank"
              rel="noopener noreferrer"
              className="hidden rounded-full bg-foreground px-4 py-2 text-[13px] font-medium text-background shadow-sm transition-[transform,opacity] hover:scale-[1.02] hover:opacity-90 active:scale-[0.98] sm:inline-flex"
            >
              下载
            </a>
            <button
              type="button"
              className="inline-flex size-9 items-center justify-center rounded-[11px] bg-background/45 text-foreground ring-1 ring-black/[0.06] backdrop-blur-md transition-colors hover:bg-background/75 dark:ring-white/[0.1] md:hidden"
              aria-expanded={menuOpen}
              aria-controls="mobile-nav"
              aria-label={menuOpen ? "关闭菜单" : "打开菜单"}
              onClick={() => setMenuOpen((v) => !v)}
            >
              <MenuIcon open={menuOpen} />
            </button>
          </div>
        </div>

        {menuOpen ? (
          <div
            id="mobile-nav"
            className="mt-2 overflow-hidden rounded-[18px] border border-black/[0.07] bg-background/92 p-2 shadow-[0_18px_50px_rgba(15,23,42,0.14)] backdrop-blur-2xl dark:border-white/[0.1] dark:shadow-[0_22px_60px_rgba(0,0,0,0.48)] md:hidden"
          >
            <nav className="flex flex-col" aria-label="移动端导航">
              {nav.map((item) => (
                <a
                  key={item.href}
                  href={item.href}
                  className="rounded-[12px] px-3.5 py-3 text-[15px] font-medium text-foreground transition-colors active:bg-foreground/5"
                  onClick={closeMenu}
                >
                  {item.label}
                </a>
              ))}
              <div className="mt-1 grid grid-cols-2 gap-2 border-t border-border/70 pt-2">
                <a
                  href="https://github.com/xseven77/Tomo"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="rounded-[12px] border border-border px-4 py-3 text-center text-sm font-medium transition-colors active:bg-foreground/5"
                  onClick={closeMenu}
                >
                  GitHub
                </a>
                <a
                  href={GITHUB_RELEASES_URL}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="rounded-[12px] bg-foreground px-4 py-3 text-center text-sm font-medium text-background"
                  onClick={closeMenu}
                >
                  前往下载
                </a>
              </div>
            </nav>
          </div>
        ) : null}
      </div>
    </header>
  );
}
