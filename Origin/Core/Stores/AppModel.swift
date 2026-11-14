import Observation
import SwiftUI

@Observable
final class AppModel {
    let settings = AppSettings()
    let cloudSync = CloudSync()
    let downloads = DownloadManager()
    let browser = LocalServerBrowser()
    @ObservationIgnored lazy var player = PlayerPresenter(app: self)

    private(set) var accounts: [ServerAccount] = []
    private(set) var client: (any MediaServerClient)?
    private(set) var tmdb: TMDBClient
    /// 标记已看 / 收藏等操作后递增，通知各页面刷新
    private(set) var contentRevision = 0

    @ObservationIgnored private var clients: [UUID: any MediaServerClient] = [:]

    var activeAccountID: UUID? {
        didSet {
            UserDefaults.standard.set(activeAccountID?.uuidString, forKey: "activeAccount")
            client = activeAccountID.flatMap(client(for:))
        }
    }

    /// 下次打开软件时首页使用的服务器
    var defaultHomeID: UUID? {
        didSet { UserDefaults.standard.set(defaultHomeID?.uuidString, forKey: "defaultHome") }
    }

    /// 本次打开后已经通过认证的加密服务器
    private(set) var unlockedServerIDs: Set<UUID> = []

    var activeAccount: ServerAccount? {
        accounts.first { $0.id == activeAccountID }
    }

    init() {
        tmdb = TMDBClient(token: "")
        tmdb.token = settings.tmdbToken
        if let data = UserDefaults.standard.data(forKey: "accounts"),
           let saved = try? JSONDecoder().decode([ServerAccount].self, from: data) {
            accounts = saved
        }
        // 下载列表等页面可能在任何请求之前就加载封面，需要先登记各服务器的鉴权头
        for account in accounts { _ = client(for: account.id) }
        let savedID = UserDefaults.standard.string(forKey: "activeAccount").flatMap(UUID.init(uuidString:))
        let homeID = UserDefaults.standard.string(forKey: "defaultHome").flatMap(UUID.init(uuidString:))
        defaultHomeID = accounts.first { $0.id == homeID }?.id
        activeAccountID = accounts.first { $0.id == defaultHomeID }?.id
            ?? accounts.first { $0.id == savedID }?.id
            ?? accounts.first?.id
        settings.cloudSync = cloudSync
        cloudSync.start(app: self)
        // 启动时就开始找局域网服务器，打开添加页时列表已经在
        browser.start()
    }

    func isLocked(_ account: ServerAccount) -> Bool {
        account.isEncrypted && !unlockedServerIDs.contains(account.id)
    }

    /// 加密服务器先通过本机认证。已经解锁过的，这次打开里不再询问。
    func unlock(_ account: ServerAccount) async -> Bool {
        guard account.isEncrypted else { return true }
        if unlockedServerIDs.contains(account.id) { return true }
        let ok = await ServerLock.authenticate(reason: "解锁服务器“\(account.name)”")
        if ok {
            unlockedServerIDs.insert(account.id)
            contentChanged()
        }
        return ok
    }

    func setEncrypted(_ account: ServerAccount, _ encrypted: Bool) {
        var updated = account
        updated.isEncrypted = encrypted
        if encrypted { unlockedServerIDs.remove(account.id) }
        update(updated)
    }

    func setDefaultHome(_ account: ServerAccount) async {
        guard await unlock(account) else { return }
        defaultHomeID = account.id
        activeAccountID = account.id
    }

    /// 参与首页聚合的服务器。当前服务器关掉聚合时，首页只显示它自己。
    var homeAccounts: [ServerAccount] {
        guard let active = activeAccount, !isLocked(active) else { return [] }
        if active.aggregationDisabled { return [active] }
        let peers = accounts.filter { !$0.aggregationDisabled && !isLocked($0) }
        return peers.isEmpty ? [active] : peers
    }

    func applyResolvedLine(_ id: UUID, lineID: UUID?) {
        guard let index = accounts.firstIndex(where: { $0.id == id }), accounts[index].activeLineID != lineID else { return }
        var updated = accounts[index]
        updated.activeLineID = lineID
        update(updated)
    }

