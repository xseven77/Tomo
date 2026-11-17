# 远程服务云验签信任维护

正式监听器使用同一云验签对象处理 grant、平台回执与绑定断言。现有固定五分钟 trust deadline 必须由原生生命周期维护，不能扩大为永久信任。

从显式配置的 HTTPS issuer 固定 `/.well-known/jwks.json` 获取 JWKS，不附登录凭据、不接受 token 中的 URL、不允许重定向或非系统 TLS。响应最多 64 KiB，限定 JSON、ES256 P-256 公钥和受限 kid。保留最多五分钟期限，后台按期限中途刷新；更新失败只保留原有限期，过期关闭授权。停止维护时立即失效验签对象，迟到请求不能复活信任。

轮换必须替换公钥集合，不能无限累加退役 key。验签跨 await 后复核信任代次与单调时钟推导的期限；换钥/失效时在途旧 key 结果拒绝。此组件先独立测试，再由正式 HTTPS 监听 manager 启停，仍需实际监听与本机审批 UI 装配。

## 当前实现与验证

RemoteCloudTrust 从固定 HTTPS issuer 取 JWKS；默认配置上限 120 秒、绝对上限 300 秒，服务响应 max-age 可进一步缩短，Age 和请求网络耗时扣除可用期限。按剩余期限中途刷新，失败后 15 秒重试但不修改旧期限；停止时取消维护并使同一个验签对象立即失效。所有 token 类型在 JWTKit await 后复核代次、单调耗时与过期时间。更新完整替换集合，包括 same kid 换 key 的情况。

最终 `swift test --filter 'RemoteCloudTrustTests|RemoteCloudGrant|RemotePlatformReceipt|RemoteBindingApproval|DesktopCloud'` 36 项通过，其中 5 项新信任维护测试，包含真实 ES256 旧/新签名、替换后旧 key 拒绝、到期拒绝、刷新失败、停止期间迟到 fetch、缓存 Age、无效 JWKS/缓存字段和网络耗时期限。HTTP 为测试替身，未访问生产云；默认 URLSession 的 TLS/重定向策略沿用桌面会话传输。

目前组件尚未由 Settings 正式监听 manager 持有和启动。现有 RemoteHTTPSListener 的真实回环 TLS/授权测试是其他阶段证据，不能替代本次维护组件接入运行后的验收。仍需 TLS 身份选择/生命周期、真实 runtime 资源装配、owner 审批与撤销 UI、退出时停止监听，最后用真实 HTTPS 和原生设备验证会话闭环。
