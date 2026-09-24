import Foundation

/// One model entry written into a DSH `llm-pi-ai` provider route.
///
/// DSH sizes a model from the entry itself because `/v1/models` publishes no
/// capacity metadata (only `id`/`name`/`owned_by`). Leaving the entry unsized
/// would silently adopt the adapter defaults (262,144 / 32,768), and an
/// over-claimed context is the expensive direction: the provider rejects the
/// request mid-turn, after the message is already durable, and the session
/// repeats a request that cannot succeed. Every entry therefore carries an
/// explicit, conservative size.
struct DSHModel: Equatable, Sendable {
    let id: String
    let name: String
    let contextWindow: Int
    let maxTokens: Int
    /// Accepted request modalities, rendered as the entry's `input` list.
    let input: [String]
    /// Selectable thinking levels, rendered as the entry's `reasoningEfforts`.
    let reasoning: [DSHReasoningEffort]
}

/// One selectable thinking level: the key the picker offers, and the wire
/// spelling dispatch sends for it.
struct DSHReasoningEffort: Equatable, Sendable {
    /// A pi-ai thinking level: `off`, `minimal`, `low`, `medium`, `high`,
    /// `xhigh` or `max`.
    let level: String
    /// The value sent in the protocol. `nil` means "send nothing", which DSH
    /// permits only for `off` — the correct dispatch where not thinking *is*
    /// the parameter's absence.
    let wire: String?
}

/// Thinking levels a gateway model may expose.
///
/// `reasoningEfforts` is the *only* source of reasoning metadata for a
/// hand-declared route: `resolveModelReasoning` falls back to the installed
/// catalog entry, and a gateway route has none, so `reasoning` resolves to
/// `false` and the picker offers no thinking control at all.
enum DSHModelReasoning {
    /// Convert an array of reasoning level strings (e.g. ["off", "low", "medium", "high"])
    /// into typed DSHReasoningEffort structures.
    /// `off` sends nothing (nil wire value), which DSH permits only for `off`.
    static func from(levels: [String]) -> [DSHReasoningEffort] {
        levels.compactMap { level -> DSHReasoningEffort? in
            let clean = level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !clean.isEmpty else { return nil }
            if clean == "off" || clean == "none" {
                return DSHReasoningEffort(level: "off", wire: nil)
            }
            return DSHReasoningEffort(level: clean, wire: clean)
        }
    }
}

/// Request modalities a gateway model may accept.
enum DSHModelModality {
    static let textOnly = ["text"]
    static let textAndImage = ["text", "image"]

    static func input(supportsImage: Bool) -> [String] {
        supportsImage ? textAndImage : textOnly
    }
}

/// Conservative capacity lookup for gateway model IDs.
enum DSHModelCapacity {
    static let fallbackContextWindow = ModelCapabilityRegistry.fallbackContextWindow
    static let fallbackMaxTokens = ModelCapabilityRegistry.fallbackMaxTokens

    static func resolve(modelID: String) -> (contextWindow: Int, maxTokens: Int) {
        let profile = ModelCapabilityRegistry.resolveCapability(for: modelID, override: nil)
        return (profile.contextWindow, profile.maxTokens)
    }
}

enum DSHGatewayConfigurationError: LocalizedError {
    case settingsUnreadable(path: String)
    case credentialsUnreadable(path: String)
    case unsupportedSettingsShape(detail: String)
    case legacyCredentialDocument(path: String)
    case noGatewayModel
    case invalidCredential
    case verificationFailed(key: String, expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .settingsUnreadable(let path):
            "无法读取 DSH 设置文档：\(path)"
        case .credentialsUnreadable(let path):
            "无法读取 DSH 凭据文档：\(path)"
        case .unsupportedSettingsShape(let detail):
            "DSH 配置文档结构不受支持（为避免破坏其他配置已中止）：\(detail)"
        case .legacyCredentialDocument(let path):
            "DSH 凭据文档 \(path) 仍是旧版扁平布局；请先启动一次 dsh 让它完成迁移，再重新接入。"
        case .noGatewayModel:
            "Gateway 当前没有已启用的可用模型，请先在“接入与模型”中开启至少一个账号代理。"
        case .invalidCredential:
            "Gateway 本地令牌为空，无法写入 DSH 凭据文档。"
        case .verificationFailed(let key, let expected, let actual):
            "DSH 配置校验失败：\(key) 应为 \(expected)，实际为 \(actual.isEmpty ? "<空>" : actual)。"
        }
    }
}

/// Result of reading the DSH documents, used both for the UI status and for
/// post-write verification.
struct DSHConfigurationState: Equatable, Sendable {
    var routePresent = false
    var baseURL: String?
    var apiKeyEnv: String?
    var modelIDs: [String] = []
    var credentialPresent = false

    var isConfigured: Bool { routePresent && credentialPresent }
}

/// Which document an edit belongs to; keeps the narrow editor honest about
/// permissions (the credential document is owner-only by contract).
private enum DSHDocumentKind {
    case settings
    case credentials
}

/// Writes the Tomo Gateway into DeepSeek Harness as a `llm-pi-ai` route.
///
/// DSH ships no CLI for settings or credentials (`dsh` boots a profile, `dsh
/// web` boots the web profile, `dsh plugin` forwards to pnpm), so the
/// documents *are* the integration surface — the same ones the DSH Models page
/// writes, both hot-reloaded by the harness:
///
/// - DSH 0.1.7+ (Profiles architecture):
///   - `~/.dsh/profiles/<profile>/cordis.patch.yml` → `- id: llm-pi-ai` -> `config.providers.tomo`
/// - Legacy DSH (0.1.1 fallback):
///   - `~/.dsh/settings.yaml` → `llm-pi-ai.providers.tomo`
/// - Credentials:
///   - `~/.dsh/.credentials.yaml` → `refs.TOMO_GATEWAY_TOKEN`
///
/// Documents are shared: DSH's own Models page, config editor and the user all edit
/// them. A parse-and-reserialize round trip would eat comments, key order and unknown
/// keys, so every edit here is **surgical and span scoped** — only the Tomo route span
/// and the one credential line are ever rewritten, and sibling routes added by the
/// Models page survive both configure and unconfigure byte for byte.
struct DSHGatewayConfigurator: Sendable {
    static let providerRouteKey = "tomo"
    static let providerDisplayName = "Tomo Gateway"
    static let credentialRef = "TOMO_GATEWAY_TOKEN"
    static let wireProtocol = "openai-completions"
    static let agentNameHeader = "DSH"