    func collectLibraries() async -> (libraries: [MediaLibrary], failure: String?) {
        let servers = homeAccounts
        let prefix = servers.count > 1
        var result: [MediaLibrary] = []
        var failure: String?
        for account in servers {
            guard let client = client(for: account.id) else { continue }
            do {
                let libraries = try await client.libraries()
                result.append(contentsOf: libraries.map { library in
                    var copy = library
                    copy.serverID = account.id
                    if prefix { copy.serverName = account.name }
                    return copy
                })
            } catch {
                if failure == nil { failure = error.localizedDescription }
            }
        }
        return (result, failure)
    }

    func client(for serverID: UUID) -> (any MediaServerClient)? {
        if let cached = clients[serverID] { return cached }
        guard let account = accounts.first(where: { $0.id == serverID }) else { return nil }
        let client: any MediaServerClient = account.kind == .plex ? PlexClient(account: account) : JellyfinClient(account: account)
        clients[serverID] = client
        for candidate in account.lineCandidates {
            MediaRequestAuth.register(candidate.url, headers: client.streamHeaders)
        }
        return client
    }

    func add(_ account: ServerAccount, token: String) {
        Keychain.set(token, for: account.id.uuidString, synchronizable: cloudSync.enabled)
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        clients[account.id] = nil
        persist()
        cloudSync.upsert(account)
        _ = client(for: account.id)
        activeAccountID = account.id
    }

    /// 修改名称、地址或登录用户；令牌不变时传 nil
    func update(_ account: ServerAccount, token: String? = nil) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        if let token { Keychain.set(token, for: account.id.uuidString, synchronizable: cloudSync.enabled) }
        accounts[index] = account
        clients[account.id] = nil
        persist()
        cloudSync.upsert(account)
        let refreshed = client(for: account.id)
        if activeAccountID == account.id { client = refreshed }
        contentChanged()
    }

    func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        persist()
        cloudSync.noteOrderChanged()
    }

    func remove(_ account: ServerAccount) {
        Keychain.set(nil, for: account.id.uuidString, synchronizable: cloudSync.enabled)
        accounts.removeAll { $0.id == account.id }
        clients[account.id] = nil
        persist()
        cloudSync.delete(account.id)
        unlockedServerIDs.remove(account.id)
        if defaultHomeID == account.id { defaultHomeID = accounts.first?.id }
        if activeAccountID == account.id {
            activeAccountID = accounts.first?.id
        }
    }

    func rename(_ account: ServerAccount, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].name = name
        persist()
        cloudSync.upsert(accounts[index])
    }

    /// 另一台设备合并过来的服务器列表。只更新本机，不再上传。
    func replaceAccountsFromSync(_ incoming: [ServerAccount]) {
        guard incoming != accounts else { return }
        let previous = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let incomingIDs = Set(incoming.map(\.id))
        for account in incoming where previous[account.id] != account {
            clients[account.id] = nil
        }
        for id in previous.keys where !incomingIDs.contains(id) {
            clients[id] = nil
            Keychain.set(nil, for: id.uuidString, synchronizable: true)
        }
        accounts = incoming
        persist()
        unlockedServerIDs.formIntersection(incomingIDs)
        if let defaultHomeID, !incomingIDs.contains(defaultHomeID) {
            self.defaultHomeID = incoming.first?.id
        }
        if let activeAccountID, !incomingIDs.contains(activeAccountID) {
            self.activeAccountID = self.defaultHomeID ?? incoming.first?.id
        } else if activeAccountID == nil {
            activeAccountID = defaultHomeID ?? incoming.first?.id
        } else if let activeAccountID {
            clients[activeAccountID] = nil
            client = client(for: activeAccountID)
        }
        for account in incoming { _ = client(for: account.id) }
        contentChanged()
    }

    func refreshClient(for id: UUID) {
        clients[id] = nil
        guard activeAccountID == id else { return }
        client = client(for: id)
        contentChanged()
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(accounts), forKey: "accounts")
    }

    func refreshTMDB() {
        tmdb = TMDBClient(token: settings.tmdbToken)
    }

    func contentChanged() {
        contentRevision += 1
    }

    // MARK: - 常用操作

    func togglePlayed(_ item: MediaItem) async throws {
        guard let client = client(for: item.serverID) else { return }
        try await client.setPlayed(!item.userState.isPlayed, item: item)
        contentChanged()
    }

    func toggleFavorite(_ item: MediaItem) async throws {
        guard let client = client(for: item.serverID) else { return }
        try await client.setFavorite(!item.userState.isFavorite, item: item)
        contentChanged()
    }
}
