import Foundation
import Observation
import Security
#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct SyncDevice: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var kind: String
    var seen: Date

    var symbol: String {
        switch kind {
        case "ipad": "ipad"
        case "iphone": "iphone"
        default: "macbook"
        }
    }
}

enum CloudSyncStatus: Equatable {
    case off
    case noAccount
    case synced
    case quota
}

/// 在同一 iCloud 账号的设备之间同步服务器和播放设置。
/// 偏好和服务器列表走键值存储，登录令牌走 iCloud 钥匙串。两边都先写本机，离线时不会丢。
/// 同一项以较新的时间戳为准；服务器按标识合并，删除用墓碑传递，避免整表覆盖丢掉另一台设备新加的服务器。
@Observable
final class CloudSync: NSObject {
    private(set) var status: CloudSyncStatus = .off
    private(set) var devices: [SyncDevice] = []

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            Task { @MainActor in
                if self.enabled {
                    self.store.synchronize()
                    self.bootstrap()
                } else {
                    self.status = .off
                }
            }
        }
    }

    /// 个人开发团队的描述文件不能包含 iCloud 能力，这时键值存储不会跨设备同步。
    var isAvailable: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil) != nil
    }

    var statusTitle: String {
        switch status {
        case .off: "已关闭"
        case .noAccount: "未登录 iCloud"
        case .synced: "已开启"
        case .quota: "iCloud 空间不足"
        }
    }

    var deviceKinds: [String] {
        var seen: [String] = []
        for device in devices where !seen.contains(device.kind) {
            seen.append(device.kind)
        }
        return seen
    }

    var footer: String {
        switch status {
        case .noAccount:
            "登录 iCloud 后，服务器和播放设置会同步到这个账号下的 iPhone、iPad 和 Mac。下载仍只留在这台设备。"
        case .quota:
            "iCloud 的同步空间已满，新的更改暂时无法上传。"
        default:
            "同步服务器、登录状态和播放设置。各设备可以各自选择当前服务器。观看进度由媒体服务器保存，下载不参与同步。"
        }
    }

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let store = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pendingSettings: [String: (value: Any, updatedAt: Date)] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
    @ObservationIgnored private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static let enabledKey = "serverSyncEnabled"
    private static let accountStampKey = "sync.accountStamps"
    private static let orderStampKey = "sync.accountOrderStamp"

    override init() {
        enabled = defaults.bool(forKey: Self.enabledKey)
        super.init()
    }

    func refreshNow() {
        guard enabled else { return }
        store.synchronize()
        pull(reason: nil)
        pushLocalSettings()
        pushSecrets()
    }

    func start(app: AppModel) {
        self.app = app
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(storeChanged), name: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: store)
        center.addObserver(self, selector: #selector(identityChanged), name: .NSUbiquityIdentityDidChange, object: nil)
        #if os(iOS)
        center.addObserver(self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(willResign), name: UIApplication.willResignActiveNotification, object: nil)
        #else
        center.addObserver(self, selector: #selector(becameActive), name: NSApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(willResign), name: NSApplication.willResignActiveNotification, object: nil)
        #endif
        guard enabled else {
            status = .off
            return
        }
        store.synchronize()
        bootstrap()
    }

    func pushSetting(key: String, value: Any, updatedAt: Date) {
        guard enabled else { return }
        pendingSettings[key] = (value, updatedAt)
        flushTask?.cancel()
        flushTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            self.flushSettings()
        }
    }

    func upsert(_ account: ServerAccount) {
        guard enabled else { return }
        let now = Date()
        setAccountStamp(now, for: account.id)
        write(AccountEnvelope(id: account.id, updatedAt: now, isDeleted: false, account: account))
        store.synchronize()
    }

    func delete(_ id: UUID) {
        guard enabled else { return }
        let now = Date()
        setAccountStamp(now, for: id)
        write(AccountEnvelope(id: id, updatedAt: now, isDeleted: true, account: nil))
        store.synchronize()
    }

    func noteOrderChanged() {
        guard enabled, let app else { return }
        writeOrder(app.accounts.map(\.id), updatedAt: Date())
        store.synchronize()
    }

    func flushSettings() {
        guard enabled, !pendingSettings.isEmpty else { return }
        let batch = pendingSettings
        pendingSettings.removeAll()
        for (key, entry) in batch {
            store.set([
                "updatedAt": entry.updatedAt.timeIntervalSince1970,
                "value": entry.value,
            ], forKey: settingKey(key))
        }
        store.synchronize()
        refreshStatus()
    }

    @objc nonisolated private func storeChanged(_ note: Notification) {
        let reason = note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
        Task { @MainActor in
            self.pull(reason: reason)
        }
    }

    @objc nonisolated private func identityChanged() {
        Task { @MainActor in
            self.bootstrap()
        }
    }

    @objc nonisolated private func becameActive() {
        Task { @MainActor in
            guard self.enabled else { return }
            self.store.synchronize()
            self.pull(reason: nil)
            self.pushSecrets()
        }
    }

    @objc nonisolated private func willResign() {
        Task { @MainActor in
            self.flushSettings()
        }
    }

    private func bootstrap() {
        guard enabled, app != nil else {
            refreshStatus()
            return
        }
        importLegacyPayload()
        pull(reason: nil)
        pushLocalSettings()
        pushSecrets()
        refreshStatus()
    }

    /// 旧版本把整份服务器列表和令牌放在同一个键里。拆成本机钥匙串和按服务器合并的记录后再删掉。
    private func importLegacyPayload() {
        guard let app, let data = store.data(forKey: "origin.servers"),
              let payload = try? JSONDecoder().decode(LegacyServerPayload.self, from: data) else { return }
        var merged = app.accounts
        for account in payload.accounts where !merged.contains(where: { $0.id == account.id }) {
            merged.append(account)
        }
        for (id, token) in payload.tokens where Keychain.string(for: id.uuidString) == nil {
            Keychain.set(token, for: id.uuidString, synchronizable: true)
        }
        if merged != app.accounts {
            app.replaceAccountsFromSync(merged)
        }
        store.removeObject(forKey: "origin.servers")
        store.synchronize()
    }

    private func pull(reason: Int?) {
        guard enabled, app != nil else { return }
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            status = .quota
            return
        }
        pullSettings()
        pullAccounts()
        pullSecrets()
        publishThisDevice()
        pullDevices()
        refreshStatus()
    }

    private func pullSettings() {
        guard let settings = app?.settings else { return }
        for key in settings.syncSnapshot().keys {
            guard let (remoteDate, value) = remoteSetting(key) else { continue }
            let localDate = settings.localStamp(for: key) ?? .distantPast
            guard remoteDate.timeIntervalSince(localDate) > 0.001 else { continue }
            settings.applyRemoteSetting(key, value: value, updatedAt: remoteDate)
        }
    }

    private func pushLocalSettings() {
        guard let settings = app?.settings else { return }
        for (key, value) in settings.syncSnapshot() {
            let localDate = settings.localStamp(for: key)
            let remoteDate = remoteSetting(key)?.date
            if let localDate, remoteDate == nil || localDate.timeIntervalSince(remoteDate ?? .distantPast) > 0.001 {
                pendingSettings[key] = (value, localDate)
            } else if localDate == nil, remoteDate == nil, !Self.plistEqual(value, AppSettings.factory[key]) {
                let now = Date()
                settings.adoptStamp(key, now)
                pendingSettings[key] = (value, now)
            }
        }
        flushSettings()
    }

    private func pullAccounts() {
        guard let app else { return }
        let plan = AccountSyncPlanner.plan(
            local: LocalAccountState(
                accounts: app.accounts,
                stamps: accountStamps(),
                orderUpdatedAt: AppSettings.date(defaults.object(forKey: Self.orderStampKey))
            ),
            remote: remoteAccounts(),
            remoteOrder: remoteOrder()
        )
        saveAccountStamps(plan.stamps)
        if let orderUpdatedAt = plan.orderUpdatedAt {
            defaults.set(orderUpdatedAt.timeIntervalSince1970, forKey: Self.orderStampKey)
        }
        if plan.accounts != app.accounts {
            app.replaceAccountsFromSync(plan.accounts)
        }
        for envelope in plan.uploads {
            write(envelope)
        }
        if plan.uploadOrder {
            writeOrder(plan.accounts.map(\.id), updatedAt: plan.orderUpdatedAt ?? Date())
        }
        if !plan.uploads.isEmpty || plan.uploadOrder {
            store.synchronize()
        }
    }

    private func pullSecrets() {
        guard let app else { return }
        if let token = Keychain.synchronizableString(for: "tmdb-token"), token != app.settings.customTMDBToken {
            app.settings.applyRemoteTMDBToken(token)
            app.refreshTMDB()
        }
        for account in app.accounts {
            guard let token = Keychain.synchronizableString(for: account.id.uuidString) else { continue }
            if Keychain.string(for: account.id.uuidString) != token {
                Keychain.set(token, for: account.id.uuidString, synchronizable: true)
                app.refreshClient(for: account.id)
            }
        }
    }

    private func pushSecrets() {
        guard enabled, let app else { return }
        let token = app.settings.customTMDBToken
        if !token.isEmpty {
            Keychain.set(token, for: "tmdb-token", synchronizable: true)
        }
        for account in app.accounts {
            if let token = account.token {
                Keychain.set(token, for: account.id.uuidString, synchronizable: true)
            }
        }
    }

    private func refreshStatus() {
        guard enabled else {
            status = .off
            return
        }
        if status == .quota { return }
        status = FileManager.default.ubiquityIdentityToken == nil ? .noAccount : .synced
    }

    private func remoteSetting(_ key: String) -> (date: Date, value: Any)? {
        guard let entry = store.dictionary(forKey: settingKey(key)),
              let date = AppSettings.date(entry["updatedAt"]),
              let value = entry["value"]
        else { return nil }
        return (date, value)
    }

    private func remoteAccounts() -> [RemoteAccountState] {
        store.dictionaryRepresentation.compactMap { key, value in
            guard key.hasPrefix("account.item."), let data = value as? Data, let id = UUID(uuidString: String(key.dropFirst("account.item.".count))) else { return nil }
            guard let envelope = try? decoder.decode(AccountEnvelope.self, from: data) else { return nil }
            return RemoteAccountState(id: id, updatedAt: envelope.updatedAt, isDeleted: envelope.isDeleted, account: envelope.account)
        }
    }

    private func remoteOrder() -> OrderEnvelope? {
        guard let data = store.data(forKey: "account.order") else { return nil }
        return try? decoder.decode(OrderEnvelope.self, from: data)
    }

    private func write(_ envelope: AccountEnvelope) {
        guard let data = try? encoder.encode(envelope) else { return }
        store.set(data, forKey: accountKey(envelope.id))
    }

    private func writeOrder(_ ids: [UUID], updatedAt: Date) {
        defaults.set(updatedAt.timeIntervalSince1970, forKey: Self.orderStampKey)
        guard let data = try? encoder.encode(OrderEnvelope(updatedAt: updatedAt, ids: ids)) else { return }
        store.set(data, forKey: "account.order")
    }

    private func accountStamps() -> [UUID: Date] {
        guard let raw = defaults.dictionary(forKey: Self.accountStampKey) else { return [:] }
        var stamps: [UUID: Date] = [:]
        for (key, value) in raw {
            guard let id = UUID(uuidString: key), let date = AppSettings.date(value) else { continue }
            stamps[id] = date
        }
        return stamps
    }

    private func saveAccountStamps(_ stamps: [UUID: Date]) {
        let raw = Dictionary(uniqueKeysWithValues: stamps.map { ($0.key.uuidString, $0.value.timeIntervalSince1970) })
        defaults.set(raw, forKey: Self.accountStampKey)
    }

    private func setAccountStamp(_ date: Date, for id: UUID) {
        var stamps = accountStamps()
        stamps[id] = date
        saveAccountStamps(stamps)
    }

    private func publishThisDevice() {
        guard enabled else { return }
        let device = SyncDevice(id: DeviceInfo.deviceID, name: DeviceInfo.deviceName, kind: Self.thisKind, seen: Date())
        guard let data = try? encoder.encode(device) else { return }
        store.set(data, forKey: "device.\(device.id)")
    }

    private func pullDevices() {
        let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        devices = store.dictionaryRepresentation.compactMap { key, value in
            guard key.hasPrefix("device."), let data = value as? Data else { return nil }
            return try? decoder.decode(SyncDevice.self, from: data)
        }
        .filter { $0.seen > cutoff }
        .sorted { $0.seen > $1.seen }
    }

    private static var thisKind: String {
        #if os(macOS)
        "mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    private func settingKey(_ key: String) -> String { "setting.\(key)" }
    private func accountKey(_ id: UUID) -> String { "account.item.\(id.uuidString)" }

    private static func plistEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case let (left as String, right as String): left == right
        case let (left as Bool, right as Bool): left == right
        case let (left as Int, right as Int): left == right
        case let (left as Double, right as Double): left == right
        case let (left as NSNumber, right as NSNumber): left == right
        default: false
        }
    }
}

