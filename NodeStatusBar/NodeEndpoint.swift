import Foundation

struct NodeEndpoint: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var urlString: String

    init(id: UUID = UUID(), name: String, urlString: String) {
        self.id = id
        self.name = name
        self.urlString = urlString
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? urlString : trimmedName
    }

    var kind: NodeKind {
        NodeKind(urlString: urlString)
    }
}

struct DisconnectLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let nodeID: UUID
    var nodeName: String
    let startedAt: Date
    var endedAt: Date?
    let message: String

    init(
        id: UUID = UUID(),
        nodeID: UUID,
        nodeName: String,
        startedAt: Date,
        endedAt: Date? = nil,
        message: String
    ) {
        self.id = id
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.message = message
    }

    var duration: TimeInterval? {
        endedAt?.timeIntervalSince(startedAt)
    }

    var isOngoing: Bool {
        endedAt == nil
    }

    var displayMessage: String {
        Self.cleanedMessage(message)
    }

    var isLocalProbeFailure: Bool {
        Self.isLocalProbeFailureMessage(message)
    }

    static func cleanedMessage(_ rawMessage: String) -> String {
        var message = rawMessage.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
        message = message.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if let localProbeResetMessage = localProbeResetMessage(message) {
            return localProbeResetMessage
        }

        if let nodeProbeFailureMessage = nodeProbeFailureMessage(message) {
            return nodeProbeFailureMessage
        }

        if message.hasPrefix("本地测速请求失败：") {
            return message
        }

        if isCFNetworkTransientProbeFailure(message) {
            return "本地测速请求失败：CFNetwork 310"
        }

        if let jsonStart = message.range(of: "{\"error\":\"")?.lowerBound {
            let prefix = String(message[..<jsonStart]).trimmingCharacters(in: .whitespacesAndNewlines)
            let jsonText = String(message[jsonStart...])

            if let data = jsonText.data(using: .utf8),
               let payload = try? JSONDecoder().decode([String: String].self, from: data),
               let error = payload["error"], !error.isEmpty {
                if prefix.contains("failed to initialize client") {
                    return "Hysteria 客户端初始化失败：\(translatedError(error))"
                }

                return translatedError(error)
            }
        }

        message = message.replacingOccurrences(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:[+-]\d{2}:\d{2}|Z)\s*"#,
            with: "",
            options: .regularExpression
        )
        message = message.replacingOccurrences(of: "FATAL ", with: "")
        message = message.replacingOccurrences(of: "ERROR ", with: "")
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if isHTTPConnectResetProbeFailure(message) {
            return "本地测速请求失败：HTTP CONNECT 连接被重置"
        }

        return message.isEmpty ? rawMessage : message
    }

    private static func translatedError(_ error: String) -> String {
        if error.contains("connect error: timeout: no recent network activity") {
            return "连接超时，短时间内没有网络活动"
        }

        if error.contains("timeout") {
            return "连接超时：\(error)"
        }

        return error
    }

    static func isLocalProbeFailureMessage(_ rawMessage: String) -> Bool {
        let message = rawMessage.lowercased()
        if nodeProbeFailureMessage(message) != nil {
            return false
        }

        return localProbeResetMessage(message) != nil ||
            message.contains("本地测速请求失败") ||
            message.contains("本地代理启动超时") ||
            message.contains("无法分配本地代理端口") ||
            isCFNetworkTransientProbeFailure(message) ||
            isHTTPConnectResetProbeFailure(message) ||
            message.contains("failed to run http proxy server") ||
            message.contains("invalid config: listen") ||
            message.contains("listen tcp")
    }

    private static func isCFNetworkTransientProbeFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("kcferrordomaincfnetwork error 310") ||
            lowercased.contains("cfnetwork error 310")
    }

    private static func isRequestTimeout(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased == "the request timed out." ||
            lowercased == "the request timed out" ||
            lowercased.contains("urlsessiontask failed with error: the request timed out")
    }

    static func isNodeProbeTimeoutMessage(_ rawMessage: String) -> Bool {
        let message = rawMessage.lowercased()
        return isRequestTimeout(message) ||
            message.contains("context deadline exceeded") ||
            message.contains("client.timeout exceeded while awaiting headers") ||
            (message.contains("generate_204") && message.contains("timeout"))
    }

    static func nodeProbeFailureMessage(_ rawMessage: String) -> String? {
        if rawMessage == "通过节点访问测试地址超时" {
            return rawMessage
        }

        let message = rawMessage.lowercased()
        if let statusCode = nodeProbeHTTPFailureStatus(in: message) {
            return "通过节点访问测试地址失败：HTTP \(statusCode)"
        }

        if isNodeProbeTimeoutMessage(message) {
            return "通过节点访问测试地址超时"
        }

        return nil
    }

    static func localProbeResetMessage(_ rawMessage: String) -> String? {
        if rawMessage == "本地测速连接被重置" || rawMessage == "通过节点访问测试地址连接中断" {
            return "本地测速连接被重置"
        }

        let message = rawMessage.lowercased()
        guard message.contains("generate_204") else {
            return nil
        }

        if message.contains("broken pipe") || message.contains("connection reset by peer") {
            return "本地测速连接被重置"
        }

        return nil
    }

    private static func nodeProbeHTTPFailureStatus(in message: String) -> Int? {
        for statusCode in [502, 503, 504] where message.contains("http \(statusCode)") {
            return statusCode
        }

        return nil
    }

    private static func isHTTPConnectResetProbeFailure(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains("http connect error") &&
            lowercased.contains("www.gstatic.com:443") &&
            lowercased.contains("connection reset by peer")
    }
}

