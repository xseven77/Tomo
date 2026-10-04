# Tomo 桌面端开放 API

状态：next 工作区实现核验版，2026-10-03。核验对象：Tomo `MobileSyncServer`、RemoteRead/Session/Operation 服务和 TomoGo `ApiService`、Agent 池、主题、RemoteClient。本文描述当前实现，不等于全部功能已经正式发布。

这是一套供用户开发自己应用的通用 HTTP API。Web / PWA、原生 iOS / Android 应用、其他桌面程序、CLI、脚本和服务端程序都可以接入，不需要安装为 Tomo Web 插件。

正式路由统一为 `/api/v1/`。旧 `/mobile/` 路由全部删除，不提供兼容或重定向；访问返回 410 / api_removed。所有使用旧路由的 Web Mobile 版本标记为失效，必须升级。v1 是 API 契约版本，与桌面版本和文档版本独立。

## 开发自己的应用

应用的基本配置是桌面服务 Base URL 和配对 Token。使用 HTTP 请求读取状态，使用 SSE 订阅变化；应用可以独立运行、独立发布，也可以部署在自己的服务器。桌面端承担数据源与代理角色，不要求第三方应用使用 React 或遵循插件包格式。

可开发任务看板、状态栏工具、工作时长展示、手机通知应用或自动化脚本。当前常规配对接口提供状态读取与代理能力；独立会话接口提供目录、历史、同步与事件流，控制路由需本机显式安装操作服务，详见会话章节。Web 浏览器需要考虑 CORS、混合内容和 EventSource 认证方式；原生或服务端客户端可使用 Authorization 请求头读取 SSE，CORS 不适用于这些客户端。

Agent 多服务池的组织方式由应用决定；使用多个桌面服务时应分别保存地址、名称和 Token。供应商数据来自哪台桌面也是应用需要明确的配置，不能因为切换任务来源就隐式替换供应商账号。

本文包含基线之后工作区中的 API 路由迁移与调用来源更新，尚未发布正式版本。

## 1. 服务与接入方式

桌面端通过 `MobileSyncServer` 提供 HTTP 服务，默认端口 `58350`，可在桌面设置中修改。当前服务生命周期依附 Mobile 同步设置；关闭服务、退出桌面应用、Mac 休眠或网络中断都会影响访问。

| 场景 | Base URL 示例 |
| --- | --- |
| 本机应用开发 | `http://127.0.0.1:58350` |
| 局域网访问 | `http://192.168.10.11:58350` |
| 反向代理后的公网服务 | `https://desktop.example.com` |

Base URL 必须使用调用者能访问的入口。公网 HTTPS 入口通常使用 443，不能因为桌面监听 58350 就在公网域名后面加 `:58350`。HTTPS 页面直接访问 HTTP 局域网服务还可能受到浏览器混合内容、私有网络访问策略限制；可使用后文的 Agent SSE 转发，由桌面机器访问目标服务。

原生服务提供 HTTP，公网 TLS 由外层网关处理。文档中的 Base URL 示例不代表已经完成对应部署。

## 2. 认证与响应约定

除 `/api/v1/remote/` 外，所有 `/api/v1/` 路由使用当前桌面服务的配对 Token，支持两种形式：

```http
Authorization: Bearer YOUR_DESKTOP_TOKEN
```

或查询参数 `?token=YOUR_DESKTOP_TOKEN`。普通 fetch 推荐请求头；原生浏览器 `EventSource` 无法设置自定义 Authorization 请求头，可使用查询参数。参数应通过 `URL` / `URLSearchParams` 编码。

Token 来自桌面配对设置，不是供应商 OAuth Token / API Key。当前 Token 没有按应用或接口划分权限：同一个 Token 可以访问快照、代理和凭证导出。只读任务应用不应请求 `/api/v1/credentials`。

认证失败返回 `401` 和 `{"error":"unauthorized"}`。`/health`、静态插件文件、OPTIONS 不需要认证。当前响应允许跨域访问，预检允许 GET、POST、OPTIONS；允许的请求头显式包括 Authorization、Content-Type、Accept、X-Tomo-App-Name、X-Target-Authorization、ChatGPT-Account-Id；这不代替 Token 认证，也不意味着供应商官方接口允许浏览器跨域。

接口错误格式尚未统一，客户端必须先检查 HTTP 状态，再按 Content-Type 或文本处理，不能假设所有错误都是 JSON。未支持的路由或方法通常返回 `404`，不是统一的 `405`。

JSON 的可选字段可能直接缺省。客户端应接受缺省字段、未知字段和未知状态，不能把所有缺失额度都当成零。Swift Date 编码字段使用 ISO 8601；已有业务字符串日期并不全部遵循同一种格式。

查询参数中的 Token 可能出现在请求日志或复制的链接中；示例和文档搜索索引不得包含真实 Token。重置 Token 后需要更新客户端配置；不要假设已建立的 SSE 会立即被撤销。

### 可选调用来源

可传请求头 `X-Tomo-App-Name: My Application`，不传不影响调用。TomoGo 普通 fetch 默认传 `Tomo Go`，部分图片和发现入口使用其各自来源标签。这是调用者自报的统计标签，不是可信身份，不参与认证。

浏览器原生 EventSource 和图片请求无法设置自定义请求头，可以传可选查询参数 `app_name`；请求头优先。桌面清除控制字符、去掉首尾空白、限制 128 个字符，空值视为未传。代理及 SSE 中转将来源以请求头转发。

认证通过后桌面 `onAPIRequest` 回调暴露 method、规范 path 和可选 appName，为后续统计预留；不包含 query、Token 或请求体。当前未实现日志持久化或统计报表。来源应传稳定应用名称，不含个人信息。

## 3. 接口总览

| 方法 | 路径 | 认证 | 用途 |
| --- | --- | --- | --- |
| GET | `/health` | 无 | HTTP 服务存活检查 |
| GET | `/api/v1/snapshot` | 桌面 Token | 当前状态完整快照 |
| GET | `/api/v1/events` | 桌面 Token | 当前服务的 SSE 状态订阅 |
| GET | `/api/v1/agents/events` | 桌面 Token + 目标 Token | 转发其他桌面服务的 Agent SSE |
| GET | `/api/v1/agents/snapshot` | 桌面 Token + 目标 Token | Agent 专用快照中转，仅用于手动检查和 SSE 降级 |
| GET | `/api/v1/agents/pet` | 桌面 Token + 目标 Token | 目标宠物图片中转 |
| GET、POST | `/api/v1/theme` | 桌面 Token | Logo 主题读取与双向同步 |
| GET | `/api/v1/agents/discover` | 桌面 Token | 局域网内嗅探在线的 Tomo Agent 设备列表 |
| GET、POST | `/api/v1/proxy` | 桌面 Token | 桌面侧转发上游请求，缓冲响应 |
| GET | `/api/v1/pets` | 桌面 Token | 宠物元数据列表 |
| GET | `/api/v1/pets/{id}/spritesheet.webp` | 桌面 Token | 宠物精灵图 |
| GET | `/api/v1/credentials` | 桌面 Token | 导出启用账号的凭证 |
| GET、HEAD | `/` 及插件静态文件路径 | 无 | 已安装 Web 插件资源 |
| OPTIONS | 任意路径 | 无 | 跨域预检 |

普通快照 API 不提供会话控制。独立 remote API 的路由、权限及启用状态见第 15–20 节；供应商统一刷新、多插件管理仍无对应 HTTP API。

## 4. 健康检查

```sh
curl 'http://127.0.0.1:58350/health'
```

```json
{"status":"ok","service":"tomo","name":"Example Mac","version":"0.8.9"}
```

这是服务存活检查，不验证 Token、供应商登录、Agent 状态或公网证书。当前实现按路径处理健康检查；开发者使用 GET 即可。

## 5. 当前快照

`GET /api/v1/snapshot`，返回 `application/json`。

```sh
curl -H 'Authorization: Bearer YOUR_DESKTOP_TOKEN' \
  'http://127.0.0.1:58350/api/v1/snapshot'
```

虚构响应示例：

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-09-18T02:30:00Z",
  "activePetId": "example-pet",
  "todayMinutes": 42,
  "activity": {
    "state": "thinking",
    "activeTaskCount": 1,
    "activeTasks": [{
      "id": "example-task-1",
      "state": "thinking",
      "title": "编写开放 API 文档",
      "agent": "Deepseek Harness",
      "detail": "分析任务",
      "model": "example-model",
      "workspaceName": "ExampleProject"
    }]
  },
  "connections": [{
    "id": "00000000-0000-4000-8000-000000000001",
    "provider": "codex",
    "label": "开发账号",
    "isHealthy": true,
    "weeklyRemaining": 75,
    "weeklyWindowLabel": "本周"
  }]
}
```

快照读取桌面当前已掌握的数据，不会因为一次 GET 就强制刷新所有官方服务。`generatedAt` 是快照生成时间，不等于每个供应商数据的刷新时间。`isHealthy` 主要来自连接认证状态，不保证所有上游请求此刻成功。

### 顶层字段

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| schemaVersion | integer | 当前为 1；不是整个 HTTP API 的版本号 |
| generatedAt | string | 快照生成时间，ISO 8601 |
| activePetId | string | 当前选中的宠物 ID |
| todayMinutes | integer | 当前桌面服务本地当天一起工作的整分钟数 |
| activity | object | 当前 Agent 活动汇总 |
| connections | array | 桌面启用的供应商连接，按桌面连接顺序组织 |

`todayMinutes` 来自桌面 `CompanionStatsStore`，是累计秒数向下取整后的分钟数；没有绑定统计存储时返回 0。其日期边界遵循桌面本地日历，不是供应商额度或任务的持续时间。Agent 池切换后，每个服务的值属于那台桌面，不应未经去重就相加。

### activity 与任务

`activity` 包含必填的 `state: string`、`activeTaskCount: integer`、`activeTasks: array`。

| 任务字段 | 类型 | 必填 | 含义 |
| --- | --- | --- | --- |
| id | string | 是 | 任务标识；按原样保存 |
| state | string | 是 | 活动状态 |
| title | string | 是 | 桌面提供的显示标题 |
| agent | string | 是 | Agent 显示名称，不是固定枚举 |
| detail | string | 否 | 细节文案 |
| model | string | 否 | 模型显示信息 |
| workspaceName | string | 否 | 工作区显示名称 |
| gitBranch | string | 否 | Git 分支 |

当前状态值：`unavailable` 不可用、`idle` 空闲、`thinking` 思考、`executing` 执行、`reviewing` 检查、`waitingForUser` 等待用户、`completed` 完成、`interrupted` 中断。汇总状态和单个任务状态并不要求完全一致。

显示信息由桌面活动聚合逻辑决定，部分 Agent 的标题或模型会被归一化；不要依赖标题推断任务原始身份。多服务池应使用“服务 ID + 任务 ID”作为客户端主键。

### connections

必填字段：`id: string`、`provider: string`、`label: string`、`isHealthy: boolean`。当前 provider 包括 `codex`、`gemini`、`deepseek`、`opencode`，客户端应容忍未来新增类型。

以下均为可选字段，按供应商和已获取的数据出现：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| shortWindowRemaining、weeklyRemaining | number | 对应额度窗口剩余百分比，展示尺度 0–100 |
| claudeGptFiveHourRemaining、claudeGptWeeklyRemaining | number | Gemini 连接中的相关模型额度剩余百分比 |
| shortWindowLabel、weeklyWindowLabel | string | 额度窗口显示名称 |
| shortWindowResetAt、weeklyWindowResetAt | string | 重置时间或显示描述；不保证统一 ISO 格式 |
| accountName、email、planName | string | 账号与套餐显示信息 |
| balance | string | 余额显示文本，可能包含货币单位 |
| subscriptionActiveUntilISO | string | 订阅结束时间信息 |
| subscriptionWillRenew | boolean | 是否自动续费 |
| subscriptionDaysRemaining | integer | 剩余天数 |
| subscriptionReminderMessage、subscriptionRenewalLine | string | 订阅提示与续费显示文案 |
| resetCoupons | array | 重置券列表，结构见下表 |
| keySuffix | string | 密钥尾部显示信息，不是完整密钥 |
| statusColor | string | 桌面提供的状态颜色标识 |
| toppedUp、granted | string | DeepSeek 充值与赠送金额字符串 |
| availableModelCount | integer | 可用模型数量 |
| availableModelIDs | string[] | 可用模型 ID 列表 |
| lastValidatedAt | string | 最近验证时间显示文本，可能是本地化格式 |

不要把余额字符串当浮点数运算，也不要把重置时间显示文案直接传给 `Date.parse`。快照不包含完整供应商凭证。

每个 `resetCoupons` 元素：

| 字段 | 类型 | 必填 | 含义 |
| --- | --- | --- | --- |
| id、title、expiresAt | string | 是 | 标识、标题、到期时间信息 |
| description、source、grantedAt | string | 否 | 描述、来源、授予时间 |
| status、resetType | string | 否 | 业务状态与重置类型 |
| profileImageURL、profileUserID | string | 否 | 授予方头像 URL 与显示信息 |

## 6. Agent SSE

`GET /api/v1/events` 返回 `text/event-stream`。使用事件名监听，不能只写 `onmessage`；这里的状态事件叫 `snapshot`。

```sh
curl -N -H 'Authorization: Bearer YOUR_DESKTOP_TOKEN' \
  'http://127.0.0.1:58350/api/v1/events'