private struct LegacyServerPayload: Codable {
    var accounts: [ServerAccount]
    var tokens: [UUID: String]
}

private struct AccountEnvelope: Codable {
    var id: UUID
    var updatedAt: Date
    var isDeleted: Bool
    var account: ServerAccount?
}

private struct OrderEnvelope: Codable {
    var updatedAt: Date
    var ids: [UUID]
}

private struct LocalAccountState {
    var accounts: [ServerAccount]
    var stamps: [UUID: Date]
    var orderUpdatedAt: Date?
}

private struct RemoteAccountState {
    var id: UUID
    var updatedAt: Date
    var isDeleted: Bool
    var account: ServerAccount?
}

private struct AccountSyncPlan {
    var accounts: [ServerAccount]
    var stamps: [UUID: Date]
    var orderUpdatedAt: Date?
    var uploads: [AccountEnvelope]
    var uploadOrder: Bool
}

/// 按时间戳合并服务器。没有时间戳的本机记录视为更旧，这样另一台设备已有的资料不会被出厂空列表盖掉。
private enum AccountSyncPlanner {
    static func plan(local: LocalAccountState, remote: [RemoteAccountState], remoteOrder: OrderEnvelope?) -> AccountSyncPlan {
        var byID = Dictionary(uniqueKeysWithValues: local.accounts.map { ($0.id, $0) })
        var stamps = local.stamps
        var uploads: [AccountEnvelope] = []

        for item in remote {
            let localDate = stamps[item.id] ?? .distantPast
            if item.updatedAt.timeIntervalSince(localDate) > 0.001 {
                stamps[item.id] = item.updatedAt
                if item.isDeleted || item.account == nil {
                    byID[item.id] = nil
                } else if let account = item.account, account.id == item.id {
                    byID[item.id] = account
                }
            } else if let account = byID[item.id], localDate.timeIntervalSince(item.updatedAt) > 0.001 {
                uploads.append(AccountEnvelope(id: account.id, updatedAt: localDate, isDeleted: false, account: account))
            }
        }

        for account in byID.values where !remote.contains(where: { $0.id == account.id }) {
            let stamp = stamps[account.id] ?? Date()
            stamps[account.id] = stamp
            uploads.append(AccountEnvelope(id: account.id, updatedAt: stamp, isDeleted: false, account: account))
        }

        let deduped = dedupe(byID, stamps: stamps)
        byID = deduped.kept
        stamps = deduped.stamps
        uploads.append(contentsOf: deduped.tombstones)

        let remoteOrderWins = remoteOrder.map { remote in
            remote.updatedAt.timeIntervalSince(local.orderUpdatedAt ?? .distantPast) > 0.001
        } ?? false
        let orderIDs = remoteOrderWins ? remoteOrder?.ids ?? [] : local.accounts.map(\.id)
        var ordered: [ServerAccount] = []
        var seen = Set<UUID>()
        for id in orderIDs {
            guard let account = byID[id], seen.insert(id).inserted else { continue }
            ordered.append(account)
        }
        for id in byID.keys.sorted(by: { $0.uuidString < $1.uuidString }) where seen.insert(id).inserted {
            if let account = byID[id] { ordered.append(account) }
        }

        let orderUpdatedAt: Date?
        let uploadOrder: Bool
        if remoteOrderWins {
            orderUpdatedAt = remoteOrder?.updatedAt
            uploadOrder = false
        } else if local.orderUpdatedAt == nil, remoteOrder == nil, !ordered.isEmpty {
            orderUpdatedAt = Date()
            uploadOrder = true
        } else if let localDate = local.orderUpdatedAt, localDate.timeIntervalSince(remoteOrder?.updatedAt ?? .distantPast) > 0.001 {
            orderUpdatedAt = localDate
            uploadOrder = true
        } else {
            orderUpdatedAt = local.orderUpdatedAt
            uploadOrder = false
        }

        return AccountSyncPlan(
            accounts: ordered,
            stamps: stamps,
            orderUpdatedAt: orderUpdatedAt,
            uploads: uploads,
            uploadOrder: uploadOrder
        )
    }

