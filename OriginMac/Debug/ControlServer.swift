#if DEBUG
import AppKit
import Network
import SwiftUI

/// 仅 Debug 构建启用的本机控制接口（只监听 127.0.0.1），供 AI / 脚本驱动应用、读取状态，
/// 无需每一步都截图。端口默认 8765，可用环境变量 ORIGIN_CONTROL_PORT 修改。
/// 接口列表见 `GET /help`，命令行封装见 scripts/originctl。
final class ControlServer {
    static let shared = ControlServer()

    private var listener: NWListener?
    private var handler: ControlHandler?
    /// 由主窗口注入 SwiftUI 的 openSettings；窗口出现前退回到菜单动作
    var openSettings: () -> Void = { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }

    func start(app: AppModel, navigation: MacNavigation) {
        guard listener == nil else { return }
        handler = ControlHandler(app: app, navigation: navigation, openSettings: { [unowned self] in openSettings() })
        let port = ProcessInfo.processInfo.environment["ORIGIN_CONTROL_PORT"].flatMap(UInt16.init) ?? 8765
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: parameters) else {
            NSLog("[ControlServer] 无法监听端口 \(port)")
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.stateUpdateHandler = { state in
            NSLog("[ControlServer] 监听状态 %@", "\(state)")
            if case .ready = state { NSLog("[ControlServer] 已启动：http://127.0.0.1:\(port)/help") }
            if case let .failed(error) = state { NSLog("[ControlServer] 启动失败：\(error)") }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = ControlRequest(buffer) {
                    Task {
                        let response = await self?.handler?.handle(request) ?? .error("服务未就绪", status: 503)
                        connection.send(content: response.encoded, completion: .contentProcessed { _ in connection.cancel() })
                    }
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self?.receive(connection, buffer: buffer)
                }
            }
        }
    }
}

// MARK: - HTTP

struct ControlRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: [String: Any]

    /// 请求不完整时返回 nil，继续接收
    init?(_ data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        let length = lines.dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        let bodyData = data[headerEnd.upperBound...]
        guard bodyData.count >= length else { return nil }

        method = String(parts[0]).uppercased()
        let components = URLComponents(string: String(parts[1]))
        path = components?.path ?? "/"
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        self.query = query
        body = (try? JSONSerialization.jsonObject(with: Data(bodyData.prefix(length)))) as? [String: Any] ?? [:]
    }

    /// 参数可以放在查询串或 JSON 请求体中
    func string(_ key: String) -> String? {
        if let value = query[key] { return value }
        switch body[key] {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        default: return nil
        }
    }

    func double(_ key: String) -> Double? { string(key).flatMap(Double.init) }
}

struct ControlResponse {
    var status = 200
    var contentType = "application/json; charset=utf-8"
    var body = Data()

    static func json(_ object: Any, status: Int = 200) -> ControlResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return ControlResponse(status: status, body: data)
    }

    static func text(_ text: String, status: Int = 200) -> ControlResponse {
        ControlResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    static func error(_ message: String, status: Int = 400) -> ControlResponse {
        .json(["ok": false, "error": message], status: status)
    }

    static let ok = ControlResponse.json(["ok": true])

    var encoded: Data {
        var head = "HTTP/1.1 \(status) \(status < 400 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
#endif
