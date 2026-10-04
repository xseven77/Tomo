import Foundation
import Observation

@MainActor
@Observable
final class ApiDocsManager {
    static let shared = ApiDocsManager()
    private(set) var status: ApiDocsServer.Status = .stopped
    private var server: ApiDocsServer?
    private var configuredPort: UInt16
    private var configuredLAN: Bool
    private init() {
        let saved = UserDefaults.standard.integer(forKey: "tomo.apiDocs.port")
        configuredPort = (1...65535).contains(saved) ? UInt16(saved) : 58351
        configuredLAN = UserDefaults.standard.bool(forKey: "tomo.apiDocs.allowLAN")
    }
    var port: UInt16 {
        get { configuredPort }
        set {
            guard !isActive, newValue > 0 else { return }
            configuredPort = newValue
            UserDefaults.standard.set(Int(newValue), forKey: "tomo.apiDocs.port")
        }
    }
    var allowLAN: Bool {
        get { configuredLAN }
        set {
            guard !isActive else { return }
            configuredLAN = newValue
            UserDefaults.standard.set(newValue, forKey: "tomo.apiDocs.allowLAN")
        }
    }
    var isActive: Bool { status == .starting || status == .running }
    var localURL: URL { URL(string: "http://127.0.0.1:\(port)/")! }
    var lanURL: URL? {
        guard allowLAN, let ip = GatewayNetworkInfo.currentLANIPv4() else { return nil }
        return URL(string: "http://\(ip):\(port)/")
    }
    func start() {
        guard !isActive else { return }
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("ApiDocs", isDirectory: true) else {
            status = .failed("未找到打包的 API 文档资源。"); return
        }
        do {
            let server = try ApiDocsServer(directory: directory, port: port, allowLAN: allowLAN)
            self.server = server
            server.onStatus = { [weak self, weak server] status in
                guard let self, let server, self.server === server else { return }
                self.status = status
            }
            server.start()
        } catch {
            self.server = nil; status = .failed("文档服务无法启动：\(error.localizedDescription)。请检查文档资源和端口占用。")
        }
    }
    func stop() { server?.stop(); server = nil; status = .stopped }
}