    private static func dedupe(_ accounts: [UUID: ServerAccount], stamps: [UUID: Date]) -> (kept: [UUID: ServerAccount], stamps: [UUID: Date], tombstones: [AccountEnvelope]) {
        var grouped: [String: [ServerAccount]] = [:]
        for account in accounts.values {
            let key = "\(account.kind.rawValue)|\(account.baseURL.absoluteString)|\(account.username)"
            grouped[key, default: []].append(account)
        }
        var kept = accounts
        var stamps = stamps
        var tombstones: [AccountEnvelope] = []
        for group in grouped.values where group.count > 1 {
            let winner = group.max { lhs, rhs in
                (stamps[lhs.id] ?? .distantPast) < (stamps[rhs.id] ?? .distantPast)
            }
            guard let winner else { continue }
            for loser in group where loser.id != winner.id {
                kept[loser.id] = nil
                let stamp = Date()
                stamps[loser.id] = stamp
                tombstones.append(AccountEnvelope(id: loser.id, updatedAt: stamp, isDeleted: true, account: nil))
                if Keychain.string(for: winner.id.uuidString) == nil, let token = Keychain.string(for: loser.id.uuidString) {
                    Keychain.set(token, for: winner.id.uuidString, synchronizable: true)
                }
            }
        }
        return (kept, stamps, tombstones)
    }
}
