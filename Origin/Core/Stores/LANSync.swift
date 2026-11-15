import CryptoKit
import Foundation
import Network
import Observation
import Security
#if os(iOS)
import UIKit
#endif

/// 局域网里另一台装了 Origin 的设备
struct LANPeer: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: String
    var isConnected = false

    var symbol: String { SyncDevice(id: id, name: name, kind: kind, seen: .now).symbol }
}

/// 交给另一台设备接着播放的内容。服务器在各设备上同步过来，标识相同，对方直接向同一台服务器请求。
struct LANPlayback: Codable, Hashable {
    var serverID: UUID
    var itemID: String
    var sourceID: String?
    var position: TimeInterval
}

/// 另一台设备发来的配对请求，等本机用户确认
struct LANPairRequest: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var code: String
}

/// 同一局域网的 iPhone、iPad、Mac 之间直接同步服务器、登录令牌和播放设置，改动立刻送到，不经过 iCloud。
/// 打开的设备会互相发现。点一下附近的设备发起配对，对方核对两边显示的 6 位数字后允许，双方就拿到同一把组密钥；
/// 之后的连接都用它做 TLS 预共享密钥，组外的设备连不上也看不到内容。
/// 配对用临时密钥交换，发起方先提交公钥的哈希再公开公钥，中间人没法凑出两边相同的数字。
@Observable
final class LANSync {
    enum Pairing: Equatable {
        case idle
        /// 本机发起了配对，等对方确认。数字算出来之前 code 为空
        case waiting(name: String, code: String?)
        case paired(name: String)
        case failed(String)
    }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            defaults.set(enabled, forKey: Self.enabledKey)
            if enabled { startServices() } else { stopServices() }
        }
    }

    /// 已配对、在这个网络里出现过的设备
    private(set) var peers: [LANPeer] = []
    /// 附近打开了 Origin、还没和本机配对的设备
    private(set) var nearby: [LANPeer] = []
    private(set) var pairing: Pairing = .idle
    /// 等本机确认的配对请求
    private(set) var request: LANPairRequest?
    private(set) var isPaired: Bool
    private(set) var lastSynced: Date?
    /// 系统没给本地网络权限
    private(set) var isBlocked = false

    var connectedCount: Int { peers.filter(\.isConnected).count }

    var statusTitle: String {
        guard enabled else { return "已关闭" }
        guard isPaired else { return "未配对" }
        let count = connectedCount
        return count > 0 ? "已连接 \(count) 台" : "等待设备"
    }

    /// 同组设备让本机接着播放
    @ObservationIgnored var onPlayback: ((LANPlayback) -> Void)?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var groupKey: Data?
    @ObservationIgnored private var syncListener: NWListener?
    @ObservationIgnored private var syncBrowser: NWBrowser?
    @ObservationIgnored private var pairBrowser: NWBrowser?
    @ObservationIgnored private var pairListener: NWListener?
    @ObservationIgnored private var pairLink: PeerLink?
    @ObservationIgnored private var pairTimeout: Task<Void, Never>?
    @ObservationIgnored private var rejectedUntil: [String: Date] = [:]
    @ObservationIgnored private var links: [ObjectIdentifier: PeerLink] = [:]
    @ObservationIgnored private var discovered: [String: (peer: LANPeer, target: LANTarget)] = [:]
    @ObservationIgnored private var pairResults: Set<NWBrowser.Result> = []
    @ObservationIgnored private var pairEndpoints: [String: LANTarget] = [:]
    @ObservationIgnored private var broadcastTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false

    private static let enabledKey = "lanSyncEnabled"
    private static let groupKeyName = "origin.lan-group-key"
    private static let syncService = "_originsync._tcp"
    private static let pairService = "_originpair._tcp"

    init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        let key = Keychain.data(for: Self.groupKeyName)
        groupKey = key
        isPaired = key != nil
    }

    func start(app: AppModel) {
        self.app = app
        app.cloudSync.localChangeHandler = { [weak self] in self?.scheduleBroadcast() }
        guard !started else { return }
        started = true
        #if os(iOS)
        // 回到前台时系统可能已经断开了后台的连接，重新发现一遍
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartServices() }
        }
        #endif
        if enabled { startServices() }
    }

    /// 让已连接的同组设备从这个位置接着播放
    @discardableResult
    func handOff(_ playback: LANPlayback, to peerID: String) -> Bool {
        guard enabled, let data = try? JSONEncoder().encode(playback),
              let link = links.values.first(where: { $0.peerID == peerID && $0.device != nil }) else { return false }
        link.send(LANMessage(kind: .play, data: data))
        return true
    }

    // MARK: - 配对

    /// 向附近的设备发起配对，对方确认后两边加入同一个同步组。
    func requestPairing(with peer: LANPeer) {
        guard enabled else { return }
        guard let target = pairEndpoints[peer.id] else {
            pairing = .failed("“\(peer.name)”已经不在附近")
            return
        }
        cancelPairing()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let link = PeerLink(connection: NWConnection(to: target.endpoint, using: Self.pairParameters(on: target.interface)), outgoing: true, peerID: peer.id)
        link.ephemeral = ephemeral
        link.onReady = { [weak self, weak link] in
            guard let self, let link else { return }
            let commitment = Data(SHA256.hash(data: ephemeral.publicKey.rawRepresentation))
            link.send(LANMessage(kind: .request, device: self.thisDevice, data: commitment))
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.handleRequesterMessage(message, link: link, peer: peer)
        }
        link.onClose = { [weak self, weak link] in
            guard let self, let link, self.pairLink === link else { return }
            self.pairLink = nil
            self.pairTimeout?.cancel()
            if !link.succeeded, case .waiting = self.pairing {
                self.pairing = .failed("没能和“\(peer.name)”配对，请确认对方打开了 Origin")
            }
        }
        pairLink = link
        pairing = .waiting(name: peer.name, code: nil)
        link.start()
        pairTimeout = Task { [weak self, weak link] in
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self, let link, !link.succeeded else { return }
            self.pairing = .failed("“\(peer.name)”没有回应")
            link.close()
        }
    }

    func cancelPairing() {
        pairTimeout?.cancel()
        pairTimeout = nil
        if let link = pairLink {
            pairLink = nil
            link.onClose = nil
            link.close()
        }
        request = nil
        if case .waiting = pairing { pairing = .idle }
    }

    func dismissPairingResult() {
        switch pairing {
        case .paired, .failed: pairing = .idle
        default: break
        }
    }

    /// 回应另一台设备的配对请求
    func respond(allow: Bool) {
        guard request != nil, let link = pairLink else { return }
        request = nil
        pairTimeout?.cancel()
        guard allow else {
            // 拒绝后短时间内不再接受同一台设备的请求，免得被反复弹窗
            if let id = link.device?.id { rejectedUntil[id] = Date().addingTimeInterval(60) }
            link.send(LANMessage(kind: .reject))
            closeSoon(link)
            return
        }
        // 已在组里的一方的密钥优先；两边都有时用确认这一方的
        let key = groupKey ?? (link.offered?.count == 32 ? link.offered : nil) ?? SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        guard let session = link.session, let sealed = Self.seal(key, with: session) else {
            link.close()
            return
        }
        link.succeeded = true
        link.send(LANMessage(kind: .done, device: thisDevice, data: sealed))
        pairing = .paired(name: link.device?.name ?? "另一台设备")
        adopt(key)
    }

    /// 退出同步组。其他设备之间照常同步，这台以后要重新配对。
    func leaveGroup() {
        Keychain.setData(nil, for: Self.groupKeyName, synchronizable: false)
        groupKey = nil
        isPaired = false
        lastSynced = nil
        restartServices()
    }

    private func handleRequesterMessage(_ message: LANMessage, link: PeerLink, peer: LANPeer) {
        switch message.kind {
        case .pair:
            guard let ephemeral = link.ephemeral, let targetKey = message.publicKey,
                  let secrets = Self.pairingSecrets(ephemeral, peer: targetKey,
                                                    requester: ephemeral.publicKey.rawRepresentation, target: targetKey),
                  let sealed = Self.seal(groupKey ?? Data(), with: secrets.session)
            else { link.close(); return }
            link.session = secrets.session
            link.send(LANMessage(kind: .reveal, data: sealed, publicKey: ephemeral.publicKey.rawRepresentation))
            pairing = .waiting(name: peer.name, code: secrets.code)
        case .done:
            guard let session = link.session, let sealed = message.data,
                  let key = Self.open(sealed, with: session), key.count == 32 else {
                link.close()
                return
            }
            link.succeeded = true
            pairTimeout?.cancel()
            pairing = .paired(name: peer.name)
            adopt(key)
            link.close()
        case .reject:
            pairing = .failed("“\(peer.name)”拒绝了配对")
            link.close()
        default:
            break
        }
    }

    private func acceptPairing(_ connection: NWConnection) {
        // 同一时间只处理一个配对
        guard pairLink == nil, request == nil else {
            connection.cancel()
            return
        }
        let link = PeerLink(connection: connection, outgoing: false, peerID: nil)
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.handleTargetMessage(message, link: link)
        }
        link.onClose = { [weak self, weak link] in
            guard let self, let link, self.pairLink === link else { return }
            self.pairLink = nil
            // 对方取消或断开，收起确认框
            if !link.succeeded {
                self.request = nil
                self.pairTimeout?.cancel()
            }
        }
        pairLink = link
        link.start()
        // 连上后迟迟不发请求的连接会一直占着配对位置
        pairTimeout?.cancel()
        pairTimeout = Task { [weak self, weak link] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, let link, self.pairLink === link, self.request == nil, !link.succeeded else { return }
            link.close()
        }
    }

    private func handleTargetMessage(_ message: LANMessage, link: PeerLink) {
        switch message.kind {
        case .request:
            guard let device = message.device, device.id != DeviceInfo.deviceID,
                  let commitment = message.data, commitment.count == 32 else {
                link.close()
                return
            }
            if let until = rejectedUntil[device.id], until > Date() {
                link.send(LANMessage(kind: .reject))
                closeSoon(link)
                return
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            link.device = device
            link.commitment = commitment
            link.ephemeral = ephemeral
            link.send(LANMessage(kind: .pair, publicKey: ephemeral.publicKey.rawRepresentation))
        case .reveal:
            guard let ephemeral = link.ephemeral, let commitment = link.commitment, let device = link.device,
                  let requesterKey = message.publicKey, Data(SHA256.hash(data: requesterKey)) == commitment,
                  let secrets = Self.pairingSecrets(ephemeral, peer: requesterKey,
                                                    requester: requesterKey, target: ephemeral.publicKey.rawRepresentation),
                  let sealed = message.data, let offered = Self.open(sealed, with: secrets.session)
            else { link.close(); return }
            link.session = secrets.session
            link.offered = offered
            request = LANPairRequest(name: device.name, code: secrets.code)
            pairTimeout?.cancel()
            pairTimeout = Task { [weak self, weak link] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self, let link, self.pairLink === link, !link.succeeded else { return }
                self.request = nil
                link.close()
            }
        default:
            break
        }
    }

    /// 先让对方收到最后一条消息再断开；对方通常会先断
    private func closeSoon(_ link: PeerLink) {
        Task { [weak link] in
            try? await Task.sleep(for: .seconds(2))
            link?.close()
        }
    }

    private func adopt(_ key: Data) {
        guard key != groupKey else { return }
        Keychain.setData(key, for: Self.groupKeyName, synchronizable: false)
        groupKey = key
        isPaired = true
        restartServices()
    }

    // MARK: - 发现与连接

    private func startServices() {
        guard app != nil else { return }
        startPairListener()
        startPairBrowser()
        startSync()
    }

    private func stopServices() {
        cancelPairing()
        stopPairing()
        stopSync()
        restartTask?.cancel()
        isBlocked = false
    }

    /// 重建广播和连接。正在进行的配对连接不受影响，组密钥变了广播内容也跟着变。
    private func restartServices() {
        guard enabled else { return }
        stopPairing()
        stopSync()
        startServices()
    }

    private func stopPairing() {
        pairListener?.cancel()
        pairListener = nil
        pairBrowser?.cancel()
        pairBrowser = nil
        pairResults = []
        pairEndpoints = [:]
        nearby = []
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self.restartServices()
        }
    }

    private func startPairListener() {
        guard pairListener == nil, let listener = try? NWListener(using: Self.pairParameters(on: nil)) else { return }
        listener.service = NWListener.Service(
            name: DeviceInfo.deviceID, type: Self.pairService, txtRecord: txtRecord(group: groupKey.map(Self.fingerprint))
        )
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.acceptPairing(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.pairListener === listener, case let .failed(error) = state else { return }
                if Self.isDenied(error) { self.isBlocked = true }
                self.scheduleRestart()
            }
        }
        listener.start(queue: .main)
        pairListener = listener
    }

    private func startSync() {
        guard let groupKey, syncListener == nil else { return }
        let parameters = Self.parameters(secret: groupKey, label: "origin-sync", on: nil)
        guard let listener = try? NWListener(using: parameters) else {
            scheduleRestart()
            return
        }
        listener.service = NWListener.Service(
            name: DeviceInfo.deviceID, type: Self.syncService, txtRecord: txtRecord(group: Self.fingerprint(groupKey))
        )
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.attach(PeerLink(connection: connection, outgoing: false, peerID: nil)) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.syncListener === listener, case .failed = state else { return }
                self.scheduleRestart()
            }
        }
        listener.start(queue: .main)
        syncListener = listener

        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.syncService, domain: nil), using: Self.browseParameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.syncResultsChanged(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.syncBrowser === browser else { return }
                self.browserChanged(state)
            }
        }
        browser.start(queue: .main)
        syncBrowser = browser
    }

    private func stopSync() {
        broadcastTask?.cancel()
        syncListener?.cancel()
        syncListener = nil
        syncBrowser?.cancel()
        syncBrowser = nil
        for link in links.values {
            link.onClose = nil
            link.close()
        }
        links = [:]
        discovered = [:]
        peers = []
    }

    private func startPairBrowser() {
        guard pairBrowser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.pairService, domain: nil), using: Self.browseParameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.pairResults = results
                self?.refreshNearby()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.pairBrowser === browser else { return }
                self.browserChanged(state)
            }
        }
        browser.start(queue: .main)
        pairBrowser = browser
    }

    private func browserChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            isBlocked = false
        case let .waiting(error):
            if Self.isDenied(error) { isBlocked = true }
        case let .failed(error):
            if Self.isDenied(error) { isBlocked = true }
            scheduleRestart()
        default:
            break
        }
    }

    /// 没有本地网络权限，或系统认为 Info.plist 没声明这个 Bonjour 服务
    private static func isDenied(_ error: NWError) -> Bool {
        guard case let .dns(code) = error else { return false }
        return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) || code == DNSServiceErrorType(kDNSServiceErr_NoAuth)
    }

    /// 附近的设备里去掉已经同组的，剩下的可以配对
    private func refreshNearby() {
        let group = groupKey.map(Self.fingerprint)
        var endpoints: [String: LANTarget] = [:]
        var list: [String: LANPeer] = [:]
        for result in pairResults {
            guard case let .bonjour(txt) = result.metadata, let peer = Self.peer(from: result) else { continue }
            let target = LANTarget(result)
            if let existing = endpoints[peer.id], existing.rank <= target.rank { continue }
            endpoints[peer.id] = target
            if let group, txt["group"] == group { continue }
            list[peer.id] = peer
        }
        pairEndpoints = endpoints
        nearby = list.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func syncResultsChanged(_ results: Set<NWBrowser.Result>) {
        guard let groupKey else { return }
        let group = Self.fingerprint(groupKey)
        var found: [String: (peer: LANPeer, target: LANTarget)] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata, txt["group"] == group, let peer = Self.peer(from: result) else { continue }
            let target = LANTarget(result)
            if let existing = found[peer.id], existing.target.rank <= target.rank { continue }
            found[peer.id] = (peer, target)
        }
        discovered = found
        connectDiscovered()
        refreshPeers()
    }

    /// 两台设备之间只由标识较小的一方发起连接，免得同时连对方、出现两条连接。
    private func connectDiscovered() {
        guard enabled, let groupKey else { return }
        for (id, entry) in discovered where DeviceInfo.deviceID < id && !links.values.contains(where: { $0.peerID == id }) {
            let connection = NWConnection(
                to: entry.target.endpoint,
                using: Self.parameters(secret: groupKey, label: "origin-sync", on: entry.target.interface)
            )
            attach(PeerLink(connection: connection, outgoing: true, peerID: id))
        }
    }

    private func attach(_ link: PeerLink) {
        links[ObjectIdentifier(link)] = link
        link.onReady = { [weak self, weak link] in
            guard let self, let link else { return }
            link.send(LANMessage(kind: .hello, device: self.thisDevice))
            if let data = self.app?.cloudSync.peerPayload() {
                link.send(LANMessage(kind: .state, data: data))
            }
        }
        link.onMessage = { [weak self, weak link] message in
            guard let self, let link else { return }
            self.handleSync(message, link: link)
        }
        link.onClose = { [weak self, weak link] in
            guard let self, let link else { return }
            self.links[ObjectIdentifier(link)] = nil
            self.refreshPeers()
            guard link.outgoing else { return }
            Task {
                try? await Task.sleep(for: .seconds(3))
                self.connectDiscovered()
            }
        }
        link.start()
    }

    private func handleSync(_ message: LANMessage, link: PeerLink) {
        switch message.kind {
        case .hello:
            guard let device = message.device, device.id != DeviceInfo.deviceID else {
                link.close()
                return
            }
            // 对方重连时旧连接可能还没断，以新的为准
            for other in links.values where other !== link && other.peerID == device.id {
                other.onClose = nil
                other.close()
                links[ObjectIdentifier(other)] = nil
            }
            link.peerID = device.id
            link.device = device
            refreshPeers()
        case .state:
            guard let data = message.data else { return }
            app?.cloudSync.applyPeerPayload(data)
            lastSynced = Date()
        case .play:
            guard link.device != nil, let data = message.data,
                  let playback = try? JSONDecoder().decode(LANPlayback.self, from: data) else { return }
            onPlayback?(playback)
        default:
            break
        }
    }

    private func refreshPeers() {
        var list: [String: LANPeer] = [:]
        for (id, entry) in discovered { list[id] = entry.peer }
        for link in links.values {
            guard let id = link.peerID, let device = link.device else { continue }
            var peer = list[id] ?? LANPeer(id: id, name: device.name, kind: device.kind)
            peer.isConnected = true
            list[id] = peer
        }
        peers = list.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func scheduleBroadcast() {
        guard enabled, !links.isEmpty else { return }
        broadcastTask?.cancel()
        broadcastTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let data = self.app?.cloudSync.peerPayload() else { return }
            var sent = false
            for link in self.links.values where link.device != nil {
                link.send(LANMessage(kind: .state, data: data))
                sent = true
            }
            if sent { self.lastSynced = Date() }
        }
    }

    // MARK: - 工具

    private var thisDevice: SyncDevice {
        SyncDevice(id: DeviceInfo.deviceID, name: DeviceInfo.deviceName, kind: CloudSync.thisKind, seen: Date())
    }

    private func txtRecord(group: String?) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["id"] = DeviceInfo.deviceID
        txt["name"] = DeviceInfo.deviceName
        txt["kind"] = CloudSync.thisKind
        if let group { txt["group"] = group }
        return txt
    }

    private static func peer(from result: NWBrowser.Result) -> LANPeer? {
        guard case let .bonjour(txt) = result.metadata, let id = txt["id"], id != DeviceInfo.deviceID else { return nil }
        return LANPeer(id: id, name: txt["name"] ?? "设备", kind: txt["kind"] ?? "mac")
    }

    /// 组密钥的指纹，放在 Bonjour 广播里，用来认出同组设备。只取哈希的一部分，看不出密钥本身。
    private static func fingerprint(_ key: Data) -> String {
        SHA256.hash(data: key + Data("origin-group".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 只走 Wi-Fi 和有线网。代理软件的虚拟网卡、VPN 和蜂窝网连不到局域网里的设备，
    /// 系统先试到它们时要等超时才换下一条，配对请求会慢几十秒。
    private static func localOnly(_ parameters: NWParameters, on interface: NWInterface?) -> NWParameters {
        parameters.prohibitedInterfaceTypes = [.other, .cellular]
        if let interface { parameters.requiredInterface = interface }
        return parameters
    }

    private static var browseParameters: NWParameters { localOnly(NWParameters(), on: nil) }

    /// 配对连接本身不加密，靠临时密钥交换和两边核对的数字保证安全
    private static func pairParameters(on interface: NWInterface?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        return localOnly(NWParameters(tls: nil, tcp: tcp), on: interface)
    }

    /// TLS 1.2 预共享密钥连接。两端用同一份 secret 才能握手成功。
    private static func parameters(secret: Data, label: String, on interface: NWInterface?) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let psk = Data(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: SymmetricKey(data: secret)))
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(label.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // 恢复会话时不再核对预共享密钥，换过组密钥后旧会话仍能连上，所以每次都完整握手
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 10
        return localOnly(NWParameters(tls: tls, tcp: tcp), on: interface)
    }

    /// 配对用的会话密钥和两边显示的 6 位数字
    private static func pairingSecrets(
        _ ephemeral: Curve25519.KeyAgreement.PrivateKey, peer: Data, requester: Data, target: Data
    ) -> (session: SymmetricKey, code: String)? {
        guard let publicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: publicKey) else { return nil }
        let salt = requester + target
        let session = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("origin-pair".utf8), outputByteCount: 32
        )
        let check = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: salt, sharedInfo: Data("origin-pair-code".utf8), outputByteCount: 4
        )
        let value = check.withUnsafeBytes { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } } % 1_000_000
        return (session, String(format: "%06d", value))
    }

    private static func seal(_ data: Data, with key: SymmetricKey) -> Data? {
        try? ChaChaPoly.seal(data, using: key).combined
    }

    private static func open(_ data: Data, with key: SymmetricKey) -> Data? {
        guard let box = try? ChaChaPoly.SealedBox(combined: data) else { return nil }
        return try? ChaChaPoly.open(box, using: key)
    }
}

