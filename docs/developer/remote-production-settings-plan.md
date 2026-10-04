# 正式远程服务设置与启停

桌面原生 Settings 显式选择 Keychain 中已有的 TLS 身份、HTTPS 对外地址和本机 ChatGPT 会话目录；不创建或安装用户根证书，不导出 TLS 私钥，不自动打开监听，不提供测试默认身份。证书名称和 SHA-256 指纹供选择，身份仅存在原生内存引用。目录来自本机用户选择，不能由手机请求注册。

RemoteProductionManager 管理 starting/running/stopping/failed 与请求代次，监听实际状态流。启动中停止/退出取消任务，迟到服务必须立即停止，不覆盖新状态。配置变更、云重新登记/换登录及退出要停止原服务；UserDefaults 只保存云地址，TLS 选择与服务不自动恢复。

先实现 TLS catalog、真实目录适配器、设置启停入口与退出钩子，使用可注入证书/服务测试状态竞争，并继续保留真实 TLS 装配回归。下一阶段接 owner ACL 审批/撤销和实际 live runtime 生命周期，完整原生会话闭环仍需验证。

## 2026-10-04 实现与验证

Settings 的移动端分区已接入 RemoteProductionSettingsView：HTTPS 地址、已有 TLS 身份名称/指纹、目录选择、显式启停和实际状态。KeychainRemoteTLSIdentityCatalog 仅在点击读取时查询身份引用，不导出私钥、不安装根证书。服务不自动恢复；当前目录适配器只声明 sessions.list/history.read。

DesktopCloudManager 在退出、清除云配置、重新登录、重新登记或刷新后登记变化时调用原生停止钩子。RemoteProductionManager 使用代次控制异步目录与启动结果，停止后到达的 host 被关闭。调用者取消、监听失败或状态流意外结束均清除运行投影；失败不会保留可用地址。无需向 WebCore 发布云登录凭据或 TLS 身份。

最终命令：`swift test --filter 'RemoteProductionManagerTests|DesktopCloudManagerTests|DesktopCloudSessionTests|RemoteProductionServiceTests|RemoteHTTPSListenerTests|RemoteGrantExchangeTests|RemoteOperationServiceTests|RemoteCloudTrustTests'`，51 项 XCTest + 7 项 Swift Testing 全部通过。9 项 manager 测试覆盖正常启动/退出、停止和退出时迟到服务清理、非法配置、调用者在目录/工厂等待期间取消、监听失败/流结束、真实 SQLite 默认目录及缺失目录拒绝。manager 的 host/云 HTTP/Keychain 目录为替身；同轮保留实际回环 TLS 装配测试和密码学校验。

未读取用户真实 Keychain，未验证实际 Settings 渲染、生产证书或真实云登记。尚缺 owner ACL 审批/撤销 UI、live runtime/journal/command source 生命周期、原生宿主配置与业务 RPC、真实设备与完整会话闭环；当前正式 Release 包没有更新。此证据不表示整项目完成。
