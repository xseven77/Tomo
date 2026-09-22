import type { Metadata } from "next";
import { AccountSwitchingPreview } from "@/components/preview/AccountSwitchingPreview";
import { DesktopPetTaskPreview } from "@/components/preview/DesktopPetTaskPreview";
import { NotchStatusPreview } from "@/components/preview/NotchStatusPreview";

export const metadata: Metadata = {
  title: "多账号陪伴预览 · Tomo",
  description:
    "通过同一只 Pet 切换查看多个 Agent 账号、API 余额和本地任务。",
};

export default function PreviewPage() {
  return (
    <main className="min-h-screen bg-[linear-gradient(145deg,var(--preview-desktop),var(--preview-desktop-end))] px-4 py-10 text-[var(--preview-ink)] sm:px-6">
      <div className="mx-auto max-w-[760px]">
        <div className="mb-8 text-center">
          <div className="text-[10px] font-bold uppercase tracking-[0.16em] text-emerald-600 dark:text-emerald-400">
            Product preview
          </div>
          <h1 className="mt-2 text-3xl font-bold tracking-[-0.045em]">
            一个 Pet，陪着你用过的每个 Agent
          </h1>
          <p className="mx-auto mt-3 max-w-xl text-sm leading-6 text-[var(--preview-muted)]">
            切换查看多个 Agent 账号与 API Key 余额，Pet 同时关注本机所有任务。
          </p>
        </div>
        <AccountSwitchingPreview />
        <NotchStatusPreview />
        <DesktopPetTaskPreview />
      </div>
    </main>
  );
}