enum NodeKind: Equatable {
    case http
    case hysteria2
    case unsupported(String)

    init(urlString: String) {
        let scheme = URLComponents(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()

        switch scheme {
        case "http", "https":
            self = .http
        case "hysteria2", "hy2":
            self = .hysteria2
        case let scheme?:
            self = .unsupported(scheme)
        case nil:
            self = .http
        }
    }
}

struct Hysteria2Endpoint: Equatable {
    let host: String
    let port: UInt16

    init?(urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = trimmed.range(of: "://") else {
            return nil
        }

        let scheme = trimmed[..<schemeRange.lowerBound].lowercased()
        guard scheme == "hysteria2" || scheme == "hy2" else {
            return nil
        }

        let afterScheme = String(trimmed[schemeRange.upperBound...])
        let authority = String(afterScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let hostPort = String(authority.split(separator: "@", omittingEmptySubsequences: false).last ?? "")
        let hostPortWithoutIPv6Brackets = hostPort.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if hostPort.hasPrefix("["),
           let closeBracketIndex = hostPort.firstIndex(of: "]") {
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closeBracketIndex])
            port = Self.parsePort(from: String(hostPort[hostPort.index(after: closeBracketIndex)...])) ?? 443
            return
        }

        let parts = hostPortWithoutIPv6Brackets.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard let rawHost = parts.first, !rawHost.isEmpty else {
            return nil
        }

        host = String(rawHost)
        if parts.count > 1 {
            port = Self.parsePort(from: String(parts[1])) ?? 443
        } else {
            port = 443
        }
    }

    private static func parsePort(from rawValue: String) -> UInt16? {
        let trimmed = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let firstPort = trimmed.split(separator: ",", maxSplits: 1).first?.split(separator: "-", maxSplits: 1).first
        guard let firstPort, let value = UInt16(firstPort) else {
            return nil
        }
        return value
    }
}

enum NodeHealth: Equatable {
    case unknown
    case checking
    case online(latencyMilliseconds: Int?, message: String, checkedAt: Date)
    case offline(message: String, checkedAt: Date)

    var isOnline: Bool {
        if case .online = self {
            return true
        }
        return false
    }

    var isTransient: Bool {
        switch self {
        case .unknown, .checking:
            return true
        case .online, .offline:
            return false
        }
    }

    var latencyMilliseconds: Int? {
        if case let .online(latencyMilliseconds, _, _) = self {
            return latencyMilliseconds
        }
        return nil
    }

    var checkedAt: Date? {
        switch self {
        case .unknown, .checking:
            return nil
        case let .online(_, _, checkedAt):
            return checkedAt
        case let .offline(_, checkedAt):
            return checkedAt
        }
    }

    var offlineMessage: String? {
        if case let .offline(message, _) = self {
            return message
        }
        return nil
    }

    var isLocalProbeFailure: Bool {
        guard let offlineMessage else {
            return false
        }

        return DisconnectLogEntry.isLocalProbeFailureMessage(offlineMessage)
    }

    var shortLabel: String {
        switch self {
        case .unknown:
            return "未检测"
        case .checking:
            return "检测中"
        case let .online(latencyMilliseconds?, _, _):
            return "\(latencyMilliseconds) ms"
        case .online:
            return "节点正常"
        case .offline:
            return "离线"
        }
    }

    var menuDetail: String {
        switch self {
        case .unknown:
            return "等待首次检测"
        case .checking:
            return "正在检测"
        case let .online(latencyMilliseconds?, message, checkedAt):
            return "在线 · \(message) · \(latencyMilliseconds) ms · \(Self.timeFormatter.string(from: checkedAt))"
        case let .online(nil, message, checkedAt):
            return "在线 · \(message) · \(Self.timeFormatter.string(from: checkedAt))"
        case let .offline(message, checkedAt):
            return "离线 · \(message) · \(Self.timeFormatter.string(from: checkedAt))"
        }
    }

    func hasSameDisplayState(as other: NodeHealth) -> Bool {
        switch (self, other) {
        case (.unknown, .unknown), (.checking, .checking):
            return true
        case let (.online(lhsLatency, lhsMessage, _), .online(rhsLatency, rhsMessage, _)):
            return lhsLatency == rhsLatency && lhsMessage == rhsMessage
        case let (.offline(lhsMessage, _), .offline(rhsMessage, _)):
            return lhsMessage == rhsMessage
        default:
            return false
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