```

连接建立后先发送 keepalive 注释，再发送一次当前完整快照；之后桌面活动、宠物、连接设置或工作分钟变化会触发快照广播。事件是完整替换数据，不是 JSON Patch。

```text
: keepalive

event: snapshot
data: {"schemaVersion":1,"generatedAt":"2026-09-18T02:30:00Z","activePetId":"example-pet","todayMinutes":42,"activity":{"state":"idle","activeTaskCount":0,"activeTasks":[]},"connections":[]}

event: heartbeat
data: {"heartbeat":true}

```

heartbeat 每 15 秒发送，表示连接仍存活，不表示任务发生变化。响应包含 `Cache-Control: no-cache, no-transform` 和 `X-Accel-Buffering: no`；外层代理仍需确认未缓冲流、未缓存响应且读取超时足够长。

浏览器示例：

```js
const baseURL = 'http://127.0.0.1:58350';
const desktopToken = 'YOUR_DESKTOP_TOKEN'; // 实际接入时由用户输入
const eventsURL = new URL('/api/v1/events', baseURL);
eventsURL.searchParams.set('token', desktopToken);

const events = new EventSource(eventsURL);
events.addEventListener('snapshot', event => {
  const snapshot = JSON.parse(event.data);
  // 用完整快照更新本服务状态；不要在这里请求全部供应商。
  console.log(snapshot.activity, snapshot.todayMinutes);
});
events.addEventListener('heartbeat', () => {
  // 更新流连接存活时间，不改变任务内容。
});
events.onerror = () => {
  // 显示正在重连；EventSource 会尝试重连。
};
// 组件卸载、切换或删除服务时：events.close();
```

当前没有事件 ID、Last-Event-ID 重放或离线历史补偿。重连会重新获得当前快照，无法恢复断线期间所有中间状态。SSE 只缩短传输层延迟，桌面发现任务本身的延迟仍然存在。Mobile 首先等待 SSE 首条快照；5 秒未收到有效快照、流断开或 45 秒无消息时，才补查快照。流正常时不主动重复拉取，点击立即检查可主动补查。

需要中转快照时使用 `GET /api/v1/agents/snapshot?target=<目标完整快照 URL>`，当前桌面 Token 放在 `Authorization`，目标 Token 放在 `X-Target-Authorization`，两者均使用 `Bearer` 格式。target 仅允许 HTTP/HTTPS、不含用户名密码、query 或 fragment，路径必须以 `/api/v1/snapshot` 结尾。Agent 快照不使用供应商通用 `/api/v1/proxy`。局域网快照及 SSE 中转直接连接目标，不经过供应商外网代理；当前桌面仍须能访问目标网络。

## 7. 其他 Agent 服务的 SSE 转发

`GET /api/v1/agents/events` 由当前桌面服务连接另一台桌面的事件流，适合 Agent 链接池和手机无法直接访问目标的情况。

| 参数 | 必填 | 含义 |
| --- | --- | --- |
| target | 是 | 目标完整 `/api/v1/events` URL |
| target_token | 是 | 目标服务的配对 Token |
| token 或 Authorization | 是 | 当前中转桌面服务的 Token |

target 只接受 HTTP/HTTPS URL，需要 host，不允许内嵌用户名密码、query 或 fragment；path 必须以 `/api/v1/events`  结尾。当前服务能访问目标网络是前提。

```js
const relayURL = new URL('/api/v1/agents/events', 'https://desktop.example.com');
relayURL.searchParams.set('token', 'YOUR_CURRENT_DESKTOP_TOKEN');
relayURL.searchParams.set('target', 'http://192.168.10.11:58350/api/v1/events');
relayURL.searchParams.set('target_token', 'YOUR_TARGET_DESKTOP_TOKEN');
const relay = new EventSource(relayURL);
relay.addEventListener('snapshot', event => {
  const targetSnapshot = JSON.parse(event.data);
  // 这里只更新这个目标服务的 Agent 状态，不替换当前服务的供应商账号。
});
```

中转将目标 Token 作为 Authorization 发送给目标，逐行转发 SSE，不等待完整响应。上游请求超时配置为 3600 秒，单行缓冲上限 1 MiB。建立流后异常通常表现为断开，客户端需要重连。

建立流前错误：参数不合法 `400 / invalid_agent_stream`；上游非 200 时转发其状态和 `agent_stream_failed`；网络失败或非 SSE 响应为 `502 / agent_stream_unavailable`。错误值位于 JSON 的 `error` 字段。

Agent 池的名字、选择和启用状态属于调用应用的配置，服务器没有池管理 API。Agent 池切换只切换任务来源；供应商代理及账号信息继续使用用户配置的当前桌面服务。

## 8. 供应商信息代理

`GET /api/v1/proxy?target=...` 或 `POST /api/v1/proxy?target=...`。

该接口让浏览器先访问桌面，再由桌面请求上游，解决官方服务不允许浏览器跨域的问题。它不是统一供应商 SDK，也不能保证官方内部接口一直兼容。

| 输入 | 含义 |
| --- | --- |
| target 查询参数 | 上游完整 URL，包含其所需查询参数；整体 URL 编码 |
| Authorization 或 token | 认证当前桌面服务 |
| x-target-authorization 请求头 | 上游 Authorization 完整值，例如 `Bearer YOUR_PROVIDER_TOKEN` |
| Content-Type 请求头 | POST 上游的内容类型，缺省为 application/json |
| POST 请求体 | 当前实现按 UTF-8 文本转发 |
| chatgpt-account-id 请求头或 account_id 查询参数 | ChatGPT 上游账号标识，按需传入 |

必须显式提供 `x-target-authorization`；缺失返回 `400 / missing_provider_authorization`。桌面 Authorization 不作为上游认证。

```js
const proxyURL = new URL('/api/v1/proxy', 'https://desktop.example.com');
proxyURL.searchParams.set('target', 'https://api.deepseek.com/user/balance');
const response = await fetch(proxyURL, {
  headers: {
    Authorization: 'Bearer YOUR_DESKTOP_TOKEN',
    'x-target-authorization': 'Bearer YOUR_PROVIDER_KEY'
  }
});
if (!response.ok) throw new Error(`代理请求失败：${response.status}`);
const upstreamData = await response.json();
```

示例演示代理用法；实际上游地址和响应结构仍应对照供应商文档。用于只读面板时优先使用 snapshot，确实需要单独查询才走 proxy。

当前实现的边界：

- 上游请求超时 30 秒，完整读取响应后返回；不支持把它当作 SSE 或模型生成流接口。
- 上游 HTTP 状态透传；响应按 UTF-8 文本处理，无法解码时使用 `{}`，Content-Type 被设为 application/json。不能承诺二进制代理。
- 请求头不是全部透传；仅处理上述头和桌面为 ChatGPT / Google 等上游补充的特定头。
- 缺少或无法解析 target：400 文本 `Missing target parameter`；网络异常：502 JSON，包含 error、code 和 message。
- 只接受 HTTPS、默认或 443 端口、无用户名密码和 fragment 的供应商查询 URL；精确限制域名、路径与方法。不支持的目标返回 `400 / unsupported_provider_request`。禁止跟随上游重定向。Agent、桌面 API 和任意其他网址均不得使用此入口。
- GET 允许 chatgpt.com 的 `/backend-api/wham/usage`、`/backend-api/subscriptions`、`/backend-api/wham/rate-limit-reset-credits`，以及 api.deepseek.com 的 `/user/balance`。POST 只允许 daily-cloudcode-pa.googleapis.com 的 `/v1internal:loadCodeAssist`、`/v1internal:retrieveUserQuotaSummary`。新增供应商接口须更新服务端允许列表。

目前没有“不向调用应用交付供应商凭证、按桌面连接 ID 自动注入认证”的统一代理 API。如果后续希望应用只配置当前服务 Token 就能刷新任意供应商，应单独设计服务器端连接代理接口；不要把此能力写成现有功能。

## 9. 宠物资源

`GET /api/v1/pets` 返回元数据数组，字段均必填：

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| id、displayName、description | string | 宠物标识、名称和说明 |
| frameWidth、frameHeight | integer | 每帧尺寸 |
| totalRows、totalColumns | integer | 精灵图行列数 |
| actionRowMap | object<string, integer> | 动作对应行索引 |

通过 `/api/v1/pets/{id}/spritesheet.webp` 获取 `image/webp`；路径中的 id 应编码，并带桌面认证。先按 manifest ID 找 App 内置 Pets 资源，再找用户 Pets 目录与 Plugins/pets 目录，没有资源返回 404。默认 ID 为 `builtin:tomo-tako`，裸 ID `tomo-tako` 同样支持。路径 ID 拒绝斜线和目录穿越。

按照元数据切帧和选择动作，不要硬编码尺寸或行列。当前模型缺省尺寸为 192×208、11 行×8 列，不能推导所有宠物都必须如此。

## 10. 凭证导出

`GET /api/v1/credentials` 返回：

```json
{
  "exportedAt": "2026-09-18T02:30:00Z",
  "accounts": [{
    "id": "00000000-0000-4000-8000-000000000001",
    "provider": "codex",
    "label": "开发账号",
    "tokenOrKey": "EXAMPLE_ONLY_NOT_A_REAL_TOKEN"
  }]
}
```

`exportedAt` 为 ISO 8601；accounts 元素的 id、provider、label、tokenOrKey 均为字符串。导出启用的 Codex / Gemini OAuth access token，以及 DeepSeek / OpenCode API Key，读取失败时 tokenOrKey 可能为空字符串。账号 ID 可与快照 connections 对应。

这是明文凭证导出，不是普通健康查询。只展示任务、宠物和已有额度的应用无需调用。静态文档站不调用此接口，不存储凭证，不把真实响应加入搜索索引。

## 11. 可选接入方式：Web 插件托管与安装包

本节仅适用于希望由 Tomo 托管前端静态页面的开发者。独立 Web、原生应用、CLI 和服务端程序无需 ZIP、plugin-manifest.json 或此安装槽位，直接调用 HTTP API 即可。

Web Mobile 0.0.8 及以前版本一律失效。安装器拒绝这些已标识的旧版本包；已安装旧版本的静态页面返回 410 失效提示。0.0.9 起使用 /api/v1/，必须配套更新桌面服务。

当前只有一个 `mobile-web` 安装槽位，目录为：

```text
~/Library/Application Support/Tomo/Plugins/mobile-web
```

ZIP 解压后的有效根目录必须包含 `index.html`，可包含一层包裹目录。安装会替换当前插件目录；当前不是多插件注册系统。

可选的 `plugin-manifest.json`：

```json
{
  "name": "example-web-plugin",
  "version": "0.1.0",
  "build": 1,
  "minTomoVersion": "0.8.3",
  "description": "示例插件",
  "author": "Example Author",
  "entry": "index.html"
}
```

name、version 是 manifest 解码必填字段，其余可选。当前安装逻辑以 index.html 为入口和有效性依据，不应假设 entry 已支持任意入口，或 minTomoVersion 已强制拦截不兼容安装。

`plugin-manifest.json` 描述插件包，与 PWA 的 `manifest.webmanifest` 不同。公开 PWA manifest 的 start_url 当前改为 `./`，不含配对 Token；PWA 启动后的配对配置由客户端另行处理。

GET /HEAD 静态文件不需要认证，不能打包秘密。当前 `assets/` 资源使用一年 immutable 缓存，入口和其他文件使用禁缓存策略；构建后的 assets 文件名应带内容哈希。正式开发文档站将使用独立资源位置，不能覆盖这个插件安装槽位。

## 12. 接入检查清单

1. 确认桌面服务开启、实际端口和可访问的 Base URL。
2. 请求 health，再用桌面 Token 请求 snapshot；区分网络、认证和数据问题。
3. 任务状态优先订阅 SSE，按 `snapshot` 事件更新完整状态，处理心跳、重连和组件卸载。
4. 多 Agent 服务隔离存储和任务主键；供应商数据固定来自当前服务。
5. 额度显示允许未知、字段缺省和旧版缺少 todayMinutes；不要显示为错误的零余额。
6. 浏览器不直接请求官方供应商；额外查询经过当前桌面 proxy，凭证来源与访问权限另行明确。
7. 不把配对 Token 或供应商凭证写入 manifest、构建产物、日志或文档。

schemaVersion 当前不能用于判断 events/proxy 等路由是否存在。旧版本接入需对照文档基线、接口探测和降级行为。HTTP 接口仍使用 `/api/v1/` 路径；未来破坏性变更需要明确迁移方案。


## 13. 文档范围与 TomoGo 调用对应

本文件是 **TomoGo 使用的桌面能力 API** 完整入口，覆盖 MobileSyncServer 对外 HTTP/SSE。供应商实际额度查询经 proxy 转发，其上游协议不属于 Tomo 自定义 API。TomoServer 的登录、用户、会员与兑换码属于另一服务；桌面内部 app-server stdio RPC、模型网关及调试工具不计入本契约。

| TomoGo 功能 | 客户端入口 | 桌面 API |
| --- | --- | --- |
| 配对与首页任务、工作时长、额度初始快照 | services/api.ts、App.tsx | snapshot、events、health |
| 供应商账号导入、官方额度补查 | PairingModal、SettingsModal、officialQuotaService | credentials、proxy |
| 宠物展示与选择 | ApiService、CompanionHero | pets、spritesheet.webp |
| 多桌面服务池、发现与实时状态 | agentPool、agentLive、lanDiscoveryService | agents/discover、agents/snapshot、agents/events、agents/pet |
| Logo 外观同步 | ApiService | GET/POST theme |
| 服务器 → Agent → runtime → session | remote/RemoteClient.ts | remote/catalog、remote/sessions |
| 历史与实时聊天展示 | RemoteSessionHistory、SessionCoordinator | messages、sync、events |
| 当前任务中断与回执恢复 | SessionOperationControl、OperationTracker | interrupt、operations/{id}、operations/by-key/{key} |

可见产品名称使用 ChatGPT；现有供应商 wire 值 `codex` 和 Agent ID `agent.chatgpt` 不得为了显示名称更改而替换。所有示例账号、ID 和 Token 均为虚构占位。

## 14. 主题、发现与宠物中转补充

### GET /api/v1/theme

200 JSON：`{"config":{...},"syncEnabled":true}`。config 是 Logo 渲染设置，不是整个 App 的明暗页面主题。后者由 TomoGo 自身偏好持久化。

### POST /api/v1/theme

请求头 Content-Type: application/json，正文直接传 config 对象，不能包在 config 属性中。200 返回 `{"success":true,"synced":true}`，可附 `message`；HTTP 200 不表示业务 success 必为 true。解码失败为 400 / invalid_theme_config。建议先 GET 再修改，以保留现有配置。

| config 字段 | 类型 | 当前渲染取值/说明 |
| --- | --- | --- |
| logoFamily | string | circle / hex / squircle / cloud7 / pure / pure_go；旧 quota 迁移为 hex + percent |
| logoContent | string | t / percent |
| notchMode、glyphMode | string | off/on；solid/cutout |
| fillType、gradientAlgo | string | solid/gradient；vibrant/subtle/deep |
| gradientAngle | integer | 渐变角度，常用 45/90/135/180 |
| accentColor、accentEndColor | string / nullable string | 起止 HEX 色；终点缺省可自动计算 |
| tileBgColor、renderMode | string | 背景 HEX；color/mono/inverse |
| shadowEnabled、shadowStyle | boolean、string | 阴影开关；tight/soft |
| logoScale、shadowDirection | number、string | 常用 0.50–1.20；down/bottomRight/radial/up |
| materialTexture、glassOpacity | string、number | flat/glass；常用 0.20–0.95 |
| updatedAt | number | Unix 毫秒，与 remote 的 ISO 日期区别 |

这些取值是渲染约定，不能当作 HTTP 已对全部枚举和范围做严格校验。缺省字段由桌面解码器补默认值。

### GET /api/v1/agents/discover

可选 query `subnet`，例如 `192.168.10`。200：`{"devices":[{"ip":"192.168.10.7","port":58350,"baseUrl":"http://192.168.10.7:58350","name":"Example Mac","isPlugin":true,"isLocal":false,"version":"0.8.9"}]}`。version 可缺省。

当前探测所选 IPv4 前缀的 1–254 地址，固定端口 58350，即使本服务使用其他端口也不会自动探测目标自定义端口。发现结果不等于已配对、已获 remote 授权或可控制。插件清单只是设备显示信息。

### GET /api/v1/agents/pet

必填 query `target`，目标完整 HTTP/HTTPS `/api/v1/pets/{id}/spritesheet.webp` 地址；目标认证通过 `target_token` 或 `X-Target-Authorization: Bearer ...`，当前桌面认证仍是配对 Token。成功透传图片 Content-Type，缓存 7 天。400：invalid_agent_pet_target / missing_target_token；上游非 200 返回该状态及文本；网络失败 502 / upstream_unavailable。客户端应编码整个 target，不应把目标 Token 混同当前 Token。

## 15. 独立 remote 接口总览与启用状态

| 方法 | 路径（前缀 /api/v1/remote） | 权限/能力 | 当前状态 |
| --- | --- | --- | --- |
| GET | /catalog | 授权资源可见性 | 已实现；TomoGo 调用 |
| GET | /sessions | sessions.list + history.read 可见会话 | 已实现；TomoGo 调用 |
| GET | /sessions/{sessionId}/messages | history.read | 已实现；TomoGo 调用 |
| GET | /sessions/{sessionId}/sync | history.read，本机已注册同步源 | 已实现；TomoGo 调用 |
| GET | /sessions/{sessionId}/events | history.read，同步源及事件游标 | 已实现；TomoGo fetch SSE 调用 |
| DELETE | /access/current | 当前 remote 凭证 | 已实现；当前 RemoteClient 无专用包装 |
| POST | /sessions/{sessionId}/interrupt | turn.interrupt、当前可控 turn | 路由/账本/Adapter/客户端已实现；正式服务可由原生 owner 接管并单独批准 ACL，真实设备链待验收 |
| POST | /sessions/{sessionId}/messages | message.send、当前 running steer 或独占 start 条件 | 已接入 steer 与回执并完成合成浏览器联验；正式受控 runtime 可发布 steer，真实模型链及 start 待完成 |
| GET | /operations/{operationId} | 原操作 owner + 对应动作 scope | 条件路由已实现；客户端已实现 |
| GET | /sessions/{sessionId}/operations/by-key/{key} | 原操作 owner + 对应动作 scope | 条件路由已实现；客户端已实现 |

操作路由必须由桌面本机安装 RemoteOperationService 并注册来源；默认未安装返回 501。默认仍只读；DEBUG 设置支持先恢复会话，再选择单独中断或“追加消息与中断”授权，生成 development-control 配置并撤销旧只读配置。写动作 scope 仅覆盖所选 session，目录与历史保持可读；生产用户/设备/VIP 认证和真实手机控制验收尚未完成，不能因开发入口存在宣称正式可用。

Agent descriptor 中的 possibleActions 是潜在能力，每个 runtime 另有实际动作范围。原 ChatGPT 历史目录只读；原生明确接管的独立 runtime 可发布控制能力，不能因此扩大原目录权限。动态控制以 sync 与 session.updated 的 allowedActions/controlMode 为准。publishCommands 仅本机调用，实际发布取 journal 状态、已注册同 executionEpoch 操作源和 caller scope 的交集。服务关闭、来源变化或缺少权限时撤回。

### 本机开发设置流程

1. 开启桌面 API 服务，在 DEBUG 的“远程会话 · 开发访问”填入存储目录和手机实际 Web Origin，生成只读授权。
2. 读取列表，选择会话和 CLI，明确确认其他执行端已停止，再恢复并接入实时会话。
3. 单独点击“授权手机中断所选会话”并确认；或明确选择“授权手机追加消息与中断”（仅执行中追加纯文本，不能开启新回合）。重新复制连接配置导入 TomoGo，旧配置已撤销。
4. 手机只对 sync 发布的当前 turn 显示中断，提交与回执查询仍受来源/action/当前授权检查。
5. 停止受管进程撤回操作来源，未下发账本拒绝，已下发且不确定的保留 unknown；历史授权可继续读。撤销授权或关闭服务同时清理本机控制服务。

开发身份使用本机 owner 标签与授权 principal ID，只代表这一开发凭证，不代表 TomoServer 生产设备身份。到期须重新本机授权；不会自动恢复、自动重新授权或自动重发中断。

### remote 鉴权

只接受 `Authorization: Bearer <REMOTE_TOKEN>`。普通配对 Token 不可替代；URL `token` / `access_token` 被拒绝。重复 Authorization、Origin、Last-Event-ID、Idempotency-Key、Content-Type 头被拒绝。

当前是桌面 owner 显式签发的 development 授权，默认关闭，最长 300 秒，绑定来源 scope、可选精确 Origin 和授权 generation。浏览器必须使用签发时的 Origin；原生无 Origin 调用需相应无 Origin 授权。TomoGo 导入 `serverURL/token/expiresAt/mode` 配置，mode 为 development-read-only 或 development-control；mode 不是服务端权限证明。生产用户、设备与 VIP 验证将由 TomoServer 完成，当前不能用客户端 VIP 标志代替。

所有 remote JSON 响应 no-store。remote 预检允许 GET/POST/DELETE/OPTIONS 和 Authorization、Content-Type、Accept、Last-Event-ID、Idempotency-Key。不要用原生 EventSource URL Token 接入 remote，TomoGo 使用带请求头的 fetch 流。

## 16. 目录与历史

### GET /api/v1/remote/catalog

不接受 query。200：`serverId: string`、`agents: {catalogRevision: integer, items: AgentCatalogItem[]}`、`runtimes: Runtime[]`。

AgentCatalogItem：agentId/displayName/status，可选 unavailableReason/descriptor/negotiatedProtocol。status 为 registered 或 incompatible；不兼容项目没有 descriptor。descriptor 包含 adapterId、adapterVersion、descriptorSchemaVersion、supportedApiMajors/supportedEventMajors/supportedContentMajors、surfaces（id/kind/label）、brand（可选 iconAssetId、fallbackGlyph）、possibleActions、inputTypes/outputTypes、requiredClientFeatures、discoveryMode、minRemoteApiVersion。negotiatedProtocol 为 apiMajor/eventMajor/contentMajor；HTTP 当前固定协商已实现的 v1，不接受客户端任意版本 query。

Runtime：agentId/runtimeId/label/controlMode/allowedActions。目录只包含当前凭证可见资源，空数组并不等于服务器没有安装其他 Agent。

### GET /api/v1/remote/sessions

| query | 必填 | 说明 |
| --- | --- | --- |
| agent_id、runtime_id | 是 | 从目录原样取得，完整来源的一部分 |
| cursor | 否 | 上一页 nextCursor，不可自行构造 |
| limit | 否 | 1–100，默认 30 |

200：`items: SessionSummary[]`、`nextCursor: string|null`、`hasMore: boolean`、`indexState: ready|building|partial`。

SessionSummary：serverId、agentId、runtimeId、sessionId、title、updatedAt（ISO8601）、archived（boolean）、controlMode、allowedActions。客户端主键必须为完整四元组，不能只用 sessionId 或显示名称。会话 ID 为桌面公开 opaque ID，不是 vendor 原始 thread ID。当前列表不支持搜索、客户端指定 storage 路径或独立 archived query。

### GET /api/v1/remote/sessions/{sessionId}/messages

必填 agent_id/runtime_id，可选 history_cursor、limit（1–100，默认 50）。初次返回最新历史窗口，每页内部按聊天时间正序；下一游标指向更旧内容，客户端前插而不是追加到末尾。

200：sessionId、messages、olderHistoryCursor（string|null）、hasOlder（boolean）、unsupportedContentCount（integer）。该计数反映未渲染内容，不应伪造为完整历史。

| Message 字段 | 类型 | 说明 |
| --- | --- | --- |
| messageId、messageRevision | string、integer | 稳定公开 ID 和内容修订，合并去重使用 |
| turnId | string\|null | 公开 turn ID |
| role | string | user / assistant；不导出私有 system/developer/reasoning |
| createdAt、status | string | 时间；当前常用 streaming/completed/failed |
| content | Part[] | 当前适配器以可见文本为主 |
| Part.partId、type、text | string | 分片 ID、类型（text/error 等）、可见文本 |

目录和历史游标绑定当前 principal 及完整来源，最长 5 分钟且不超过凭证有效期；服务重启丢失内存游标。历史读取固定文件快照字节与摘要，新增日志不进入旧分页，截断/替换会触发重取。不能将游标当 offset、日期或路径，也不能跨 Token/会话复用。

## 17. 会话快照与事件流

### GET /api/v1/remote/sessions/{sessionId}/sync

可选 agent_id/runtime_id，但必须同时出现；TomoGo 始终传入以校验完整来源。只接受这两个 query。session 必须已由本机 runtime attach 注册，能列出历史不保证已有实时同步源。

返回结构为扁平对象，**没有 projection/control 包装层**：

```json
{
  "sessionId":"ses_example","executionEpoch":"execution_example","controlRevision":4,
  "state":"running","controlMode":"readOnly","currentTurnId":"turn_example",
  "allowedActions":["history.read"],"messages":[],"activities":[],"pendingRequests":[],
  "olderHistoryCursor":null,"hasOlder":false,
  "streamEpoch":"stream_example","sequence":12,"eventCursor":"opaque_cursor"
}
```

executionEpoch 标识上游执行，streamEpoch 标识本机事件日志，两者不能互换；controlRevision 只用于控制状态比较。state 当前以 idle/running/waitingForUser/completed/interrupted/failed/unavailable 为主。controlMode 为 readOnly/live/unavailable。pendingRequests 当前对外固定空数组，审批/问答仍未发布。

`activities` 是只读工具活动摘要：`activityId`（不透明 ID）、`turnId`、`activityRevision`、`kind`、`status`、`createdAt`。`kind` 当前限定为 command/fileChange/mcpTool/dynamicTool/collabTool/webSearch/imageView/imageGeneration；`status` 为 running/completed/failed/unknown。Codex 实时事件和完整 `thread/read` 基线可提供这些摘要，但旧 rollout 历史不补造缺失工具事件。字段不含命令正文、路径、工具参数或输出，也不等同于 DSH 原始 `tool/call`/`tool/result`；未来富工具卡片需单独审查数据授权和来源语义。

### GET /api/v1/remote/sessions/{sessionId}/events

先 sync，再取其 eventCursor 连接 SSE。来源 query 同 sync；游标用 Last-Event-ID 请求头或 after query（二者同时出现必须相同），不能为空。不要把 legacy snapshot SSE 游标套用到此接口。

```sh
curl -N -H 'Authorization: Bearer REMOTE_TOKEN' \
  -H 'Last-Event-ID: OPAQUE_EVENT_CURSOR' \
  'http://127.0.0.1:58350/api/v1/remote/sessions/ses_example/events?agent_id=agent.chatgpt&runtime_id=rt_example'
