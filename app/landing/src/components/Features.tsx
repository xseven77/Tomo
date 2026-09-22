import {
  Activity,
  Gauge,
  MonitorCog,
  PanelTop,
  PawPrint,
  RefreshCw,
  ShieldCheck,
} from "lucide-react";
import type { LucideIcon } from "lucide-react";

type Feature = {
  title: string;
  description: string;
  icon: LucideIcon;
};

const features: Feature[] = [
  {
    title: "状态随时看",
    description:
      "圆点独立显示任务状态，文字直接给出当前额度窗口；固定中性底不会跟随状态或壁纸翻色。",
    icon: Activity,
  },
  {
    title: "会主动出现的任务浮窗",
    description:
      "空闲时悬停即可快速查看；Codex 开始工作后，浮窗会自动展开并持续呈现 Pet、任务摘要和活跃任务数。",
    icon: PanelTop,
  },
  {
    title: "并行任务集中查看",
    description:
      "逐个查看任务状态、工作区、分支、模型和最近摘要，也会记录今天一起工作的时长。",
    icon: MonitorCog,
  },
  {
    title: "额度和到期时间",
    description:
      "各个额度窗口、重置时间和重置券都在一起；能取到时也会显示当前订阅周期。",
    icon: Gauge,
  },
  {
    title: "Pet 跟着任务动",
    description:
      "内置 Pet 和自定义 Pet 都能用。切换后会同步到 Codex，需要重启时 App 会提醒你。",
    icon: PawPrint,
  },
  {
    title: "任务数据留在本机",
    description:
      "登录在 OpenAI 官方页面完成；任务记录只在本机读取，不会由 Tomo 另行上传。",
    icon: ShieldCheck,
  },
  {
    title: "常用设置都在 App 里",
    description:
      "主题、额度刷新、状态栏 Wave、窗口置顶和版本更新都能在 App 中完成。",
    icon: RefreshCw,
  },
];

export function Features() {
  return (
    <section
      id="features"
      className="mx-auto max-w-6xl px-4 py-16 sm:px-6 sm:py-24"
      aria-labelledby="features-heading"
    >
      <div className="max-w-2xl">
        <p className="text-sm font-medium tracking-[0.16em] text-accent">
          主要功能
        </p>
        <h2
          id="features-heading"
          className="mt-3 text-2xl font-semibold tracking-tight sm:text-4xl"
        >
          不只看额度，也看 Codex 在做什么
        </h2>
        <p className="mt-4 text-base text-muted sm:text-lg">
          菜单栏随时看状态，动态浮窗在任务开始时主动跟进，点开完整窗口查看任务、Pet 和用量。
        </p>
      </div>

      <div className="mt-10 grid gap-4 sm:mt-12 sm:grid-cols-2 sm:gap-5 lg:grid-cols-12">
        {features.map((feature, index) => {
          const Icon = feature.icon;

          return (
            <article
              key={feature.title}
              className={[
                "glass group min-h-[210px] overflow-hidden rounded-2xl p-5",
                "bg-gradient-to-br from-surface/70 to-card/30",
                "transition-[transform,border-color,box-shadow] duration-300",
                "sm:rounded-3xl sm:p-6 sm:hover:-translate-y-1 sm:hover:border-accent/25 sm:hover:shadow-[0_18px_50px_rgba(0,0,0,0.12)]",
                index < 3 ? "lg:col-span-4" : "lg:col-span-3",
              ].join(" ")}
            >
              <div className="mb-7 inline-flex h-11 w-11 items-center justify-center rounded-2xl bg-accent-soft text-accent ring-1 ring-accent/10">
                <Icon aria-hidden="true" size={21} strokeWidth={1.8} />
              </div>
              <h3 className="text-lg font-medium">{feature.title}</h3>
              <p className="mt-2 text-sm leading-7 text-muted">{feature.description}</p>
            </article>
          );
        })}
      </div>
    </section>
  );
}
