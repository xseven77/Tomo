import Foundation

struct CodexPetArchive {
    private struct Entry: Decodable {
        let files: [String: Entry]?
        let offset: String?
        let size: Int?
    }

    let url: URL

    func importBuiltIns(into cache: URL) throws -> [CodexPet] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 16), header.count == 16 else { return [] }
        let headerSize = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
        let jsonSize = Int(header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian })
        guard jsonSize > 0, jsonSize <= 32_000_000, headerSize >= jsonSize + 8,
              let json = try handle.read(upToCount: jsonSize), json.count == jsonSize else { return [] }
        let root = try JSONDecoder().decode(Entry.self, from: json)
        let assets = root.files?["webview"]?.files?["assets"]?.files ?? [:]
        return try assets.keys.sorted().compactMap { name in
            guard let match = name.range(of: #"^[a-z0-9-]+-spritesheet-v[0-9]+\.[a-f0-9]+\.webp$"#, options: .regularExpression),
                  match == name.startIndex..<name.endIndex,
                  let separator = name.range(of: "-spritesheet-v", options: .backwards),
                  let entry = assets[name], let offset = entry.offset.flatMap(UInt64.init),
                  let size = entry.size, size > 0, size <= CodexPetLibrary.maxSpriteSize,
                  offset < UInt64.max - UInt64(headerSize) - 8 else { return nil }
            let assetID = String(name[..<separator.lowerBound])
            let target = cache.appendingPathComponent(assetID, isDirectory: true).appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: target.path) {
                try handle.seek(toOffset: UInt64(8 + headerSize) + offset)
                guard let data = try handle.read(upToCount: size), data.count == size else { return nil }
                try CodexPetLibrary.cacheSprite(data, at: target)
            }
            let title = assetID == "bsod" ? "BSOD" : assetID.replacingOccurrences(of: "-", with: " ").capitalized
            return CodexPetLibrary.makePet(id: "builtin:\(assetID)", assetID: assetID, name: title,
                                          description: "Codex 内置", source: .codexBuiltIn, sprite: target)
        }
    }
}