```

每条事件：SSE id 为 opaque 游标；event 是类型；data 为 schemaVersion/sessionId/streamEpoch/sequence/occurredAt/type/payload。sequence 必须连续，消息修订必须正确；重复忽略，断档或 epoch 改变重取 sync，不可盲目拼接 delta。

| event | payload | 处理 |
| --- | --- | --- |
| message.created、message.completed | 完整 Message | 按 messageId/revision 覆盖合并 |
| message.delta | messageId/partId/messageRevision/delta | 对已有指定文本分片追加 |
| activity.created、activity.updated | 完整只读工具活动摘要 | 按 activityId/revision 合并；状态只能从 running/unknown 转入已知终态，冲突时重新 sync |
| session.updated | 扁平 RemoteSessionControl | 更新 executionEpoch/revision/state/mode/turn/actions |
| sync.required | reason | 停止旧流并重取 sync |
| access.revoked | reason | 清理授权与私有缓存，不继续自动重连 |

approval/question 事件当前被投影成 sync.required，不发布可执行的私有请求；operation.updated 已作为同一连接的独立回执通道接入。它不带 streamEpoch/sequence，并以空 id 字段防止继承历史事件 ID；不会推进会话日志游标。回执按可信用户/设备/完整来源/动作隔离，发送每条前通过操作服务重新校验身份与权限。通知最多 64 个订阅、每个 128 条缓冲，溢出或通知服务关闭要求恢复同步与 GET 查询；不得据此重发 POST。客户端仅接收当前完整来源、原 operationId 或唯一 clientMessageId 匹配的回执，已确认结果不被迟到 POST/GET 降级。明确手动 GET 可将 unknown 更新为同操作的已确认结果。断开、切换、撤权清理监听；事件缺失和重启仍用原 key/id 的有界 GET 恢复。heartbeat 是每 15 秒的注释，不带事件 ID，不推进序号。空闲流也定时检查撤销，授权在每个发送帧前再检查。

`operation.updated` 示例（独立侧通道，不套用历史事件的序号校验）：

```text
id:
event: operation.updated
data: {"schemaVersion":1,"type":"operation.updated","serverId":"srv_1","agentId":"agent.chatgpt","runtimeId":"rt_1","sessionId":"ss_1","operation":{"operationId":"op_1","sessionId":"ss_1","clientMessageId":null,"state":"applied","turnId":"tr_1","errorCode":null,"createdAt":"2026-10-03T00:00:00Z","updatedAt":"2026-10-03T00:00:01Z"}}

