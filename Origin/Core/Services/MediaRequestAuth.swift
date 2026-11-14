import Foundation

/// 按服务器地址登记鉴权请求头。
/// 飞牛影视的图片、视频流只认请求头鉴权，不接受 api_key 查询参数，
/// 所以图片加载、封面下载、离线下载都要经由这里构造 URLRequest。
enum MediaRequestAuth {
    private static var headersByOrigin: [String: [String: String]] = [:]

    static func register(_ baseURL: URL, headers: [String: String]) {
        guard let key = origin(of: baseURL) else { return }
        headersByOrigin[key] = headers.filter { $0.key != "Accept" }
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let key = origin(of: url), let headers = headersByOrigin[key] {
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return request
    }

    private static func origin(of url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return "\(url.scheme ?? "http")://\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
}
