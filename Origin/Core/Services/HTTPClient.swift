import CFNetwork
import Foundation
import Security

nonisolated enum APIError: LocalizedError {
    case invalidURL
    case http(Int, String?)
    case unauthorized
    case decoding(Error)
    case notFound
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "服务器地址无效"
        case let .http(code, body): "服务器返回错误 \(code)" + (body.map { "：\($0.prefix(200))" } ?? "")
        case .unauthorized: "认证失败，请检查用户名、密码或重新登录"
        case let .decoding(error): "数据解析失败：\(error.localizedDescription)"
        case .notFound: "未找到内容"
        case let .message(text): text
        }
    }
}

/// 基于 URLSession 的轻量请求封装
nonisolated struct HTTPClient {
    var session: URLSession
    var timeout: TimeInterval
    /// 自定义会话会持有这个委托，否则证书回调会被释放
    private let tlsKeeper: OriginTrustDelegate
    /// 连到已经选定的 IP 时不走系统代理，避免代理把真实地址再送进虚拟网卡。
    private let directSession: URLSession

    init(timeout: TimeInterval = 20, allowsInsecureTLS: Bool = false) {
        self.timeout = timeout
        let delegate = OriginTrustDelegate(allowsInsecure: allowsInsecureTLS)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        tlsKeeper = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let direct = configuration.copy() as? URLSessionConfiguration ?? URLSessionConfiguration.ephemeral
        direct.timeoutIntervalForRequest = timeout
        direct.timeoutIntervalForResource = timeout
        direct.waitsForConnectivity = false
        direct.connectionProxyDictionary = OriginTrust.directProxySettings()
        directSession = URLSession(configuration: direct, delegate: delegate, delegateQueue: nil)
    }

    func data(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if body != nil, request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let authority = ServerEndpoint.authority(for: url) {
            request.setValue(authority, forHTTPHeaderField: "Host")
        }
        let transport = ServerEndpoint.bypassesProxy(url) ? directSession : session
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200 ..< 300: return data
        case 401, 403: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default: throw APIError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
    }

    func decode<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let data = try await data(url, method: method, headers: headers, body: body)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }
}

extension URL {
    /// 拼接路径与查询参数，nil 值会被忽略
    func appending(path: String, query: [String: String?]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = basePath + (path.hasPrefix("/") ? path : "/" + path)
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty {
            components.queryItems = (components.queryItems ?? []) + items.sorted { $0.name < $1.name }
        }
        return components.url!
    }
}

extension String {
    /// 用户输入的服务器地址规范化：补全协议、去除末尾斜杠
    var normalizedServerURL: URL? {
        var text = trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "http://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }
}

/// 用户允许自签名时直接接受证书。连到字面 IP 时可按原来的域名校验。
nonisolated enum OriginTrust {
    /// 关掉系统 HTTP、HTTPS、SOCKS 和 PAC。只用于用户填写的字面 IP。
    static func directProxySettings() -> [String: Any] {
        var settings: [String: Any] = [
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
        ]
        #if os(macOS)
        settings[kCFNetworkProxiesHTTPSEnable as String] = 0
        settings[kCFNetworkProxiesSOCKSEnable as String] = 0
        #endif
        return settings
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: OriginTrustDelegate(allowsInsecure: false), delegateQueue: nil)
    }()

    private static let directSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = directProxySettings()
        return URLSession(configuration: configuration, delegate: OriginTrustDelegate(allowsInsecure: false), delegateQueue: nil)
    }()

    static func session(for url: URL) -> URLSession {
        ServerEndpoint.isLiteralIP(url.host() ?? "") ? directSession : session
    }

    static func evaluate(_ challenge: URLAuthenticationChallenge, allowsInsecure: Bool) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        if allowsInsecure {
            return (.useCredential, URLCredential(trust: trust))
        }
        if let domain = ServerRoute.shared.certificateHost(for: challenge.protectionSpace.host) {
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, domain as CFString))
            if SecTrustEvaluateWithError(trust, nil) {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.performDefaultHandling, nil)
    }

    /// 收到响应头就算这条地址通了。
    static func responds(_ url: URL, timeout: TimeInterval, allowsInsecure: Bool, direct: Bool) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        if direct { configuration.connectionProxyDictionary = directProxySettings() }
        let session = URLSession(configuration: configuration, delegate: OriginTrustDelegate(allowsInsecure: allowsInsecure), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let authority = ServerEndpoint.authority(for: url) {
            request.setValue(authority, forHTTPHeaderField: "Host")
        }
        guard let (bytes, response) = try? await session.bytes(for: request) else { return false }
        bytes.task.cancel()
        return response is HTTPURLResponse
    }
}

nonisolated final class OriginTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    let allowsInsecure: Bool

    init(allowsInsecure: Bool) {
        self.allowsInsecure = allowsInsecure
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        OriginTrust.evaluate(challenge, allowsInsecure: allowsInsecure)
    }
}

enum DateParsing {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFraction = ISO8601DateFormatter()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// 兼容 Jellyfin 的 7 位小数秒，以及纯日期格式
    static func parse(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        var normalized = string
        if let dot = normalized.firstIndex(of: "."), let end = normalized[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = normalized[normalized.index(after: dot) ..< end].prefix(3)
            normalized = String(normalized[..<dot]) + "." + fraction + String(normalized[end...])
        }
        return iso.date(from: normalized) ?? isoNoFraction.date(from: normalized) ?? day.date(from: String(string.prefix(10)))
    }
}