```

事件仅补充持久账本回执，applied 表示上游确认请求，不表示模型任务完成。只读订阅不订阅操作通知，其他设备没有收到该 operationId 的权限。 已通过正式 TomoGo 浏览器与合成上游的真实 HTTP/SSE 联验：发送和中断均读取到 stream 来源回执，延迟发送经历 tracking→applied，草稿清空且没有重复 RPC。该证据不代表真实 CLI 活跃执行或生产 VIP 授权已验收。


默认重放保留约束为 1,024 条、8 MiB、300 秒；超过任一条件可失效，不是承诺固定可重放 5 分钟。无效游标在建立流前返回 409；已建立流失效发 sync.required 后关闭。断开取消释放 feed；全局 remote 连接上限 32。

## 18. 操作提交与查询

所有 POST 必须 application/json 和 `Idempotency-Key`（16–128 ASCII 字母/数字/下划线/连字符），正文不超过 64 KiB。幂等 namespace 包含可信 owner、完整来源、key；摘要还包含动作、epoch 和正文。同 key 同正文返回原 operation，同 key 不同正文返回 409。调用者不能传 userId/deviceId/owner 或 vendor thread、工作目录、模型/权限覆盖。

### POST /api/v1/remote/sessions/{sessionId}/interrupt

来源 query 同 sync。正文：

```json
{"executionEpoch":"execution_example","turnId":"turn_example"}
```

必须使用 sync 给出的当前公开 turnId，当前 live 且包含 turn.interrupt；执行变化/旧 turn 被拒绝。不能把中断当作通用任务删除或 runtime 停止。

### POST /api/v1/remote/sessions/{sessionId}/messages

条件性 text-only 接单契约：

```json
{
  "executionEpoch":"execution_example","clientMessageId":"client_example",
  "expectedControlRevision":4,"mode":"start",
  "input":[{"type":"text","text":"请继续分析"}]
}
```

输入 1–32 段，合计 ≤48 KiB 且至少有非空白文本，不接受附件和其他字段。必须 idle、当前无 turn/请求且可信本机上下文保证独占 fresh start。当前真实 coordinator 不承诺该条件，正常发送未开放，不得依据上述示例展示可用发送按钮。审批、问答、create/fork/resume 没有对应已开放 HTTP POST。

执行中追加消息的适配契约（DEBUG 开发授权或正式服务原生 owner 接管并单独批准 ACL；客户端已接入）：

```json
{
  "executionEpoch":"execution_example","clientMessageId":"client_example",
  "expectedControlRevision":4,"mode":"steer","expectedTurnId":"turn_public_example",
  "input":[{"type":"text","text":"请优先检查会话同步"}]
}
```

`steer` 同样受上述纯文本数量/大小限制，额外要求当前 revision 一致、state=running、没有待回复请求，并以 sync 的公开 turnId 匹配可信本机私有 turnId。适配器调用 `turn/steer`，携带私有 `expectedTurnId`、原 `clientUserMessageId` 与纯文本 input；上游原子检查活跃回合，不匹配时失败。仅回执 turnId 与请求对应的私有回合一致才标记 applied；不确定结果保留 unknown，绝不降级成 turn/start、不改目标回合、不自动重发。

协议依据：本机 Codex app-server CLI 生成的 v2 `TurnSteerParams`/`TurnSteerResponse` JSON Schema，expectedTurnId 为必填活跃回合前置条件。该映射、持久幂等、coordinator running-only 能力发布和 DEBUG 独立授权已实现；默认中断授权不包含 message.send。完成/中断/失败撤下追加消息能力，未实现的审批请求使控制不可用。TomoGo 已通过共享 ChatComposer、RemoteClient.sendMessage 和 OperationTracker 接入 steer；按当前完整来源/能力/状态显示输入，POST 或查询回执须匹配原 clientMessageId，applied 的 turnId 也须一致。草稿仅当前页面内存保存，成功回执清除对应提交内容；不确定结果保留草稿并查询原 key，切换会话/撤权清除。已通过合成上游下的真实 HTTP/SSE + 正式页面浏览器联验：中文/换行/emoji 原样进入历史、applied 清除原草稿、只读会话无入口、完成后撤权并保留未提交草稿。每个隔离实例一次 RPC/一条 applied 账本，授权过期清除连接与内容。真实 CLI 隔离负向联验已确认：空闲 thread 的 `turn/steer` 返回 `-32600`（无活跃回合），后续仍为 idle；真实 CLI 恢复已完成合成历史后，即使显式授予 steer，sync 仍无 message.send/turn.interrupt 能力。这些测试不启动模型回合、不读取真实用户会话。真实 CLI 活跃执行的追加/中断、桌面 manager UI 与真机键盘发送联验仍待完成，不将负向或合成浏览器结果视为生产控制验收。

### 202 回执与 GET 查询

POST 成功返回 202 operation；仅表示接单，收到时可能已被并发调度推进。GET `/operations/{operationId}` 或 `/sessions/{sessionId}/operations/by-key/{key}` 返回 200 同模型，来源 query 建议始终携带 agent_id/runtime_id。按 key 查询要求当前来源仍注册；按 ID 查询可读取原账本，但仍验证原 owner、action scope 和当前权限。

```json
{
  "operationId":"op_example","sessionId":"ses_example","state":"accepted",
  "createdAt":"2026-10-03T00:00:00Z","updatedAt":"2026-10-03T00:00:00Z"
}
```

可选字段 clientMessageId、turnId、errorCode 可能缺省。createdAt/updatedAt 为 ISO8601。回执不包含正文、幂等 key、私有 RPC ID、owner 或 dispatch lease。

| state | 含义与客户端行为 |
| --- | --- |
| accepted | 已持久化，等待下发；查回原操作 |
| dispatching | 已认领，可能进入上游；不创建新 key 自动重发 |
| applied | 上游确认动作被接受；不等于模型任务完成 |
| rejected | 确认未执行/明确拒绝，errorCode 说明原因 |
| unknown | 已下发但无法确定结果，errorCode 为 dispatch_uncertain；查询/对账，禁止自动重发 |

网络超时或响应丢失，首先按原 key GET；404 不证明上游未执行，也不是自动换 key 重发的依据。unknown/非终态不自动清理，applied/rejected 至少保留 24 小时；账本满容量明确失败。撤销远端权限不等于 Agent 已停止。

## 19. remote 错误和请求限制

错误 JSON 形如 `{"error":"code"}`。与 legacy 的文本错误分开处理。

| HTTP | error | 含义/处理 |
| --- | --- | --- |
| 400 | invalid_remote_credentials | 重复认证头或 URL 凭证 |
| 400 | invalid_remote_request | 参数/JSON/字段/幂等键不合法 |
| 401 | remote_access_required | 凭证失效、过期或已撤销；重新本机授权 |
| 403 | remote_access_denied | Origin、资源或动作无权；不可用旧配对 Token 降级 |
| 404 | remote_resource_not_found | 来源/会话/原 owner 操作不存在或不可见 |
| 409 | cursor_expired、history_snapshot_changed | 目录/历史分页失效，重新取首窗口 |
| 409 | event_cursor_expired | 重取 sync，建立新流 |
| 409 | idempotency_key_conflict | 同 key 请求变化，不自动重发 |
| 409 | execution_changed、control_changed、session_busy、start_control_unavailable | 更新控制状态，不能盲目重试 |
| 429 | remote_operation_limit | 操作容量/并发受限 |
| 501 | remote_route_not_implemented、remote_action_not_implemented | 未安装服务或动作未实现 |
| 503 | remote_source_unavailable | runtime/source/服务不可用 |

HTTP framing 另有限制：头部 16 KiB、普通正文 1 MiB、接收 deadline 15 秒；不接受 pipelining，Content-Length 重复或非法拒绝，Transfer-Encoding 当前返回 501（不支持 chunked）。这些拒绝可能不带上述业务 JSON。控制正文更严格为 64 KiB。客户端应设置自身 deadline，并在切换页面/来源时取消 fetch/SSE。

### DELETE /api/v1/remote/access/current

使用当前 remote Authorization，无正文；204 空响应。使当前凭证失效，对应流收到撤销或关闭。桌面本机撤销全部 development 权限是独立设置动作，无 HTTP 签发权限接口。

## 20. 客户端接入顺序与验收边界

普通页面：配对 → snapshot/pets/theme → legacy events → 官方额度需要时 credentials/proxy。Agent 池只改变任务来源，不隐式改变供应商账号来源。

会话页面：导入桌面限时授权 → catalog → 指定 Agent/runtime sessions → messages 历史 → 已注册会话 sync → 带 cursor 的 fetch SSE → 按最新控制能力显示操作 → 同 key 接单/查询 → 离开时取消流。列表历史与受管实时会话不是同一个启用条件。

current next 实际 ChatGPT 读取 Adapter 已接入。统一 registry/服务支持扩展 Adapter，但不能把 DeepSeek/Google 的首页状态 logo 视为它们已支持统一聊天/控制。App VIP 与生产 Web 锁定逻辑属于产品权限；开发授权只为开发联验，不替代 TomoServer 会员验证。

## 21. Next.js 文档站与桌面端口服务

2026-10-04：`app/api-docs` 已实现 Next.js 静态文档站，由本 Markdown 构建生成 23 个章节和本地搜索内容。独立 `ApiDocsServer`、设置启动/停止/端口/LAN 地址与退出清理已接入桌面；完整 Swift 模块编译与资源隔离/真实 GET、HEAD、404、405 测试通过。正式 App 打包和生命周期 UI 联验仍须完成。

- 唯一内容来源为本 Markdown，构建时解析目录/表格/代码与搜索索引；不维护第二份手写 API 字段表。TomoGo docs 通过相对链接指向此文档。
- 新建 Tomo `app/api-docs`，采用 Next.js App Router 静态导出（output: export、trailingSlash: true）；产物 out 随桌面构建打包为独立 ApiDocs 资源。桌面运行时不需要用户安装 Node/npm。此方式符合 [Next.js 官方静态导出说明](https://nextjs.org/docs/app/guides/static-exports)。
- 桌面提供独立只读 Docs 静态服务，建议默认 58351、可配置。不得复用 MobileSyncServer 作为第二实例，以免同时暴露 credentials/proxy/remote。默认仅 loopback，桌面可打开浏览器；明确开启局域网访问后再监听 LAN。
- 设置提供启动/停止/端口/本机链接/可选 LAN 链接，退出时关闭监听；端口冲突显示错误，不自动终止其他进程。Docs 服务生命周期与业务 API 服务分离。
- 页面提供接口分组、目录锚点、全文搜索、方法/路径/状态标签、参数/返回字段、复制虚构 curl、API 更新时间/实现状态；手机布局可折叠目录，并支持明暗主题。
- 首期只查阅，没有 Try it、Token 输入、真实服务响应索引或账号内容。静态资源按真实路径白名单/MIME 服务，拒绝目录穿越和符号链接逃逸；404 不回退业务接口。
- 打包命令构建 Docs 后复制产物，开发可用 next dev 独立端口；正式桌面必须使用已打包静态产物，不在线安装依赖、不远程拉取文档。

已验证 Next.js 导出、Markdown 摘要一致性、全部章节与资源存在、Swift 文档端口只读隔离及浏览器字段搜索/章节定位。待验证：最终打包后离线资源、纯净机器无需 Node、桌面设置实际启动/停止/冲突/退出 UI、窄屏与代码复制。当前只有 next 开发文档，正式发布快照及历史版本切换尚未实现，不将工作区文档伪装成冻结发布版本。


### 2026-10-03：生产云 grant 验签组件（尚未接入 HTTP exchange）

`RemoteCloudGrantVerifier` 使用 [JWTKit](https://github.com/vapor/jwt-kit) 验证 ES256 compact JWS。Package.resolved 固定 JWTKit 5.7.1 及传递依赖；其默认 manifest 要求 Swift 6.2+，当前使用 Swift 6.4 编译通过。

可信 JWKS 必须由已配置控制面提供，不能采用 token 的内嵌公钥、jku/x5u 或客户提交的信任目录。配置固定 HTTPS issuer 与持久 serverId，JWKS 最多 64 KiB/16 个公钥、kid 唯一，只允许 EC/P-256/ES256/sig 公钥字段，拒绝私钥；信任快照有明确到期时间（最长 300 秒，后续拉取应遵守服务器 60 秒缓存头）。过期快照拒绝验签，不能无期限离线使用缓存密钥。

验证 token 最多 32 KiB，固定 header alg/typ/kid，拒绝其他头字段、未知 kid、非规范 Base64URL。签名通过后核对精确 issuer/aud、UUID 身份、cnf.jkt、binding/entitlement version、iat/nbf/exp；不得接受超过 300 秒期限、尚未生效或已到期凭证。范围只允许标准 scope 和严格 runtime / workspace-registered 两类结构，拒绝未知字段、通配 ID 和未支持 Agent 策略。基础 server.identity 必须无资源，付费 scope 必须有范围。

验证证据：6 项组件测试及 4 项现有开发授权回归通过。包含 Ruby ruby-jwt 3.3.0 签发的 ES256/JWKS 样例，Swift 验证其身份、版本和资源；样例使用虚构 UUID、固定测试时钟，私钥已丢弃，不连接实际服务器/账户。

此组件仅证明云签名与声明校验。HTTP exchange、TLS/可信 JWKS 获取与轮换、本机持久绑定/ACL 求交、设备 DPoP/nonce/replay、jti 单次消费、生产 principal 和 SSE 持续撤销校验仍待接入。现有 HTTP 会话继续使用显式开发授权，云签名通过不能直接开放业务入口。


### 2026-10-03：设备 DPoP 验证组件（HTTP 集成待完成）

`RemoteDPoPVerifier` 根据 [RFC 9449](https://www.rfc-editor.org/rfc/rfc9449.html#section-4.3) 验证 ES256 的 `dpop+jwt`。只允许头部 alg/typ/jwk；拒绝 none/HMAC、私钥字段、远端 key URL 和错误类型。内嵌 EC/P-256 公钥按 RFC 7638 规范字段生成 SHA-256 指纹，必须与云凭证 cnf.jkt 完全相同；验签使用 JWTKit。

本资源服务器 profile 必须提供 jti/htm/htu/iat/ath/nonce。ath 绑定当前呈现 token 的 SHA-256/Base64URL，不允许把一个 token 的证明用于另一个。请求方法精确匹配，iat 与检查时间相差最多 30 秒。htu 要求 HTTPS、无凭证、无 query/fragment；与实际请求 URI 比较时忽略请求 query/fragment，并规范化 scheme/host 大小写、443 默认端口和空路径。路径仍精确匹配。目标地址由未来 TLS HTTP 服务的可信上下文提供，不能信任手机传来的 Host/X-Forwarded-* 作为校验依据。

服务端 nonce 为 32 字节随机值，绑定设备指纹，期限不超过 60 秒及调用方提供的 access/grant 到期；缓存只保存摘要。允许 nonce 用于多个不同 proof，jti 必须逐 proof 唯一。按设备指纹+jti 缓存最近 60 秒重放编号，最多 4096 项；nonce 最多 1024 项，满载拒绝新项，不提前丢弃有效记录。验签 await 返回后重新原子校验 nonce/replay，防止并发副本同时通过。设备撤销清除该设备 nonce，保留近期 replay；进程重启清空 nonce 后旧 proof 也不可直接复用。云 grant 的 jti 一次性消费仍需另设持久账本，不与 DPoP proof jti 混用。

验证：DPoP 8 项、云验签 6 项、原开发授权 4 项测试全部通过。覆盖公钥/签名错误、错误方法/地址/token/time/nonce、nonce 期限/撤销、查询与默认端口规范化、8 个并发副本只有 1 个通过、坏签名不能占用正常 jti、超大 proof 与 nonce 满载保护。

尚未接入 HTTP `DPoP`/`DPoP-Nonce` 头、重复头拒绝、TLS、本机绑定/ACL、持久 grant jti 消费、production principal 或 SSE 持续撤销。组件通过不代表生产接口已经支持设备授权。HTTP 集成必须在验证 DPoP 前后检查 access/grant 到期与本机绑定版本；DPoP 本身不保护请求正文，仍必须使用 TLS。

### 2026-10-03：持久本机授权账本（HTTP 集成待完成）

`RemoteAuthorizationLedger` 将桌面主人批准的用户/设备公钥指纹、云绑定版本、权限及资源范围保存到 SQLite。数据库固定 serverId，文件权限 0600，采用 WAL、FULL 同步及 IMMEDIATE 事务；最多 1024 个绑定（撤销记录仍占容量）、10000 个未过期交换记录，满载拒绝新授权，不驱逐有效授权。

`approve` 仅供可信本机批准流程使用，通过 expectedLocalVersion 防止过期 UI 覆盖新配置。每次批准或撤销递增本机版本，已有交换回执随即失效；同一云版本不能修改设备公钥、清除/替换已固定的云绑定 ID，撤销后恢复要求更高的云版本。后续主机批准 UI 不得将手机请求直接传给此入口。

云 JWS 与设备 DPoP 验证成功后才能调用 `consume`，事务内再次核对主机、用户、设备公钥、绑定版本、权限及资源求交。首次消费固定云 bindingId，并保存 grant jti、声明摘要、accessId、期限及授权范围；同一 jti 的相同声明重试返回原回执，不延长期限，声明或本机版本改变则拒绝。不保存原始 grant、proof 或 access secret。持久时钟下界拒绝回退时间恢复已失效凭证。

`validate` 用于后续每次 HTTP 请求及 SSE 帧发送前核对持久回执和当前本机授权，拒绝过期、撤销、修改及伪造回执。它尚未连接 HTTP 鉴权；accessId 也不是可直接使用的 Bearer token，生产 access secret/设备绑定 principal、交换路由、TLS、云撤销消费及原生钥匙桥仍待实现。

验证：账本 7 项、云验签 6 项、DPoP 8 项、开发授权 4 项通过。覆盖重启后的幂等交换、撤销持久化、批准版本冲突、权限/资源拒绝扩张、绑定 ID 固定、容量及时间回退；两个独立账本 actor 的 8 个并发交换返回同一个 accessId。

### 2026-10-03：正式 grant/access 交换与鉴权服务（HTTPS 路由待接入）

`RemoteGrantExchange` 已连接云 ES256 验签、设备 DPoP、本机持久批准与 grant 消费。`exchangeNonce` 校验云 grant 后发出设备限定挑战；`exchange` 要求 POST `/api/v1/remote/access/exchange` 的 proof，绑定 grant 的 ath。成功生成 32 字节随机短期 secret、`tokenType=DPoP` 和会话服务共用的 principal，期限完全沿用 grant。凭证最多 128 项，secret 仅留在内存用于同一次成功交换的幂等响应；进程重启使旧 secret 失效，设备需以新的 proof 重试交换。

业务 `authenticate` 要求 `Authorization: DPoP <access>`，拒绝 Bearer 与浏览器 Origin；proof 精确绑定 access、方法及路径，每次请求使用新的 jti。目标主机来自初始化时固定的 HTTPS endpoint，不能从未验证的 Host/Forwarded 头获取。`accessNonce` 只发挑战、不构成业务认证。生产 Web 是否可用不由这套服务推断；平台身份验证仍需由受信任的原生入口完成，缺失时不得开放交换路由。

资源解析必须由可信本机注册与工作区映射提供。runtime 条目再检查 agentId/runtimeId 精确匹配；workspace 条目要求解析器只返回该已批准工作区的注册资源。标准 scope 转为 RemoteAction 后，业务仍与 adapter/runtime/session 当前能力求交。现有 access 固定其已解析的范围，注册资源改变时旧 principal 被拒绝；新 Agent 可沿已批准 workspace 范围取得新 grant/access，严格 runtime 授权不扩张。workspace 真实映射实现尚待接入。

`RemotePrincipalValidator` 将 SSE 的每帧授权检查与开发凭证来源解耦，开发 store 和正式 exchange 服务均实现此接口。正式 validate 在资源解析前后检查持久回执、本机版本、撤销及到期。`revoke` 仅撤销当前 access；账本将其 grant jti 标记为不可再次交换，保留到原期限，重启后也不能复活。设备绑定仍保留，可申请全新的云 grant。

本次联验发现并修正 Agent ID 契约：agentId 使用 descriptor 规则 `^[a-z][a-z0-9._-]{0,127}$`，允许实际 `agent.chatgpt`；runtimeId/workspaceId 继续使用 `^[A-Za-z0-9_-]{1,160}$`。TomoServer 的绑定/grant 校验及样例同步更新。

验证：交换服务 6 项、账本 8 项、云验签 6 项、DPoP 8 项、开发授权 4 项、实际会话 HTTP/SSE 5 项共 37 项通过；TomoServer PostgreSQL 全量 61 项/490 断言通过。交换服务采用实际 P-256 签名验证完整链路，覆盖错误设备、缺失本机批准、重试、Bearer/Origin 拒绝、scope/runtime 扩张、access 与绑定撤销及 runtime 撤下。现有 HTTP 测试仍使用开发凭证，不能视为正式 TLS 网络联验。HTTPS listener/路由、可信本机批准 UI、平台与原生密钥桥、工作区映射和云撤销消费仍待完成。

### 2026-10-03：本机工作区与 runtime 授权映射

`RemoteRuntimeScopeRegistry` 维护可信本机登记的 workspace/runtime。workspace 只公开不透明 ID；路径留在本机，登记时固定规范根目录及设备号/inode。每次解析拒绝根目录替换、符号链接改变或已撤销的工作区。最多 128 个工作区（含当前进程中已退役 ID）、1024 个 runtime；撤销工作区同时撤下关联 runtime，不允许复用已退役 ID 扩大旧 grant 的范围。持久化工作区配置及跨重启的退役记录仍须接入主机批准流程；恢复配置不能将旧 ID 指向新目录。

注册 runtime 时可选 workspace 句柄仅由本机可信 adapter 提供，并且要求该 runtime 的全部会话确实隔离在对应项目中。ChatGPT 的主机级历史索引可能包含多个项目，不能将其存储目录误当成工作区；现有 `MobileSyncManager` 注册此索引时不传 workspace。未隔离的索引只能通过严格 runtime 条目访问。

`resolve` 对严格 runtime 精确匹配完整 agentId/runtimeId；workspace 的 registered 策略动态纳入该已批准工作区的新注册 Agent，其他工作区和主机级 runtime 不纳入。重复资源去重，动作与 descriptor 当前声明求交，未知资源返回空范围。每个 runtime 注册具有独立租约，旧租约不能撤下替代注册。`RemoteGrantExchange` 可直接使用此注册表解析批准范围；已存在的 access 仍固定其交换时的范围，发生变化时需重新取得 access。

`RemoteReadService` 实际注册及撤下 adapter 时同步授权注册表，撤下后清理该资源分页游标。列表/历史的异步读取保留并核对来源租约，读取过程中撤下或同 ID 替换均拒绝返回旧数据。catalog/session adapter 的 descriptor 在本服务进程内保持一致，撤下最后一个 runtime 后可重新登记同一 descriptor。

验证：映射 6 项、交换 7 项、目录 4 项、MobileSync 22 项、会话 HTTP/SSE 5 项共 44 项通过。完整 ES256/DPoP/本机批准链验证了“先签发工作区 grant，再注册新 Agent，交换时获得已批准范围”；验证主机级索引排除、严格范围不扩张、目录替换/符号链接拒绝、撤销与退役 ID、租约替换，以及列表和历史的读取中撤下。尚未实现主机批准 UI/持久工作区配置、正式 HTTPS listener、平台密钥桥及云撤销消费，生产验收保持未完成。

### 2026-10-03：正式授权 HTTP 请求边界（尚未挂载端口）

`RemoteProductionAccessRouter` 将授权生命周期与业务 principal 的校验分开，采用保留重复项的原始 header 列表，不接受先压平后的重复认证头。拒绝大小写变化的重复 header、CR/LF/NUL 字节、超限 header/body、非法路径及 query 中 token/access_token/grant/dpop/authorization。Origin 请求返回 403，不提供浏览器 CORS 开放。

| 方法 | 路径 | 输入 | 返回 |
| --- | --- | --- | --- |
| POST | /api/v1/remote/access/exchange/nonce | application/json `{grant}`；无 Authorization/DPoP | 200，DPoP-Nonce 头；不签发 access |
| POST | /api/v1/remote/access/exchange | application/json `{grant,clientCapabilities}`；DPoP proof 头 | 201，serverId/accessId/accessToken/tokenType/expiresAt/negotiatedProtocol |
| POST | /api/v1/remote/access/nonce | Authorization: DPoP access；空正文/query，无 proof | 200，DPoP-Nonce 头；不构成业务认证 |
| DELETE | /api/v1/remote/access/current | Authorization: DPoP access、DPoP proof；空正文/query | 204；持久禁止旧 grant 再次交换 |
| 业务路由 | /api/v1/remote/... | Authorization: DPoP access、绑定方法/路径/token 的 proof | 校验后的 principal，再交给现有目录/会话/操作服务 |

交换正文当前只接受 grant 与 clientCapabilities 字段（nonce 正文仍仅 grant），最多 40 KiB；拒绝客户端 vip/app 等额外声明。交换及其 nonce 必须调用集成方提供的可信原生平台验证器，没有默认放行实现。该依赖必须使用真实 App 身份验证，不能将 Origin、User-Agent 或 bridge 布尔标记视为平台证据；测试中的空验证器仅为合成 fixture。错误正文/重复头返回 400，无权 403，凭证失败 401，验证器或服务不可用 503；错误不包含内部异常/凭证，全部响应禁止缓存。平台验证的异步耗时计入凭证时间检查。

验证：交换/路由 9 项、持久账本 8 项、云签名 6 项、DPoP 8 项、开发授权 4 项、既有实际 HTTP/SSE 5 项共 40 项通过。新增路由测试走真实签名的 nonce→exchange→业务鉴权→DELETE→旧 grant 拒绝，覆盖重复头、URL 凭证、Origin、CRLF、错误方法/媒体类型/JSON/额外字段及平台验证器不可用。

这些是请求边界和签名链测试，尚未启动正式 HTTPS listener，也未修改旧明文 MobileSyncServer 的认证方式。后续必须完成 TLS 证书/固定目标上下文、云登记 UUID 与本机主机身份对齐、原生平台验证和密钥桥、clientCapabilities 协商，再挂载正式入口并进行 App 网络联验；此阶段不代表正式端口已可访问。

### 2026-10-03：客户端协议协商与 access 绑定

正式 exchange 必须显式传入 clientCapabilities，不推断客户端能力，也不默认放行缺失字段。对象只允许 descriptorMajors/apiMajors/eventMajors/contentMajors/clientFeatures；每组版本为 1..8 个不重复的正整数（最大 1000），特性最多 32 项、不重复且符合标识规则。数组排序后绑定到 access，等价顺序不产生不同协议；重试不能替换现有 access 的声明，validate 也核对捕获的声明。

```json
{
  "grant": "ES256 云凭证",
  "clientCapabilities": {
    "descriptorMajors": [1], "apiMajors": [1],
    "eventMajors": [1], "contentMajors": [1], "clientFeatures": []
  }
}
```

当前已实现 API/event/content v1，三者必须有交集，成功返回 negotiatedProtocol `{apiMajor:1,eventMajor:1,contentMajor:1}`；无交集返回 426 protocol_incompatible，非法结构/布尔版本/重复声明返回 400。不要因为客户端宣称更高版本就提升服务端实际实现版本。exchange nonce 正文保持 `{grant}`。

注册表按 descriptor schema、Agent 的协议版本及 requiredClientFeatures 逐个求交。不兼容 Agent 保留仅供目录提示的资源条目，actions 为空；目录返回最小 incompatible 项、无完整 descriptor/可访问 runtime，直接 sessions/history 也无权。其他兼容 Agent 正常显示。RemoteReadService 使用 access 绑定的客户端能力生成目录，不再对正式 principal 固定假定 v1 能力。TomoGo 会话目录提示需要升级，并禁用不兼容条目。

验证：桌面交换 11 项、runtime 映射 6 项、Agent 注册 6 项、目录 4 项、HTTP/SSE 5 项、开发授权 4 项共 36 项通过；Web RemoteClient 10 项通过，Web 构建通过并同步到 iOS/Android WebCore。新增真实签名测试验证缺少必需特性时没有会话权限，声明支持后才可读取兼容目录，现有 access 的声明替换拒绝，以及 HTTP 426/400。仍未完成 TLS listener、App 身份/密钥桥、持久主机批准和生产网络联验。

### 2026-10-03：独立 HTTPS 授权传输层

`RemoteHTTPSListener` 已实现，按调用方提供的 `RemoteTLSIdentity`、`RemoteProductionAccessRouter` 与业务处理器启动独立 Network.framework TLS 服务。端口取自 exchange 固定 endpoint（缺省 443），可显式限制绑定地址。最低 TLS 1.2，仅提供 HTTP/1.1；初始化检查证书与固定目标主机匹配，监听器不根据 Host/Forwarded 改写 DPoP 目标。IP 与域名访问需要证书包含相应 SAN，客户端必须独立验证信任与主机名。证书身份的配置方式参考 [Apple 本地网络 TLS 身份说明](https://developer.apple.com/documentation/network/creating-an-identity-for-local-network-tls)。监听器不生成生产私钥、不安装根证书，也不自动修改系统信任。

授权路由处理 exchange nonce/exchange/access nonce/current 撤销；其他请求先验证 principal，再调用注入的业务处理器，并在返回数据前重新验证授权。集成方应使用同一 server UUID 和 runtime 注册表连接 `RemoteReadService` 等能力服务，处理器继续执行具体资源/动作检查。不能将任意闭包或测试请求头当作 App 身份验证器。旧明文 MobileSyncServer 保持独立，不挂载正式交换路由。

请求保留原始重复头，不接受绝对 URL、双斜杠 authority、路径百分号编码歧义、fragment、解码后重复 query；有限帧解析拒绝 chunked、冲突 Content-Length、未完成正文和流水线多请求。请求头上限 16 KiB、正文上限 1 MiB、exchange 正文上限 40 KiB；一次连接仅处理一个请求并关闭。最多 64 个连接/仍运行的处理任务，启动和单次请求期限均 15 秒，响应正文最多 4 MiB，全部强制 no-store/no-cache。忽略取消的处理器仍占用容量，不能通过重复断连无限启动处理任务。

验证：本次授权/传输/目录/会话回归共 **66 项通过**（XCTest 43，Swift Testing 23）。真实 HTTPS 测试完成平台 fixture 拒绝、Origin 拒绝、nonce→签名交换→实际目录服务→DPoP 重放拒绝→持久绑定撤销后的拒绝访问；明文连接和不可信客户端证书锚均被拒绝。另验证本机证书与配置主机不匹配时无法构造监听器，以及请求解析歧义。测试证书仅在临时目录和进程内存中使用，结束后删除；内存 PKCS12 测试导入要求 macOS 15+，监听器本身仍以 macOS 14 为目标。

这是可注入并经过真实网络验证的传输组件，尚未由正式 App 生命周期启用。当前业务响应为有限 JSON，TLS SSE 流式转发、正式 CA/证书配置流程、云登记主机身份持久化、真实 App 平台证明/密钥桥、本机批准 UI、云撤销消费及 App 真机联验仍待完成。测试使用合成云/设备密钥和显式 fixture 平台验证器，不代表正式 App 身份已经验收。

### 2026-10-03：HTTPS 会话快照与 SSE 接入

HTTPS listener 可注入同一 server UUID 的 `RemoteSessionService`，直接处理 GET `/api/v1/remote/sessions/{sessionId}/sync` 和 GET `/api/v1/remote/sessions/{sessionId}/events`。两者要求空正文，并沿用 `agent_id`/`runtime_id` 的完整资源检查。events 需要 `Last-Event-ID` 或 `after` 游标；同时提供时必须相等。缺失/冲突游标 400，过期游标 409，资源越权 403、未登记会话 404；错误均在流式响应头发送前处理。未配置会话服务返回 501，不回落到旧服务。

建立事件订阅后再次验证 access/绑定/runtime，并复用 `RemoteSSEConnection` 逐帧授权和 journal 回放。正式 TLS 流不发送浏览器 CORS 放行头；初始请求仍要求绑定方法/路径/access 的 DPoP 和新 jti，重连必须获取并使用新的 proof。存活流每秒检查授权与来源，过期/撤销发出 access.revoked 后关闭，流内的终止信号不能用作持久回放游标。客户端断开立即取消订阅，服务 stop/释放也取消流及连接。JSON 建立阶段保留 15 秒期限，成功交接给 SSE 后取消该期限；SSE 继续保留发送超时及授权期限。最多 32 个流，且占用总连接容量。

JSON 响应上限改为 **17 MiB**，覆盖 journal 允许的最大 16 MiB projection 与 sync 的有限封装字段；先前 4 MiB 上限会拒绝合法历史快照。真实 TLS 测试使用超过 5 MiB 的正文快照，验证完整返回，然后从旧游标回放、断开并用实际事件游标重连，序列 1→2→3 连续且不重复，最后撤销本机持久绑定收到 access.revoked 并释放订阅。另覆盖空闲客户端取消、缺失/冲突/过期游标、runtime 越权及无 CORS 头。

最终相关回归 **67 项通过**（XCTest 44、Swift Testing 23），包含云签名、DPoP、持久授权、TLS 目录/会话、runtime 注册、请求帧与既有开发 HTTP/SSE。TLS SSE 组件完成网络联验，正式 App 生命周期、真实原生平台/密钥桥、云主机身份/证书配置、本机批准 UI、云撤销消费和真机验证仍未完成。本阶段未提交代码。

### 2026-10-04：云签名原生平台回执

正式 HTTPS 交换和 nonce 请求增加 `X-Tomo-Platform-Receipt` 头。云端签发 `tomo-platform-receipt+jwt`，声明绑定当前用户、设备、公钥摘要、serverId/grantId 与具体 HTTP 请求。桌面 `RemoteCloudGrantVerifier.verifyPlatformRequest` 只使用显式配置的云 ES256/JWKS/kid，拒绝自带密钥地址、错误 JWT 类型、用户/设备/grant 不匹配、未知平台、非 production、过期或超过 60 秒的回执。`RemoteProductionAccessRouter.cloudVerified` 提供挂载该验证器的构造入口，仍要求 grant、设备 DPoP 和本机持久 ACL。

请求摘要为 SHA-256：LF 连接 `tomo-platform-http-v1`、serverId 小写 UUID、grantId 小写 UUID、`POST`、固定交换路径、SHA-256(原始 body) 的规范 Base64URL，无末尾 LF。只接受 `/api/v1/remote/access/exchange/nonce` 与 `/api/v1/remote/access/exchange`；正文或路径变化必须重新取得相应回执。平台回执不增加 scope，不取代会员或桌面批准。

TomoServer 的 `POST /api/v1/remote/platform-receipts` 要求已成功验签的 assertion 与当前活跃 grant/登录/设备/绑定/VIP匹配，签名期限不因重试延期；每次证明的应用版本和分发类别独立保存。完整协议见 TomoGo `docs/native-platform-receipt.zh-CN.md` 与 TomoServer `docs/platform-receipts.md`。

### HTTPS 桌面绑定请求与审批回执

`RemoteHTTPSListener` 显式注入 `RemoteBindingRouter` 后提供以下配对通道；默认不挂载，旧 plaintext 服务不提供。该通道不授予业务权限，桌面批准/拒绝只可由本机 owner 调用。

| 方法 | 路径 | 身份与输入 | 成功输出 |
| --- | --- | --- | --- |
| POST | `/api/v1/remote/bindings/nonce` | JSON 仅 `identityAssertion`，云签名 `tomo-binding-identity+jwt` | 200 `nonceRequired:true`，`DPoP-Nonce` 头 |
| POST | `/api/v1/remote/bindings/requests` | 相同 JSON；设备 DPoP 的 ath 绑定断言、htm/htu 绑定精确 HTTPS 请求 | 202 `status:pending/requestId/expiresAt` |
| GET | `/api/v1/remote/bindings/requests/{challengeId}` | `Authorization: DPoP {identityAssertion}` 与新设备 DPoP；仅原断言可查询原挑战 | 200 pending，或 approved 含桌面签名 `receipt`；拒绝为 403 rejected |

云断言校验固定 ES256/JWKS/kid、服务器/用户/设备/公钥摘要/挑战/nonce/版本/短时限与严格 schema。Origin、重复头、查询参数、手机提交权限字段、错误设备、证明重放或跨挑战查询失败；所有响应 no-store。查询回执前重新校验云信任期限。设备 DPoP 只证明持有密钥，不代替平台证明、会员、grant 或本机 ACL。

本机 `RemoteBindingApproval` 有界存放待审批项。owner 显式选择 scopes/resources，经当前云信任检查和持久 ledger CAS 后返回 `tomo-binding-receipt+jwt`，用已登记服务器密钥签名，原样重试不重复增加本机版本。Swift 签名回执已由实际 Rails 绑定服务验收。Settings 审批 UI、Keychain 服务器身份、生产 listener 生命周期及原生云绑定回传仍未完成；此接口当前为实现和测试状态，不能据此宣称已在运行桌面产品中启用。

当前为云签发及桌面验签边界实现，尚未由实际 App 的 HTTPS 生命周期挂载，原生请求签发协调与真实云/真机/Agent 会话仍待联调。此项不得视为生产交换入口已开放或整链路完成。

### 2026-10-04：正式服务装配与原生 Settings 启停

上述段落记录早期实现阶段；当前源码已由 `RemoteProductionService` 装配正式 HTTPS listener、云 JWKS 维护、设备 DPoP、平台回执、持久 ACL、配对、真实会话目录和命令服务。生产命令 owner 来自验证后的云 user/device 回执，未经注册的执行 source 不提供控制能力。

桌面 Settings 的「TomoGo 安全会话服务」提供本机专用配置：先登录并登记 Mac，显式读取已有 Keychain TLS 身份，选择证书、HTTPS 对外地址与 ChatGPT 会话目录，再启动。只显示证书名称和 SHA-256 指纹，不导出 TLS 私钥；证书不自动选取、监听不自动恢复。用户选择的目录要有可读 `state_5.sqlite` 或 `sqlite/state_5.sqlite`，否则启动失败。默认目录只发布 `sessions.list`、`history.read`，不能据此声称支持消息发送。

这些配置不是 HTTP API，也不接受手机提交的 TLS 身份、本机路径或批准权限。退出账号、更换云配置、重新登录/登记或当前登记失效会停止旧服务。取消启动后迟到的服务被关闭；监听失败/状态中断清除可用地址。停止清除内存 access、HTTP/SSE 和命令 admission，不删除持久 ACL。

最终相关回归为 51 项 XCTest + 7 项命令 Swift Testing，包含真实回环 HTTPS/ES256、SQLite 默认目录和异步启停竞争。云 HTTP、manager host 与证书目录测试使用替身，没有操作用户 Keychain。Settings 实机渲染、生产证书、owner 审批/撤销 UI、真实云/Apple/Android、live Agent 会话闭环与新版 Release 打包仍待验证。完整跨项目 Goal 继续执行。

### 2026-10-04：本机 owner 设备授权入口

当前源码进一步接入原生「移动设备授权」设置，运行服务期间查看待配对云身份与持久 ACL、选择明确 runtime、批准/拒绝及撤销设备。资源默认不选，控制权限默认关闭；当前 ChatGPT 目录只支持 discovery/session.read，发送与批准动作仍需实际注册的执行 source。Settings 显示设备公钥摘要与本机版本，不持有 HTTP owner 权限，不返回原断言、批准回执或私钥。

owner 操作限原生调用：`ownerState`、`ownerApprove`、`ownerReject`、`ownerRevoke`。只有当前 registry 中的资源可选择，批准/撤销使用 localVersion；界面操作携带 service lease，旧服务页面不能操作重启后的服务。没有手机可调用的 approve/revoke HTTP 路由。

撤销持久 binding 并递增本机版本，旧 grant/access 的后续 ledger 校验失败。配对查询和批准重试也检查当前 ACL，撤销后不再返回缓存的批准 receipt。50 项 XCTest + 7 项命令回归通过；另 3 项装配测试验证了 manager 的实际服务批准/撤销，并在真实 TLS 请求中确认 fresh DPoP 配对查询仍返回 403 且不含旧 receipt。云邮件/JWKS 为替身，没有验证真实云回传或实际原生 Settings 交互；完整 native/Agent 控制闭环仍未完成。

### 2026-10-04：正式服务受控 runtime

运行中的原生 owner 设置可从本机真实 ChatGPT 目录选择会话及 CLI，启动独立账号 stdio 进程，resume 后读取 baseline，再发布单会话 runtime/journal/command source。`ownerAttachChatGPT`、`ownerDetachChatGPT` 只供原生调用，没有接受 executable/home/vendor thread 的远程 HTTP 接口；同一账号同一 thread 不能重复接管。原目录动作仍限于 sessions.list/history.read，Agent 潜在能力不会扩大其权限。

默认不允许追加消息。明确开启 allowSteer 后也只对当前活动且没有待回复请求的回合发布 message.send；turn.interrupt 同样必须有当前回合。手机仍需通过现有云身份、平台回执、grant、设备 DPoP 和本机 ACL 链路，接管不自动批准任何设备。**原有空闲会话**的新回合发送仍未开放。停止、取消、迟到启动和进程断线撤回控制，原生刷新清理断线目录。

桌面另有明确的“创建独立新会话”入口：owner 选择本地账号、CLI 与工作区，在专属进程执行 `thread/start`（`ephemeral: true`），且仅在回执确认临时、无路径、工作区一致并读取空闲元数据后注册独立 runtime/session。该 runtime 绑定工作区，目录和历史读取 Tomo journal；只有此来源的空闲状态可发布首次 `message.send`，不扩张原历史目录或接管旧会话的能力。停止后临时 vendor thread 无法续接。已完成真实 CLI 空会话初始化和合成事件/操作账本回归；真实模型回复、手机授权与真机操作尚未验收，详见 [独立临时新会话方案](remote-ephemeral-new-session-plan.md)。

19 项 XCTest + 29 项 Swift Testing 回归通过，包含真实 stdio 合成进程的追加消息→回复事件→sync→applied，以及停止期间迟到进程的清理。另显式运行本机 codex-cli 0.153.4，隔离合成已完成历史的恢复、索引、真实 HTTP/SSE 和停止测试通过。这些证据没有调用模型，也不证明真实云/设备/模型或原生设置交互的完整闭环。

### 2026-10-04：Android Play Integrity 回执

同一 `X-Tomo-Platform-Receipt` 支持云端经过 Google Play Integrity 判定的 Android 回执。Android 声明 `platform=android`、`environment=production`、规范正整数 versionCode（JWT 的 version 字段，最多 2100000000）及 `deviceIntegrity=MEETS_DEVICE_INTEGRITY`，不得包含 Apple category。iOS 回执必须具有允许的 category，不得包含 deviceIntegrity；未知或混合字段拒绝。云端核对 Google 包名/发布证书/版本允许列表、挑战会话设备和精确 server/grant/业务请求摘要，签发仍受当前 grant、binding、VIP 与权限版本事务控制。

桌面增加 Android/iOS 互斥字段检查后继续验证云签名、issuer/audience/设备公钥绑定、原请求体与固定交换路径，以及最多 60 秒/不超过 grant 的时间边界。平台验签与云 grant 共 11 项 XCTest 通过；该证据不包含真实 Google/Play 安装或 Android 原生宿主闭环，后者仍需接入和真机验收。