/// 发现到的设备地址，以及发现它的那块网卡。连接时绑定这块网卡，不用挨个试别的
private struct LANTarget {
    var endpoint: NWEndpoint
    var interface: NWInterface?

    init(_ result: NWBrowser.Result) {
        endpoint = result.endpoint
        var candidates = result.interfaces
        if case let .service(_, _, _, interface?) = result.endpoint { candidates.append(interface) }
        interface = candidates.min { Self.rank($0) < Self.rank($1) }
    }

    /// 同一台设备在几块网卡上都被发现时，优先 Wi-Fi 和有线网
    var rank: Int { interface.map(Self.rank) ?? 3 }

    private static func rank(_ interface: NWInterface) -> Int {
        switch interface.type {
        case .wifi: 0
        case .wiredEthernet: 1
        default: 2
        }
    }
}

private struct LANMessage: Codable {
    enum Kind: String, Codable {
        /// 同步连接建立后报上自己是谁
        case hello
        /// 整包同步数据
        case state
        /// 配对：发起方报上自己，附带临时公钥的哈希
        case request
        /// 配对：被请求方的临时公钥
        case pair
        /// 配对：发起方公开临时公钥，附带加密的组密钥（没有时为空）
        case reveal
        /// 配对：被请求方确认，回复最终使用的组密钥
        case done
        /// 配对：被请求方拒绝
        case reject
        /// 同组设备让对方接着播放
        case play
    }

