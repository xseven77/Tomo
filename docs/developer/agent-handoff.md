# Agent 任务交接（tomo-handoff）

任何能写文件或运行 shell 的 Agent，都可以用 `skills/tomo-handoff` 把当前任务交接给 Tomo，在手机或网页的「会话 → 任务交接」里查看。

- **技能**：`skills/tomo-handoff/SKILL.md`（通用 Agent Skills 格式）和 `scripts/tomo-handoff`（POSIX sh：`submit`、`list`、`show`、`path`）。
- **安装**：把技能目录链接到各 Agent 的技能目录，例如 `~/.claude/skills/tomo-handoff`、`~/.codex/skills/tomo-handoff`。
- **收件箱**：`~/Library/Application Support/Tomo/Handoffs/`（可用 `TOMO_HANDOFF_DIR` 覆盖）。每份交接是带头信息（`tomo-handoff: 1`、`title`、`agent`、`workspace`、`status`）的 Markdown 文件，上限 256 KB。以点开头的文件、符号链接、格式不对的文件都会被忽略。
- **接口**：`GET /api/v1/remote/handoffs`、`GET /api/v1/remote/handoffs/<id>`，只读，需要带会话读取权限的授权。工作区只返回文件夹名，不返回完整路径。
- **不做的事**：不接管其他程序正在使用的会话；交接内容只是信息，Tomo 不执行其中任何指令。
