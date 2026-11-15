import Foundation

/// 按服务器地址登记鉴权请求头。
/// 飞牛影视的图片、视频流只认请求头鉴权，不接受 api_key 查询参数，
/// 所以图片加载、封面下载、离线下载都要经由这里构造 URLRequest。
/// 同一个域名下可能用不同路径反代多台服务器，所以按“源 + 路径前缀”区分，取最长匹配。
enum MediaRequestAuth {
    private static var headersByPrefix: [String: [String: String]] = [:]

    static func register(_ baseURL: URL, headers: [String: String]) {
        guard let key = prefix(of: baseURL) else { return }
        headersByPrefix[key] = headers.filter { $0.key != "Accept" }
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let headers = headers(for: url) {
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }

    /// 先找路径前缀最长的登记；地址落在所有登记路径之外时，退回同源里路径最短的那条。
    private static func headers(for url: URL) -> [String: String]? {
        guard let target = prefix(of: url), let origin = origin(of: url) else { return nil }
        var best: (length: Int, headers: [String: String])?
        var fallback: (length: Int, headers: [String: String])?
        for (key, headers) in headersByPrefix {
            if target == key || target.hasPrefix(key + "/") {
                if best.map({ key.count > $0.length }) ?? true { best = (key.count, headers) }
            } else if key == origin || key.hasPrefix(origin + "/") {
                if fallback.map({ key.count < $0.length }) ?? true { fallback = (key.count, headers) }
            }
        }
        return (best ?? fallback)?.headers
    }

    private static func origin(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let scheme = url.scheme?.lowercased() ?? "http"
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }

    /// `scheme://host:port/path`，去掉末尾斜杠。路径按小写比较，和服务器反代的大小写无关。
    private static func prefix(of url: URL) -> String? {
        guard let origin = origin(of: url) else { return nil }
        var path = url.path().lowercased()
        while path.hasSuffix("/") { path.removeLast() }
        return origin + path
    }
}