    var kind: Kind
    var device: SyncDevice?
    var data: Data?
    var publicKey: Data?
}

/// 一条 TCP 连接，同步时外加 TLS。消息是 4 字节长度加 JSON。
private final class PeerLink {
    let connection: NWConnection
    let outgoing: Bool
    var peerID: String?
    var device: SyncDevice?
    var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    var commitment: Data?
    var session: SymmetricKey?
    var offered: Data?
    var succeeded = false
    var onReady: (() -> Void)?
    var onMessage: ((LANMessage) -> Void)?
    var onClose: (() -> Void)?
    private var closed = false
    private var isReady = false

    private static let maxFrame = 8 << 20

    init(connection: NWConnection, outgoing: Bool, peerID: String?) {
        self.connection = connection
        self.outgoing = outgoing
        self.peerID = peerID
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    self.onReady?()
                    self.receiveLength()
                case .failed, .cancelled:
                    self.close()
                case .waiting:
                    // 握手失败或对方不在时不要一直等，交给上层重连
                    self.close()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        // 密钥不对时服务端会拒绝，但发起方可能一直停在握手中，不会报错
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, !self.isReady else { return }
            self.close()
        }
    }

    func send(_ message: LANMessage) {
        guard !closed, let body = try? JSONEncoder().encode(message), body.count <= Self.maxFrame else { return }
        var frame = withUnsafeBytes(of: UInt32(body.count).bigEndian) { Data($0) }
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        let handler = onClose
        onClose = nil
        onReady = nil
        onMessage = nil
        handler?()
    }

    private func receiveLength() {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard error == nil, let data, data.count == 4 else {
                    self.close()
                    return
                }
                let length = Int(data.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard length > 0, length <= Self.maxFrame else {
                    self.close()
                    return
                }
                self.receiveBody(length)
            }
        }
    }

    private func receiveBody(_ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard error == nil, let data, data.count == length,
                      let message = try? JSONDecoder().decode(LANMessage.self, from: data) else {
                    self.close()
                    return
                }
                self.onMessage?(message)
                guard !self.closed else { return }
                self.receiveLength()
            }
        }
    }
}
