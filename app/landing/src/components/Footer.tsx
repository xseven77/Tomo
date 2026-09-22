export function Footer() {
  return (
    <footer className="border-t border-border/70">
      <div className="mx-auto flex max-w-6xl flex-col gap-4 px-4 py-8 text-sm text-muted supports-[padding:max(0px)]:pb-[max(2.5rem,env(safe-area-inset-bottom))] sm:flex-row sm:items-center sm:justify-between sm:px-6 sm:py-10">
        <div>Tomo · 原生 macOS 菜单栏 App</div>
        <div className="flex flex-wrap gap-5">
          <a
            href="https://github.com/xseven77/Tomo"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-foreground"
          >
            GitHub
          </a>
          <a
            href="https://github.com/xseven77/Tomo/releases"
            target="_blank"
            rel="noopener noreferrer"
            className="hover:text-foreground"
          >
            Releases
          </a>
          <a href="#features" className="hover:text-foreground">
            功能
          </a>
        </div>
      </div>
    </footer>
  );
}
