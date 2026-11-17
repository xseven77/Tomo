# 正式服务的本机受控 runtime

1. Agent 描述声明适配器可能支持的动作；每个 runtime 单独声明实际可用范围。ChatGPT 原历史目录保持只读，不能因为另一个 runtime 可控制而继承发送权限。
2. 本机从原登记目录选 opaque sessionId，解析 vendor ID 仅在原生内存；显式选择 executable 并接管会话。启动独立账号 app-server，resume/attach 取得真实 baseline，然后发布 journal/commands 和独立 runtime。手机不能提交 executable、home、vendor ID 或启动进程。
3. 独立 runtime 只列出接管的会话，不自动授予手机 ACL，不映射整个 home 为 workspace。消息追加/中断仍由当前活动回合及实际 command source 检查；空闲新回合不因 grant 自动启动。
4. 停止服务、启动失败、取消或迟到结果必须撤下 read/session/commands 并停止专属进程。进程断线后立即失去控制，待原生刷新清理目录。
5. 验证真实 stdio 子进程到 journal/sync/命令的装配以及生命周期，保留真实 HTTPS/ACL 回归。设置接管入口已实现；后续实现明确的新回合策略、原生业务 RPC 和真实 Agent 闭环；不得以 synthetic agent 冒充真实模型回复。

## 2026-10-04 装配证据

- 正式 `RemoteProductionService` 持有受控 runtime 服务，原生 owner Settings 可选择本机目录中的会话和 executable，明确开启活动回合追加消息；单独登记 runtime 后仍需要独立批准手机 ACL。原目录保持只读。
- 同一账号同一 thread 的接管去重覆盖进行中的启动；停止/取消期间迟到的 launcher 结果会停止私有进程，不发布目录或控制源。
- 19 项 XCTest 与 29 项 Swift Testing 回归通过。受控服务测试启动真实 stdio 合成子进程，经过 resume、baseline、steer、回复事件、sync 和 applied 账本；这只证明装配与生命周期，不证明真实模型任务。
- 单独显式开启 `TOMO_RPC_RESUME_SMOKE_EXECUTABLE` 后，已安装 `codex-cli 0.153.4` 的隔离历史测试通过。使用临时 HOME、合成已完成 rollout，无用户会话、登录或模型请求；验证真实 CLI 恢复、SQLite 索引、HTTP 快照、SSE 连接/释放和停止后的不可访问。
- 原生 Settings 源码通过编译，实际点击交互、真实平台/云授权到 Agent 控制链仍待验收。

## 新回合策略待实现

本机 `codex-cli 0.153.4` 生成的 `TurnStartParams` schema 只有必需的 `threadId`/`input`，没有空闲回合 CAS 前置条件；其 `turnTrigger`、`serviceTierForTurn` 描述明确包含请求转为 steer 的情况。`TurnSteerParams.expectedTurnId` 则要求与当前活动回合一致。不能把本机日志中上一刻的 idle 当作上游原子保证，也不能通过 `thread/read` 后立即 `turn/start` 消除竞态。

下一阶段需为既有线程定义真实独占执行条件，或提供明确的新会话创建路径并验证该执行只由受管 dispatcher 驱动。新路径必须贯通原生入口、目录/不透明 ID、baseline、journal、start 回执与事件、后续 steer/interrupt，并覆盖断线、取消、重复请求及自主执行竞态；不以放宽当前 `permitsFreshStart` 代替实现。