    let settingsURL: URL
    let credentialsURL: URL
    let customProfilePatchURLs: [URL]?
    let homeDirectory: URL
    let environment: [String: String]

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        settingsURL: URL? = nil,
        credentialsURL: URL? = nil,
        profilePatchURLs: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.settingsURL = settingsURL
            ?? homeDirectory.appendingPathComponent(".dsh/settings.yaml")
        self.credentialsURL = credentialsURL
            ?? homeDirectory.appendingPathComponent(".dsh/.credentials.yaml")
        self.customProfilePatchURLs = profilePatchURLs
        self.environment = environment
    }

    // MARK: - Detection

    var dshHomeURL: URL { settingsURL.deletingLastPathComponent() }

    /// Mirrors `AgentHookManager`'s DeepSeek Harness detection: the harness
    /// keeps all of its state under `~/.dsh`, which exists whether it was
    /// installed globally or run through npx.
    var isDSHInstalled: Bool {
        FileManager.default.fileExists(atPath: dshHomeURL.path)
    }

    var isConfigured: Bool { state.isConfigured }

    /// Discovers all profile `cordis.patch.yml` files in `~/.dsh/profiles/`.
    func discoverProfilePatchURLs() -> [URL] {
        let profilesDir = dshHomeURL.appendingPathComponent("profiles")
        guard FileManager.default.fileExists(atPath: profilesDir.path) else {
            return []
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var patchURLs: [URL] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name != "node_modules", !name.hasPrefix(".") else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                let patchURL = entry.appendingPathComponent("cordis.patch.yml")
                patchURLs.append(patchURL)
            }
        }
        return patchURLs.sorted { $0.path < $1.path }
    }

    /// The list of target profile patch URLs to write, either injected or discovered.
    var profilePatchURLs: [URL] {
        if let custom = customProfilePatchURLs {
            return custom
        }
        return discoverProfilePatchURLs()
    }

    /// Primary settings URL displayed in the UI: prefers `profiles/web/cordis.patch.yml`,
    /// then the first profile patch, or falls back to legacy `settings.yaml`.
    var primarySettingsURL: URL {
        profilePatchURLs.first(where: { $0.path.contains("/web/") })
            ?? profilePatchURLs.first
            ?? settingsURL
    }

    var state: DSHConfigurationState {
        var state = DSHConfigurationState()

        // 1. Check profile patches (DSH 0.1.7+)
        for patchURL in profilePatchURLs {
            if let text = try? String(contentsOf: patchURL, encoding: .utf8),
               let patchState = Self.readCordisState(in: text),
               patchState.routePresent {
                state.routePresent = true
                state.baseURL = patchState.baseURL
                state.apiKeyEnv = patchState.apiKeyEnv
                state.modelIDs = patchState.modelIDs
                break
            }
        }

        // 2. Fallback to settings.yaml (legacy DSH 0.1.1)
        if !state.routePresent, let text = try? String(contentsOf: settingsURL, encoding: .utf8) {
            let block = NarrowYAML.topLevelBlock(named: "llm-pi-ai", in: text)
            let route = block.flatMap {
                NarrowYAML.childBlock(named: Self.providerRouteKey, atIndent: 4, in: $0)
            }
            if let route {
                state.routePresent = true
                state.baseURL = NarrowYAML.scalar(named: "baseURL", atIndent: 6, in: route)
                state.apiKeyEnv = NarrowYAML.scalar(named: "apiKeyEnv", atIndent: 6, in: route)
                state.modelIDs = NarrowYAML.sequenceIDs(in: route)
            }
        }

        // 3. Check credentials document
        if let text = try? String(contentsOf: credentialsURL, encoding: .utf8) {
            let refs = NarrowYAML.topLevelBlock(named: "refs", in: text)
            let value = refs.flatMap { NarrowYAML.scalar(named: Self.credentialRef, atIndent: 2, in: $0) }
            state.credentialPresent = !(value ?? "").isEmpty
        }
        return state
    }

    /// DSH resolves a credential reference from the inherited process
    /// environment *before* the managed document, and that precedence cannot be
    /// changed from inside a process. An exported variable of the same name
    /// therefore shadows the token written here, so the UI must be able to say
    /// so instead of presenting a route that silently authenticates with the
    /// wrong value.
    var isCredentialShadowedByEnvironment: Bool {
        !(environment[Self.credentialRef] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Configure

    func configure(
        baseURL: String,
        apiKey: String,
        models: [DSHModel],
        setAsAgentDefaultModel: Bool
    ) throws {
        let uniqueModels = models.reduce(into: [DSHModel]()) { result, model in
            let id = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !id.contains(where: { $0.isWhitespace }) else { return }
            guard !result.contains(where: { $0.id == id }) else { return }
            let profile = ModelCapabilityRegistry.resolveCapability(for: id, override: nil)
            result.append(DSHModel(
                id: id,
                name: model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? id : model.name,
                contextWindow: model.contextWindow > 0 ? model.contextWindow : profile.contextWindow,
                maxTokens: model.maxTokens > 0 ? model.maxTokens : profile.maxTokens,
                input: model.input.isEmpty ? DSHModelModality.input(supportsImage: profile.supportsImage) : model.input,
                reasoning: model.reasoning.isEmpty ? DSHModelReasoning.from(levels: profile.reasoningLevels) : model.reasoning
            ))
        }
        guard !uniqueModels.isEmpty else {
            throw DSHGatewayConfigurationError.noGatewayModel
        }
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw DSHGatewayConfigurationError.invalidCredential
        }

        let settingsOriginal = try? Data(contentsOf: settingsURL)
        let credentialsOriginal = try? Data(contentsOf: credentialsURL)
        var patchesOriginal: [URL: Data?] = [:]
        let targetPatches = profilePatchURLs
        for patchURL in targetPatches {
            patchesOriginal[patchURL] = try? Data(contentsOf: patchURL)
        }

        do {
            // 1. Write to all target profile patches (DSH 0.1.7+)
            for patchURL in targetPatches {
                var patchText = (try? readText(at: patchURL, kind: .settings)) ?? ""
                patchText = try Self.upsertCordisRoute(
                    in: patchText,
                    baseURL: baseURL,
                    apiKeyEnv: Self.credentialRef,
                    models: uniqueModels
                )
                if setAsAgentDefaultModel, let defaultModel = uniqueModels.first?.id {
                    patchText = try Self.setCordisAgentDefaultModel(
                        in: patchText,
                        provider: Self.providerRouteKey,
                        model: defaultModel
                    )
                } else {
                    patchText = try Self.reconcileCordisAgentDefaultModel(in: patchText, models: uniqueModels)
                }
                try write(patchText, to: patchURL, kind: .settings)
            }

            // 2. Write to settings.yaml (legacy DSH 0.1.1 fallback)
            var settings = (try? readText(at: settingsURL, kind: .settings)) ?? ""
            settings = try Self.upsertRoute(
                in: settings,
                baseURL: baseURL,
                apiKeyEnv: Self.credentialRef,
                models: uniqueModels
            )
            if setAsAgentDefaultModel, let defaultModel = uniqueModels.first?.id {
                settings = try Self.setAgentDefaultModel(
                    in: settings,
                    provider: Self.providerRouteKey,
                    model: defaultModel
                )
            } else {
                settings = try Self.reconcileAgentDefaultModel(in: settings, models: uniqueModels)
            }
            try write(settings, to: settingsURL, kind: .settings)

            // 3. Write credentials (~/.dsh/.credentials.yaml)
            try upsertCredential(apiKey: trimmedKey)

            // 4. Verify round-trip state
            try verify(baseURL: baseURL, apiKey: trimmedKey, models: uniqueModels)
        } catch {
            restore(settingsOriginal, to: settingsURL)
            restore(credentialsOriginal, to: credentialsURL)
            for (patchURL, originalData) in patchesOriginal {
                restore(originalData, to: patchURL)
            }
            throw error
        }
    }

    /// Refresh the route's model catalog in place.
    ///
    /// DSH merges the settings section per provider and its `models` list is an
    /// array that replaces wholesale, so a refresh is expressible directly: the
    /// Tomo route span is rewritten from scratch, which drops removed
    /// models and adds new ones in the same atomic file commit. There is no
    /// window in which the route is absent. Returns `true` when documents actually changed.
    @discardableResult
    func refreshModels(baseURL: String, apiKey: String, models: [DSHModel]) throws -> Bool {
        let beforePrimary = try? String(contentsOf: primarySettingsURL, encoding: .utf8)
        let beforeLegacy = try? String(contentsOf: settingsURL, encoding: .utf8)
        try configure(baseURL: baseURL, apiKey: apiKey, models: models, setAsAgentDefaultModel: false)
        let afterPrimary = try? String(contentsOf: primarySettingsURL, encoding: .utf8)
        let afterLegacy = try? String(contentsOf: settingsURL, encoding: .utf8)
        return beforePrimary != afterPrimary || beforeLegacy != afterLegacy
    }

    func updateApiKey(_ newApiKey: String) throws {
        let trimmed = newApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DSHGatewayConfigurationError.invalidCredential
        }
        guard state.routePresent else { return }
        let original = try? Data(contentsOf: credentialsURL)
        do {
            try upsertCredential(apiKey: trimmed)
            let text = try readText(at: credentialsURL, kind: .credentials)
            let refs = NarrowYAML.topLevelBlock(named: "refs", in: text)
            let actual = refs.flatMap { NarrowYAML.scalar(named: Self.credentialRef, atIndent: 2, in: $0) }
            guard actual == trimmed else {
                throw DSHGatewayConfigurationError.verificationFailed(
                    key: Self.credentialRef,
                    expected: "<已更新>",
                    actual: actual == nil ? "" : "<不一致>"
                )
            }
        } catch {
            restore(original, to: credentialsURL)
            throw error
        }
    }

    // MARK: - Unconfigure

    func unconfigure() throws {
        let settingsOriginal = try? Data(contentsOf: settingsURL)
        let credentialsOriginal = try? Data(contentsOf: credentialsURL)
        var patchesOriginal: [URL: Data?] = [:]
        let targetPatches = profilePatchURLs
        for patchURL in targetPatches {
            patchesOriginal[patchURL] = try? Data(contentsOf: patchURL)
        }

        do {
            for patchURL in targetPatches {
                if let patchText = try? readText(at: patchURL, kind: .settings) {
                    var updated = try Self.removeCordisRoute(in: patchText)
                    updated = try Self.clearCordisAgentDefaultModelIfOurs(in: updated)
                    if updated != patchText {
                        try write(updated, to: patchURL, kind: .settings)
                    }
                }
            }

            if let settings = try? readText(at: settingsURL, kind: .settings) {
                var updated = try Self.removeRoute(in: settings)
                updated = try Self.clearAgentDefaultModelIfOurs(in: updated)
                if updated != settings {
                    try write(updated, to: settingsURL, kind: .settings)
                }
            }

            if let credentials = try? readText(at: credentialsURL, kind: .credentials) {
                let updated = try Self.removeCredential(in: credentials)
                if updated != credentials {
                    try write(updated, to: credentialsURL, kind: .credentials)
                }
            }

            let after = state
            guard !after.routePresent else {
                throw DSHGatewayConfigurationError.verificationFailed(
                    key: "llm-pi-ai.providers.\(Self.providerRouteKey)",
                    expected: "<已移除>",
                    actual: "仍存在"
                )
            }
        } catch {
            restore(settingsOriginal, to: settingsURL)
            restore(credentialsOriginal, to: credentialsURL)
            for (patchURL, originalData) in patchesOriginal {
                restore(originalData, to: patchURL)
            }
            throw error
        }
    }

    // MARK: - Document I/O

    private func readText(at url: URL, kind: DSHDocumentKind) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "" }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            switch kind {
            case .settings: throw DSHGatewayConfigurationError.settingsUnreadable(path: url.path)
            case .credentials: throw DSHGatewayConfigurationError.credentialsUnreadable(path: url.path)
            }
        }
        return text
    }

    private func write(_ text: String, to url: URL, kind: DSHDocumentKind) throws {
        let directory = url.deletingLastPathComponent()
        let existingMode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .posixPermissions
        ] as? NSNumber

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // An atomic replace does not carry the original mode over, so it is
        // re-applied explicitly. The credential document's mode is a contract:
        // DSH refuses to parse one any other OS user can read, and refuses
        // *before* reading its content. The settings document holds no secret,
        // so it keeps whatever mode it already had — widening a user's chosen
        // permissions is not ours to do.
        let mode: NSNumber = kind == .credentials ? 0o600 : (existingMode ?? 0o644)

        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        if kind == .credentials {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    private func restore(_ original: Data?, to url: URL) {
        if let original {
            try? original.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func upsertCredential(apiKey: String) throws {
        var text = try readText(at: credentialsURL, kind: .credentials)
        let hasVersion = NarrowYAML.topLevelBlock(named: "version", in: text) != nil
        let hasRefs = NarrowYAML.topLevelBlock(named: "refs", in: text) != nil
        let isBlank = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if !isBlank, !hasRefs, !hasVersion {
            // A pre-`version: 1` flat document. DSH upgrades it under its own
            // write lock on next start; rebuilding it here risks rewriting
            // secrets we did not author.
            throw DSHGatewayConfigurationError.legacyCredentialDocument(path: credentialsURL.path)
        }

        if isBlank {
            text = "version: 1\n"
        }
        text = try Self.upsertScalar(
            in: text,
            blockName: "refs",
            key: Self.credentialRef,
            value: apiKey,
            blockIndent: 2
        )
        try write(text, to: credentialsURL, kind: .credentials)
    }

    // MARK: - Verification

    private func verify(baseURL: String, apiKey: String, models: [DSHModel]) throws {
        let after = state
        guard after.routePresent else {
            throw DSHGatewayConfigurationError.verificationFailed(
                key: "llm-pi-ai.providers.\(Self.providerRouteKey)",
                expected: "<存在>",
                actual: ""
            )
        }
        guard after.baseURL == baseURL else {
            throw DSHGatewayConfigurationError.verificationFailed(
                key: "baseURL",
                expected: baseURL,
                actual: after.baseURL ?? ""
            )
        }
        guard after.apiKeyEnv == Self.credentialRef else {
            throw DSHGatewayConfigurationError.verificationFailed(
                key: "apiKeyEnv",
                expected: Self.credentialRef,
                actual: after.apiKeyEnv ?? ""
            )
        }
        let expectedIDs = models.map(\.id)
        guard after.modelIDs == expectedIDs else {
            throw DSHGatewayConfigurationError.verificationFailed(
                key: "models",
                expected: "\(expectedIDs.count) 个模型",
                actual: "\(after.modelIDs.count) 个模型"
            )
        }
        guard after.credentialPresent else {
            throw DSHGatewayConfigurationError.verificationFailed(
                key: Self.credentialRef,
                expected: "<已写入>",
                actual: ""
            )
        }
        guard !isCredentialShadowedByEnvironment else {
            throw DSHGatewayConfigurationError.verificationFailed(
                key: Self.credentialRef,
                expected: "<由 ~/.dsh/.credentials.yaml 提供>",
                actual: "被进程环境变量遮蔽"
            )
        }
        // The stored value must round-trip verbatim; a mismatch here would
        // surface much later as a 401 instead of as a failed write.
        let text = try readText(at: credentialsURL, kind: .credentials)
        let refs = NarrowYAML.topLevelBlock(named: "refs", in: text)
        let stored = refs.flatMap { NarrowYAML.scalar(named: Self.credentialRef, atIndent: 2, in: $0) }
        guard stored == apiKey else {
            throw DSHGatewayConfigurationError.verificationFailed(
                key: Self.credentialRef,
                expected: "<与 Gateway 令牌一致>",
                actual: stored == nil ? "" : "<不一致>"
            )
        }
    }

    // MARK: - Route block generation

    private static func routeBlockLines(
        baseURL: String,
        apiKeyEnv: String,
        models: [DSHModel],
        indent: Int
    ) -> [String] {
        let pad = String(repeating: " ", count: indent)
        let fieldPad = String(repeating: " ", count: indent + 2)
        let itemPad = String(repeating: " ", count: indent + 4)
        let itemFieldPad = String(repeating: " ", count: indent + 6)

        var lines: [String] = []
        lines.append("\(pad)\(providerRouteKey):")
        lines.append("\(fieldPad)displayName: \(NarrowYAML.quote(providerDisplayName))")
        lines.append("\(fieldPad)api: \(NarrowYAML.quote(wireProtocol))")
        lines.append("\(fieldPad)baseURL: \(NarrowYAML.quote(baseURL))")
        lines.append("\(fieldPad)apiKeyEnv: \(NarrowYAML.quote(apiKeyEnv))")
        lines.append("\(fieldPad)headers:")
        lines.append("\(itemPad)X-Agent-Name: \(NarrowYAML.quote(agentNameHeader))")
        lines.append("\(fieldPad)models:")
        for model in models {
            lines.append("\(itemPad)- id: \(NarrowYAML.quote(model.id))")
            lines.append("\(itemFieldPad)name: \(NarrowYAML.quote(model.name))")
            lines.append("\(itemFieldPad)contextWindow: \(model.contextWindow)")
            lines.append("\(itemFieldPad)maxTokens: \(model.maxTokens)")
            // Flow style keeps the modality list on one line, which a
            // line-oriented span editor can rewrite without tracking nested
            // sequence indentation.
            lines.append("\(itemFieldPad)input: [\(model.input.joined(separator: ", "))]")
            if !model.reasoning.isEmpty {
                lines.append("\(itemFieldPad)reasoningEfforts:")
                for effort in model.reasoning {
                    // `off` with no value is the one level allowed to be empty:
                    // pi-ai reads it as "supported, send nothing".
                    let wire = effort.wire.map { " \(NarrowYAML.quote($0))" } ?? ""
                    lines.append("\(itemFieldPad)  \(effort.level):\(wire)")
                }
            }
        }
        return lines
    }

    // MARK: - Legacy settings.yaml Route Operations

    /// Insert or replace the Tomo route inside the `llm-pi-ai` block,
    /// leaving every sibling route and comment untouched. Also purges legacy codexling routes.
    static func upsertRoute(
        in text: String,
        baseURL: String,
        apiKeyEnv: String,
        models: [DSHModel]
    ) throws -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let generated = routeBlockLines(baseURL: baseURL, apiKeyEnv: apiKeyEnv, models: models, indent: 4)

        guard let blockSpan = NarrowYAML.topLevelSpan(named: "llm-pi-ai", in: lines) else {
            // No section yet: append one after a separating blank line.
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append("llm-pi-ai:")
            lines.append("  providers:")
            lines.append(contentsOf: generated)
            lines.append("")
            return lines.joined(separator: "\n")
        }

        var blockLines = Array(lines[blockSpan])

        // Remove any legacy codexling provider entries
        for legacyKey in ["codexling-gateway", "codexling"] {
            if let legacyRange = NarrowYAML.childSpan(named: legacyKey, atIndent: 4, in: blockLines) {
                blockLines.removeSubrange(legacyRange)
            }
        }

        let (providersRange, isEmptyFlowMap) = try NarrowYAML.providersSpan(atIndent: 2, in: blockLines)

        if let routeRange = NarrowYAML.childSpan(
            named: providerRouteKey,
            atIndent: 4,
            in: blockLines
        ) {
            blockLines.replaceSubrange(routeRange, with: generated)
        } else if let providersRange {
            if isEmptyFlowMap {
                blockLines.replaceSubrange(providersRange, with: ["  providers:"])
                blockLines.insert(contentsOf: generated, at: providersRange.lowerBound + 1)
            } else {
                blockLines.insert(contentsOf: generated, at: providersRange.upperBound)
            }
        } else {
            blockLines.append("  providers:")
            blockLines.append(contentsOf: generated)
        }

        lines.replaceSubrange(blockSpan, with: blockLines)
        return lines.joined(separator: "\n")
    }

    /// Remove the Tomo route, then collapse a `providers` mapping and a
    /// `llm-pi-ai` section that our removal left empty. Sibling routes added by
    /// the DSH Models page survive untouched.
    static func removeRoute(in text: String) throws -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        guard let blockSpan = NarrowYAML.topLevelSpan(named: "llm-pi-ai", in: lines) else {
            return text
        }
        var blockLines = Array(lines[blockSpan])

        for key in [providerRouteKey, "codexling-gateway", "codexling"] {
            if let routeRange = NarrowYAML.childSpan(named: key, atIndent: 4, in: blockLines) {
                blockLines.removeSubrange(routeRange)
            }
        }

        // Drop a `providers:` mapping that no longer has any child route.
        if let providersRange = NarrowYAML.childSpan(named: "providers", atIndent: 2, in: blockLines),
           NarrowYAML.childSpans(atIndent: 4, in: Array(blockLines[providersRange])).isEmpty {
            blockLines.removeSubrange(providersRange)
        }

        let hasChildren = !NarrowYAML.childSpans(atIndent: 2, in: blockLines).isEmpty
        if hasChildren {
            lines.replaceSubrange(blockSpan, with: blockLines)
        } else {
            var removal = blockSpan
            // Swallow one blank separator so repeated cycles do not stack them.
            while removal.upperBound < lines.count, lines[removal.upperBound].isEmpty {
                removal = removal.lowerBound..<(removal.upperBound + 1)
            }
            lines.removeSubrange(removal)
        }
        return lines.joined(separator: "\n")
    }

    static func removeCredential(in text: String) throws -> String {
        guard let blockSpan = NarrowYAML.topLevelSpan(named: "refs", in: text.components(separatedBy: "\n")) else {
            return text
        }
        var lines = text.components(separatedBy: "\n")
        var blockLines = Array(lines[blockSpan])
        guard var keyRange = NarrowYAML.childSpan(named: credentialRef, atIndent: 2, in: blockLines) else {
            return text
        }
        // A comment directly above an entry is that entry's annotation, so it
        // leaves with it rather than drifting onto whatever follows.
        while keyRange.lowerBound > 1 {
            let above = blockLines[keyRange.lowerBound - 1].trimmingCharacters(in: .whitespaces)
            guard above.hasPrefix("#") else { break }
            keyRange = (keyRange.lowerBound - 1)..<keyRange.upperBound
        }
        blockLines.removeSubrange(keyRange)

        // An emptied mapping stays an explicit `{}`: a bare `refs:` would parse
        // as null, which the credential document rejects outright.
        if NarrowYAML.childSpans(atIndent: 2, in: blockLines).isEmpty {
            blockLines = ["refs: {}"]
        }
        lines.replaceSubrange(blockSpan, with: blockLines)
        return lines.joined(separator: "\n")
    }

    static func setAgentDefaultModel(in text: String, provider: String, model: String) throws -> String {
        var body = try upsertScalar(
            in: text,
            blockName: "agent-default-model",
            key: "provider",
            value: provider,
            blockIndent: 2
        )
        body = try upsertScalar(
            in: body,
            blockName: "agent-default-model",
            key: "model",
            value: model,
            blockIndent: 2
        )
        return body
    }

    static func isOurProvider(_ provider: String?) -> Bool {
        guard let provider else { return false }
        return provider == providerRouteKey || provider == "codexling-gateway" || provider == "codexling"
    }

    static func agentDefaultProvider(in text: String) -> String? {
        NarrowYAML.topLevelBlock(named: "agent-default-model", in: text)
            .flatMap { NarrowYAML.scalar(named: "provider", atIndent: 2, in: $0) }
    }

    /// Keep an agent default that points at this route from naming a model the
    /// route no longer serves. A default belonging to any other provider is
    /// left exactly as the user set it.
    static func reconcileAgentDefaultModel(in text: String, models: [DSHModel]) throws -> String {
        let currentProvider = agentDefaultProvider(in: text)
        guard isOurProvider(currentProvider) else { return text }
        guard let first = models.first?.id else { return text }
        let current = NarrowYAML.topLevelBlock(named: "agent-default-model", in: text)
            .flatMap { NarrowYAML.scalar(named: "model", atIndent: 2, in: $0) }
        if currentProvider != providerRouteKey || current == nil || !models.contains(where: { $0.id == current }) {
            return try setAgentDefaultModel(in: text, provider: providerRouteKey, model: first)
        }
        return text
    }

    /// Undo only the default this integration set: a `provider` naming another
    /// provider is somebody else's configuration.
    static func clearAgentDefaultModelIfOurs(in text: String) throws -> String {
        guard isOurProvider(agentDefaultProvider(in: text)) else { return text }
        var lines = text.components(separatedBy: "\n")
        guard let blockSpan = NarrowYAML.topLevelSpan(named: "agent-default-model", in: lines) else {
            return text
        }
        var blockLines = Array(lines[blockSpan])
        for key in ["model", "provider"] {
            if let range = NarrowYAML.childSpan(named: key, atIndent: 2, in: blockLines) {
                blockLines.removeSubrange(range)
            }
        }
        if blockLines.count > 1 {
            lines.replaceSubrange(blockSpan, with: blockLines)
        } else {
            var removal = blockSpan
            while removal.upperBound < lines.count, lines[removal.upperBound].isEmpty {
                removal = removal.lowerBound..<(removal.upperBound + 1)
            }
            lines.removeSubrange(removal)
        }
        return lines.joined(separator: "\n")
    }

    private static func upsertScalar(
        in text: String,
        blockName: String,
        key: String,
        value: String,
        blockIndent: Int
    ) throws -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        let rendered = "\(String(repeating: " ", count: blockIndent))\(key): \(NarrowYAML.quote(value))"

        guard let blockSpan = NarrowYAML.topLevelSpan(named: blockName, in: lines) else {
            if !lines.isEmpty, lines.last?.isEmpty == false { lines.append("") }
            lines.append("\(blockName):")
            lines.append(rendered)
            lines.append("")
            return lines.joined(separator: "\n")
        }

        var blockLines = Array(lines[blockSpan])
        if let keyRange = NarrowYAML.childSpan(named: key, atIndent: blockIndent, in: blockLines) {
            blockLines.replaceSubrange(keyRange, with: [rendered])
        } else {
            blockLines.append(rendered)
        }
        lines.replaceSubrange(blockSpan, with: blockLines)
        return lines.joined(separator: "\n")
    }

    // MARK: - DSH 0.1.7+ cordis.patch.yml Operations

    /// Reads state from a `cordis.patch.yml` document.
    static func readCordisState(in text: String) -> DSHConfigurationState? {
        let lines = text.components(separatedBy: "\n")
        guard let span = CordisYAML.itemSpan(named: "llm-pi-ai", in: lines) else {
            return nil
        }
        let itemLines = Array(lines[span])
        guard let configSpan = NarrowYAML.childSpan(named: "config", atIndent: 2, in: itemLines) else {
            return nil
        }
        let configLines = Array(itemLines[configSpan])
        guard let providersSpan = NarrowYAML.childSpan(named: "providers", atIndent: 4, in: configLines) else {
            return nil
        }
        let providersLines = Array(configLines[providersSpan])
        guard let tomoSpan = NarrowYAML.childSpan(named: providerRouteKey, atIndent: 6, in: providersLines) else {
            return nil
        }
        let tomoLines = Array(providersLines[tomoSpan])

        var state = DSHConfigurationState()
        state.routePresent = true
        state.baseURL = NarrowYAML.scalar(named: "baseURL", atIndent: 8, in: tomoLines)
        state.apiKeyEnv = NarrowYAML.scalar(named: "apiKeyEnv", atIndent: 8, in: tomoLines)
        state.modelIDs = NarrowYAML.sequenceIDs(in: tomoLines)
        return state
    }

    /// Removes legacy `codexling-gateway` or `codexling` routes from `itemLines`.
    private static func removeLegacyCodexlingProviders(in itemLines: [String]) -> [String] {
        var lines = itemLines
        guard let configSpan = NarrowYAML.childSpan(named: "config", atIndent: 2, in: lines) else { return lines }
        var configLines = Array(lines[configSpan])
        guard let providersSpan = NarrowYAML.childSpan(named: "providers", atIndent: 4, in: configLines) else { return lines }
        var providersLines = Array(configLines[providersSpan])

        for legacyKey in ["codexling-gateway", "codexling"] {
            if let span = NarrowYAML.childSpan(named: legacyKey, atIndent: 6, in: providersLines) {
                providersLines.removeSubrange(span)
            }
        }
        configLines.replaceSubrange(providersSpan, with: providersLines)
        lines.replaceSubrange(configSpan, with: configLines)
        return lines
    }

    /// Upsert Tomo route into `cordis.patch.yml`.
    static func upsertCordisRoute(
        in text: String,
        baseURL: String,
        apiKeyEnv: String,
        models: [DSHModel]
    ) throws -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == "[]" }

        let generated = routeBlockLines(baseURL: baseURL, apiKeyEnv: apiKeyEnv, models: models, indent: 6)

        if let itemSpan = CordisYAML.itemSpan(named: "llm-pi-ai", in: lines) {
            var itemLines = Array(lines[itemSpan])
            itemLines = removeLegacyCodexlingProviders(in: itemLines)

            if let configSpan = NarrowYAML.childSpan(named: "config", atIndent: 2, in: itemLines) {
                var configLines = Array(itemLines[configSpan])
                if let providersSpan = NarrowYAML.childSpan(named: "providers", atIndent: 4, in: configLines) {
                    var providersLines = Array(configLines[providersSpan])
                    let header = providersLines[0]
                    let isFlowEmpty = header.contains(":")
                        && header.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) == "{}"
                    if isFlowEmpty {
                        providersLines = ["    providers:"]
                        providersLines.append(contentsOf: generated)
                    } else if let tomoSpan = NarrowYAML.childSpan(named: providerRouteKey, atIndent: 6, in: providersLines) {
                        providersLines.replaceSubrange(tomoSpan, with: generated)
                    } else {
                        providersLines.append(contentsOf: generated)
                    }
                    configLines.replaceSubrange(providersSpan, with: providersLines)
                } else {
                    configLines.append("    providers:")
                    configLines.append(contentsOf: generated)
                }
                itemLines.replaceSubrange(configSpan, with: configLines)
            } else {
                itemLines.append("  config:")
                itemLines.append("    providers:")
                itemLines.append(contentsOf: generated)
            }
            lines.replaceSubrange(itemSpan, with: itemLines)
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("- id: llm-pi-ai")
            lines.append("  name: \"@deepseek-ai/dsh-llm-pi-ai\"")
            lines.append("  config:")
            lines.append("    providers:")
            lines.append(contentsOf: generated)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Remove Tomo route from `cordis.patch.yml`.
    static func removeCordisRoute(in text: String) throws -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        guard let itemSpan = CordisYAML.itemSpan(named: "llm-pi-ai", in: lines) else {
            return text
        }
        var itemLines = Array(lines[itemSpan])
        itemLines = removeLegacyCodexlingProviders(in: itemLines)

        guard let configSpan = NarrowYAML.childSpan(named: "config", atIndent: 2, in: itemLines) else {
            return text
        }
        var configLines = Array(itemLines[configSpan])
        guard let providersSpan = NarrowYAML.childSpan(named: "providers", atIndent: 4, in: configLines) else {
            return text
        }
        var providersLines = Array(configLines[providersSpan])

        if let tomoSpan = NarrowYAML.childSpan(named: providerRouteKey, atIndent: 6, in: providersLines) {
            providersLines.removeSubrange(tomoSpan)
        }

        let remainingProviders = NarrowYAML.childSpans(atIndent: 6, in: providersLines)
        if remainingProviders.isEmpty {
            configLines.removeSubrange(providersSpan)
        } else {
            configLines.replaceSubrange(providersSpan, with: providersLines)
        }

        let remainingConfigChildren = NarrowYAML.childSpans(atIndent: 4, in: configLines)
        if remainingConfigChildren.isEmpty {
            itemLines.removeSubrange(configSpan)
        } else {
            itemLines.replaceSubrange(configSpan, with: configLines)
        }

        let remainingItemChildren = NarrowYAML.childSpans(atIndent: 2, in: itemLines)
        let hasRealConfig = remainingItemChildren.contains { span in
            let key = NarrowYAML.keyName(of: itemLines[span.lowerBound])
            return key != "name" && key != "id"
        }

        if !hasRealConfig {
            var removal = itemSpan
            while removal.upperBound < lines.count, lines[removal.upperBound].isEmpty {
                removal = removal.lowerBound..<(removal.upperBound + 1)
            }
            lines.removeSubrange(removal)
        } else {
            lines.replaceSubrange(itemSpan, with: itemLines)
        }

        let remainingSpans = CordisYAML.itemSpans(in: lines)
        if remainingSpans.isEmpty {
            var resultLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            resultLines.append("[]")
            resultLines.append("")
            return resultLines.joined(separator: "\n")
        }

        return lines.joined(separator: "\n")
    }

    /// Set agent default model in `cordis.patch.yml`.
    static func setCordisAgentDefaultModel(in text: String, provider: String, model: String) throws -> String {
        var lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces) == "[]" }

        let providerLine = "    provider: \(NarrowYAML.quote(provider))"
        let modelLine = "    model: \(NarrowYAML.quote(model))"

        if let itemSpan = CordisYAML.itemSpan(named: "agent-default-model", in: lines) {
            var itemLines = Array(lines[itemSpan])
            if let configSpan = NarrowYAML.childSpan(named: "config", atIndent: 2, in: itemLines) {
                var configLines = Array(itemLines[configSpan])
                if let pSpan = NarrowYAML.childSpan(named: "provider", atIndent: 4, in: configLines) {
                    configLines.replaceSubrange(pSpan, with: [providerLine])
                } else {
                    configLines.append(providerLine)
                }
                if let mSpan = NarrowYAML.childSpan(named: "model", atIndent: 4, in: configLines) {
                    configLines.replaceSubrange(mSpan, with: [modelLine])
                } else {
                    configLines.append(modelLine)
                }
                itemLines.replaceSubrange(configSpan, with: configLines)
            } else {
                itemLines.append("  config:")
                itemLines.append(providerLine)
                itemLines.append(modelLine)
            }
            lines.replaceSubrange(itemSpan, with: itemLines)
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("- id: agent-default-model")
            lines.append("  name: \"@deepseek-ai/dsh-agent-default-model\"")
            lines.append("  config:")
            lines.append(providerLine)
            lines.append(modelLine)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func cordisAgentDefaultProvider(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let itemSpan = CordisYAML.itemSpan(named: "agent-default-model", in: lines) else {
            return nil
        }
        let itemLines = Array(lines[itemSpan])
        guard let configSpan = NarrowYAML.childSpan(named: "config", atIndent: 2, in: itemLines) else {
            return nil
        }
        let configLines = Array(itemLines[configSpan])
        return NarrowYAML.scalar(named: "provider", atIndent: 4, in: configLines)
    }

    static func cordisAgentDefaultModel(in text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let itemSpan = CordisYAML.itemSpan(named: "agent-default-model", in: lines) else {
            return nil
        }
        let itemLines = Array(lines[itemSpan])
        guard let configSpan = NarrowYAML.childSpan(named: "config", atIndent: 2, in: itemLines) else {
            return nil
        }
        let configLines = Array(itemLines[configSpan])
        return NarrowYAML.scalar(named: "model", atIndent: 4, in: configLines)
    }

    static func reconcileCordisAgentDefaultModel(in text: String, models: [DSHModel]) throws -> String {
        let currentProvider = cordisAgentDefaultProvider(in: text)
        guard isOurProvider(currentProvider) else { return text }
        guard let first = models.first?.id else { return text }
        let currentModel = cordisAgentDefaultModel(in: text)
        if currentProvider != providerRouteKey || currentModel == nil || !models.contains(where: { $0.id == currentModel }) {
            return try setCordisAgentDefaultModel(in: text, provider: providerRouteKey, model: first)
        }
        return text
    }

    static func clearCordisAgentDefaultModelIfOurs(in text: String) throws -> String {
        guard isOurProvider(cordisAgentDefaultProvider(in: text)) else { return text }
        var lines = text.components(separatedBy: "\n")
        guard let itemSpan = CordisYAML.itemSpan(named: "agent-default-model", in: lines) else {
            return text
        }
        var itemLines = Array(lines[itemSpan])
        if let configSpan = NarrowYAML.childSpan(named: "config", atIndent: 2, in: itemLines) {
            var configLines = Array(itemLines[configSpan])
            for key in ["model", "provider"] {
                if let range = NarrowYAML.childSpan(named: key, atIndent: 4, in: configLines) {
                    configLines.removeSubrange(range)
                }
            }
            let remainingConfigChildren = NarrowYAML.childSpans(atIndent: 4, in: configLines)
            if remainingConfigChildren.isEmpty {
                itemLines.removeSubrange(configSpan)
            } else {
                itemLines.replaceSubrange(configSpan, with: configLines)
            }
        }

        let remainingItemChildren = NarrowYAML.childSpans(atIndent: 2, in: itemLines)
        let hasOtherConfig = remainingItemChildren.contains { span in
            let key = NarrowYAML.keyName(of: itemLines[span.lowerBound])
            return key != "name" && key != "id"
        }
        if !hasOtherConfig {
            var removal = itemSpan
            while removal.upperBound < lines.count, lines[removal.upperBound].isEmpty {
                removal = removal.lowerBound..<(removal.upperBound + 1)
            }
            lines.removeSubrange(removal)
        } else {
            lines.replaceSubrange(itemSpan, with: itemLines)
        }

        let remainingSpans = CordisYAML.itemSpans(in: lines)
        if remainingSpans.isEmpty {
            var resultLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            resultLines.append("[]")
            resultLines.append("")
            return resultLines.joined(separator: "\n")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Cordis YAML Sequence helpers

enum CordisYAML {
    /// Finds the line ranges for each top-level sequence item starting with `- ` at column 0.
    static func itemSpans(in lines: [String]) -> [Range<Int>] {
        var starts: [Int] = []
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("- ") || line == "-" {
                starts.append(index)
            }
        }
        return starts.enumerated().map { offset, start in
            var end = offset + 1 < starts.count ? starts[offset + 1] : lines.count
            while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                end -= 1
            }
            return start..<end
        }
    }

    /// Retrieves the id of a sequence item map.
    static func itemId(in itemLines: [String]) -> String? {
        guard let first = itemLines.first else { return nil }
        let afterDash = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        if afterDash.hasPrefix("id:") {
            let raw = String(afterDash.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return NarrowYAML.unquote(raw)
        }
        return NarrowYAML.scalar(named: "id", atIndent: 2, in: itemLines)
    }

    /// Finds the sequence item span matching a given `id`.
    static func itemSpan(named id: String, in lines: [String]) -> Range<Int>? {
        for span in itemSpans(in: lines) {
            let itemLines = Array(lines[span])
            if itemId(in: itemLines) == id {
                return span
            }
        }
        return nil
    }
}

// MARK: - Narrow, span-scoped YAML editing

/// Deliberately not a YAML library.
///
/// Both DSH documents are shared with the harness's own writers, so the only
/// safe edit is one that touches the bytes it owns and leaves every other byte
/// exactly where it was. These helpers locate spans by indentation and never
/// reserialize: comments, key order, quoting style and unknown keys all survive.
///
/// Everything here trusts only structure this file generated or DSH's own
/// 2-space dumper produces; an exotic shape (a non-empty flow mapping under
/// `providers`) is refused rather than guessed at.
enum NarrowYAML {
    /// A line that introduces a top-level mapping key.
    static func isTopLevelKey(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        if first == " " || first == "\t" || first == "#" { return false }
        guard line.contains(":") else { return false }
        return true
    }

    static func keyName(of line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }

    static func indent(of line: String) -> Int {
        var count = 0
        for character in line {
            if character == " " { count += 1 } else if character == "\t" { count += 2 } else { break }
        }
        return count
    }

    /// Span of one top-level block: its key line through the last line before
    /// the next top-level key. Trailing blank lines are excluded so a block
    /// appended later does not accumulate separators.
    static func topLevelSpan(named name: String, in lines: [String]) -> Range<Int>? {
        guard let start = lines.firstIndex(where: { isTopLevelKey($0) && keyName(of: $0) == name }) else {
            return nil
        }
        var end = lines.count
        var index = start + 1
        while index < lines.count {
            if isTopLevelKey(lines[index]) {
                end = index
                break
            }
            index += 1
        }
        while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        return start..<end
    }

    static func topLevelBlock(named name: String, in text: String) -> [String]? {
        let lines = text.components(separatedBy: "\n")
        guard let span = topLevelSpan(named: name, in: lines) else { return nil }
        return Array(lines[span])
    }

    /// Every keyed child at one indentation level.
    static func childSpans(atIndent target: Int, in lines: [String]) -> [Range<Int>] {
        var starts: [Int] = []
        for (index, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.first == "#" { continue }
            if indent(of: line) == target, keyName(of: line) != nil {
                starts.append(index)
            }
        }
        return starts.enumerated().map { offset, start in
            var end = offset + 1 < starts.count ? starts[offset + 1] : lines.count
            for i in (start + 1)..<end {
                let line = lines[i]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !trimmed.hasPrefix("#"), indent(of: line) < target {
                    end = i
                    break
                }
            }
            while end > start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                end -= 1
            }
            return start..<end
        }
    }

    static func childSpan(named name: String, atIndent target: Int, in lines: [String]) -> Range<Int>? {
        for span in childSpans(atIndent: target, in: lines) {
            if keyName(of: lines[span.lowerBound]) == name { return span }
        }
        return nil
    }

    static func childBlock(named name: String, atIndent target: Int, in lines: [String]) -> [String]? {
        childSpan(named: name, atIndent: target, in: lines).map { Array(lines[$0]) }
    }

    /// Locate the Tomo route whether or not the `llm-pi-ai` block's own
    /// `providers` key could be found.
    static func routeBlock(inProvidersBlock block: [String]?, route: String) -> [String]? {
        guard let block else { return nil }
        return childBlock(named: route, atIndent: 4, in: block)
    }

    /// The `providers:` line inside a settings block, plus whether it is an
    /// empty flow mapping (`providers: {}`) that may safely be expanded.
    static func providersSpan(atIndent target: Int = 2, in blockLines: [String]) throws -> (Range<Int>?, Bool) {
        guard let span = childSpan(named: "providers", atIndent: target, in: blockLines) else {
            return (nil, false)
        }
        let header = blockLines[span.lowerBound]
        guard let colon = header.firstIndex(of: ":") else { return (span, false) }
        let inline = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if inline.isEmpty || inline.hasPrefix("#") { return (span, false) }
        if inline == "{}" { return (span, true) }
        throw DSHGatewayConfigurationError.unsupportedSettingsShape(
            detail: "providers 不是块映射（\(inline.prefix(24))…），请改为块映射或先由 DSH 模型页迁移"
        )
    }

    /// A scalar value at `key: value`, unquoted.
    static func scalar(named key: String, atIndent target: Int, in lines: [String]) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), indent(of: line) == target else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            guard String(trimmed[trimmed.startIndex..<colon]).trimmingCharacters(in: .whitespaces) == key else {
                continue
            }
            let raw = String(trimmed[trimmed.index(after: colon)...])
            return unquote(raw)
        }
        return nil
    }

    /// Model IDs from a `models:` sequence: every `- id: …` at the item indent.
    static func sequenceIDs(in lines: [String]) -> [String] {
        var ids: [String] = []
        var insideModels = false
        var modelsIndent = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let lineIndent = indent(of: line)
            if let key = keyName(of: trimmed), key == "models", !trimmed.hasPrefix("-") {
                insideModels = true
                modelsIndent = lineIndent
                continue
            }
            guard insideModels else { continue }
            guard lineIndent > modelsIndent else {
                insideModels = false
                continue
            }
            guard trimmed.hasPrefix("- ") else { continue }
            let entry = String(trimmed.dropFirst(2))
            guard let colon = entry.firstIndex(of: ":") else { continue }
            guard String(entry[entry.startIndex..<colon]).trimmingCharacters(in: .whitespaces) == "id" else {
                continue
            }
            if let value = unquote(String(entry[entry.index(after: colon)...])), !value.isEmpty {
                ids.append(value)
            }
        }
        return ids
    }

    /// Render a YAML scalar, quoting whenever the plain form could be
    /// misread. Quoting is always valid YAML, so the only cost is a few
    /// characters of noise on values that happen to be safe either way.
    static func quote(_ value: String) -> String {
        let plainSafe = value.range(of: "^[A-Za-z0-9_./@+-]+$", options: .regularExpression) != nil
        let looksLikeNumber = Double(value) != nil
        let isReserved = ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(value.lowercased())
        if plainSafe, !looksLikeNumber, !isReserved {
            return value
        }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func unquote(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        // A trailing comment is only a comment after whitespace, per YAML.
        if let hash = value.range(of: " #") {
            value = String(value[value.startIndex..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            return inner
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value.isEmpty ? nil : value
    }
}
