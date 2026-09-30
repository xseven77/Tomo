# Gateway 的 Responses 工具兼容规则

实现位置：`crates/gateway-server/src/responses_bridge.rs`。原生 Codex 路由保留原始 Responses 请求和事件；下表说明转换到 Chat Completions 上游时的行为。

## 工具声明与调用

| 类型 | 转换行为 |
| --- | --- |
| `function` | 转换为 Chat function；保留参数、调用 ID 和返回结果。 |
| `namespace` | 展开子工具，用稳定别名避免同名冲突；返回时恢复名称和命名空间。 |
| `custom` | 用字符串 `input` 参数承载自由文本，返回 `custom_tool_call`。语法约束写入工具描述，Chat 上游不提供原生语法强制约束。 |
| 客户端 `tool_search` | 转换为客户端函数；返回 `tool_search_call`，继续接收 `tool_search_output` 和新增工具。 |
| 服务端 `tool_search` | 将已声明工具直接提供给模型，不额外调用托管搜索。 |
| `additional_tools`、搜索返回的工具定义 | 合并进工具目录；加载后的定义替换同一工具的占位定义。 |
| `local_shell` | 保留结构化 `action`，返回客户端执行的 `local_shell_call`。 |
| `shell` 且环境为 `local` | 保留 `commands` 等 action 字段，返回客户端执行的 `shell_call`。 |
| `apply_patch` | 保留结构化 `operation`，返回客户端执行的 `apply_patch_call`。与名为 apply_patch 的 custom/function 工具分别处理。 |
| `web_search`、`web_search_preview`、`file_search`、`code_interpreter`、`image_generation`、远程 `mcp`、托管 shell | Chat 转换路径不提供这些托管服务。省略可选声明，并告知模型能力限制；普通对话和其他客户端工具继续工作。 |
| `computer`、`computer_use_preview` 和其他尚无转换器的类型 | 同样作为不可用的可选能力处理；不会创建没有执行器的假函数。原生路由仍原样透传。 |

Gateway 不执行本地 shell、补丁或客户端工具；执行、审批和沙箱继续由客户端负责。工具返回事件需要完整的名称和调用 ID，工具参数在接收完整调用后发送，文本仍实时流式输出。

## 工具选择和历史

- `auto`、`none` 允许在没有可用工具时正常对话。
- `required` 必须有实际可调用的工具；强制选择不可用工具会返回明确的能力错误，不能伪造成功。
- `allowed_tools` 先筛选工具，再转换选择模式；命名空间限制不会丢失。
- 历史 function/custom/客户端工具调用及结果保留对应关系；历史托管工具记录作为低权限上下文保留，不重新执行，也不作为审批指令。
- 加密 compaction、`item_reference`、`previous_response_id` 和服务端 conversation 引用不能在 Chat 转换路径跨模型解析，需要原生路由或完整明文历史。
- 省略可选工具声明只解决协议兼容，不表示所选模型获得了该托管能力。需要联网搜索时，应使用提供此能力的原生路由，或客户端实际提供的搜索工具。

## 验证范围

已添加可选工具集合、混合 Codex 工具、工具选择限制、分段工具名、延迟加载定义、历史托管记录和本地结构化工具往返的回归用例。本次按用户要求仅编译检查和打包，未运行测试套件或真实模型调用；客户端功能验证由用户完成。

协议参考：[Function calling](https://developers.openai.com/api/docs/guides/function-calling)、[Tool search](https://developers.openai.com/api/docs/guides/tools-tool-search)、[Shell](https://developers.openai.com/api/docs/guides/tools-shell)、[Local shell](https://developers.openai.com/api/docs/guides/tools-local-shell)、[Apply patch](https://developers.openai.com/api/docs/guides/tools-apply-patch)。