actor CodexPetLibrary {
    struct Snapshot: Sendable {
        var builtIns: [CodexPet] = []
        var accountPets: [CodexPet] = []
    }

    private struct Credentials: Decodable {
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String
        }
        let tokens: Tokens
    }

    private struct AccountPet: Decodable {
        let id: String
        let name: String
        let description: String?
        let spritesheet_url: URL?
        let updated_at: String?
        let is_custom: Bool?
    }

    private struct Page: Decodable {
        let pets: [AccountPet]
        let cursor: String?
    }

    private struct Download: Decodable {
        let spritesheet_url: URL
    }

    static let maxSpriteSize = 8 * 1024 * 1024
    static var cacheRoot: URL {
        CodexPetCatalog.defaultCustomPetsRoot.deletingLastPathComponent().appendingPathComponent("CodexPetCache")
    }

    private var snapshot = Snapshot()
    private var archiveURL: URL?
    private var archiveDate: Date?
    private var accountID: String?
    private var nextAccountPull = Date.distantPast
    private var previousSelection: String?

    func loadBuiltIns(applicationURL: URL) -> Snapshot {
        let archive = applicationURL.appendingPathComponent("Contents/Resources/app.asar")
        let modificationDate = try? archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if archive != archiveURL || modificationDate != archiveDate {
            snapshot.builtIns = (try? CodexPetArchive(url: archive)
                .importBuiltIns(into: Self.cacheRoot.appendingPathComponent("BuiltIn"))) ?? []
            archiveURL = archive
            archiveDate = modificationDate
        }
        return snapshot
    }

    func pullAccountPets(home: URL, selection: String?) async -> Snapshot {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")),
              let credentials = try? JSONDecoder().decode(Credentials.self, from: data).tokens else {
            accountID = nil
            snapshot.accountPets = []
            return snapshot
        }
        let changedAccount = credentials.account_id != accountID
        let changedSelection = selection != previousSelection
        previousSelection = selection
        if changedAccount {
            accountID = credentials.account_id
            snapshot.accountPets = []
        }
        guard changedAccount || (changedSelection && selection?.hasPrefix("pet_") == true) || Date() >= nextAccountPull else {
            return snapshot
        }
        nextAccountPull = Date().addingTimeInterval(60)
        if let pets = try? await fetchAccountPets(credentials, selection: selection) {
            snapshot.accountPets = pets
        }
        return snapshot
    }

    private func fetchAccountPets(_ credentials: Credentials.Tokens, selection: String?) async throws -> [CodexPet] {
        var records: [AccountPet] = []
        var seen = Set<String>()
        var cursor: String?
        repeat {
            let query = [URLQueryItem(name: "limit", value: "20")] +
                (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
            let page: Page = try await get("/pets", query: query, credentials: credentials)
            records += page.pets
            cursor = page.cursor
            if let cursor, !seen.insert(cursor).inserted { throw URLError(.badServerResponse) }
        } while cursor != nil

        let ordered = records.filter { $0.id == selection } + records.filter { $0.id != selection }
        var pets: [CodexPet] = []
        var ids = Set<String>()
        for record in ordered where record.is_custom != false && ids.insert(record.id).inserted {
            try Task.checkCancellation()
            guard record.id.range(of: #"^pet_[a-zA-Z0-9_-]+$"#, options: .regularExpression) != nil,
                  !CodexPetCatalog.hiddenTomoNames.contains(record.name.lowercased()) else { continue }
            let version = (record.updated_at ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let folder = Self.cacheRoot.appendingPathComponent("Account").appendingPathComponent(record.id)
            let sprite = folder.appendingPathComponent(version.isEmpty ? "spritesheet.webp" : "\(version).webp")
            if !FileManager.default.fileExists(atPath: sprite.path) {
                do {
                    let url: URL
                    if let suppliedURL = record.spritesheet_url {
                        url = suppliedURL
                    } else {
                        let download: Download = try await get("/pets/\(record.id)/download", credentials: credentials)
                        url = download.spritesheet_url
                    }
                    guard url.scheme == "https", url.user == nil, url.password == nil else { continue }
                    var request = URLRequest(url: url, timeoutInterval: 10)
                    request.httpShouldHandleCookies = false
                    let (data, response) = try await URLSession.tomoExternal.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          data.count <= Self.maxSpriteSize else { continue }
                    try Self.cacheSprite(data, at: sprite)
                } catch {
                    if let previous = snapshot.accountPets.first(where: { $0.id == record.id }) { pets.append(previous) }
                    continue
                }
            }
            if let pet = Self.makePet(id: record.id, assetID: record.id, name: record.name,
                                      description: record.description ?? "Codex 自定义", source: .custom, sprite: sprite) {
                pets.append(pet)
            }
        }
        return pets
    }

    private func get<Value: Decodable>(_ path: String, query: [URLQueryItem] = [],
                                       credentials: Credentials.Tokens) async throws -> Value {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "chatgpt.com"
        components.path = "/backend-api" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(credentials.access_token)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.account_id, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession.tomoExternal.data(for: request, delegate: ProviderProxyRedirectDelegate())
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    static func cacheSprite(_ data: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func makePet(id: String, assetID: String, name: String, description: String,
                        source: CodexPetSource, sprite: URL) -> CodexPet? {
        guard let dimensions = imageDimensions(at: sprite),
              dimensions.width == PetSpriteSheet.cellWidth * 8,
              dimensions.height % PetSpriteSheet.cellHeight == 0 else { return nil }
        let rows = dimensions.height / PetSpriteSheet.cellHeight
        guard rows >= 9 else { return nil }
        return CodexPet(id: id, assetID: assetID, displayName: name, description: description, source: source,
                        spriteVersionNumber: rows >= 11 ? 2 : 1, spritesheetURL: sprite, rowCount: rows)
    }
}
