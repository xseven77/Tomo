const steps = [
  {
    step: "01",
    title: "在 OpenAI 完成授权",
    description:
      "点击登录后会打开 OpenAI 官方授权页，完成后自动回到 Tomo。",
  },
  {
    step: "02",
    title: "读取额度",
    description:
      "Tomo 会读取账号返回的额度窗口；重置券、订阅周期能取到就一起显示，取不到也不影响额度。",
  },
  {
    step: "03",
    title: "读取本地任务",
    description:
      "只读查看本机任务记录，用来显示任务名、工作区、分支、模型和当前状态。",
  },
  {
    step: "04",
    title: "在恰当的时候呈现",
    description:
      "任务圆灯和额度文字常驻中性透明胶囊；任务运行时浮窗主动展开。",
  },
];

export function HowItWorks() {
  return (
    <section
      id="how-it-works"
      className="border-y border-border/70 bg-surface/50"
      aria-labelledby="how-heading"
    >
      <div className="mx-auto max-w-6xl px-4 py-16 sm:px-6 sm:py-24">
        <div className="max-w-2xl">
          <p className="text-sm font-medium tracking-[0.16em] text-accent">
            数据从哪里来
          </p>
          <h2
            id="how-heading"
            className="mt-3 text-2xl font-semibold tracking-tight sm:text-4xl"
          >
            额度从 OpenAI 获取，任务从本机读取
          </h2>
        </div>

        <div className="mt-10 grid gap-4 sm:mt-12 sm:grid-cols-2 sm:gap-6 lg:grid-cols-4">
          {steps.map((item) => (
            <div
              key={item.step}
              className="relative rounded-2xl border border-border p-5 sm:rounded-3xl sm:p-6"
            >
              <div className="font-mono text-sm text-accent">{item.step}</div>
              <h3 className="mt-4 text-lg font-medium">{item.title}</h3>
              <p className="mt-2 text-sm leading-7 text-muted">{item.description}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
