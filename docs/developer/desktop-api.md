# Tomo 桌面端开放 API

状态：首份开发草稿。核验基线：桌面源码 `e79c2eba10dce96a9188538711a3a75fdc5abc33`，Info.plist 0.8.3 / build 100，2026-09-18。

这是一套供用户开发自己应用的通用 HTTP API。Web / PWA、原生 iOS / Android 应用、其他桌面程序、CLI、脚本和服务端程序都可以接入，不需要安装为 Tomo Web 插件。

正式路由统一为 `/api/v1/`。旧 `/mobile/` 路由全部删除，不提供兼容或重定向；访问返回 410 / api_removed。所有使用旧路由的 Web Mobile 版本标记为失效，必须升级。v1 是 API 契约版本，与桌面版本和文档版本独立。

## 开发自己的应用

应用的基本配置是桌面服务 Base URL 和配对 Token。使用 HTTP 请求读取状态，使用 SSE 订阅变化；应用可以独立运行、独立发布，也可以部署在自己的服务器。桌面端承担数据源与代理角色，不要求第三方应用使用 React 或遵循插件包格式。

可开发任务看板、状态栏工具、工作时长展示、手机通知应用或自动化脚本。当前接口提供状态读取与代理能力，尚不提供任务控制。Web 浏览器需要考虑 CORS、混合内容和 EventSource 认证方式；原生或服务端客户端可使用 Authorization 请求头读取 SSE，CORS 不适用于这些客户端。

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

所有 `/api/v1/` 路由使用当前桌面服务的配对 Token，支持两种形式：

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

可传请求头 `X-Tomo-App-Name: My Application`，不传不影响调用。Mobile 默认传 `Tomo Mobile`。这是调用者自报的统计标签，不是可信身份，不参与认证。

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
| GET | `/api/v1/agents/discover` | 桌面 Token | 局域网内嗅探在线的 Tomo Agent 设备列表 |
| GET、POST | `/api/v1/proxy` | 桌面 Token | 桌面侧转发上游请求，缓冲响应 |
| GET | `/api/v1/pets` | 桌面 Token | 宠物元数据列表 |
| GET | `/api/v1/pets/{id}/spritesheet.webp` | 桌面 Token | 宠物精灵图 |
| GET | `/api/v1/credentials` | 桌面 Token | 导出启用账号的凭证 |
| GET、HEAD | `/` 及插件静态文件路径 | 无 | 已安装 Web 插件资源 |
| OPTIONS | 任意路径 | 无 | 跨域预检 |

当前没有任务启动、取消、审批、发送消息、历史任务查询、供应商统一刷新、服务能力查询或多插件管理 API。展示任务状态与控制任务是不同能力。

## 4. 健康检查

```sh
curl 'http://127.0.0.1:58350/health'
```

```json
{"status":"ok"}
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

通过 `/api/v1/pets/{id}/spritesheet.webp` 获取 `image/webp`；路径中的 id 应编码，并带桌面认证。先找用户 Pets 目录，再找 Plugins/pets 目录，没有资源返回 404。

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
