import AppKit
import Combine
import Darwin
import Foundation

@MainActor
final class NodeMonitor: ObservableObject {
    @Published private(set) var nodes: [NodeEndpoint]
    @Published private(set) var statuses: [UUID: NodeHealth] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var selectedNodeID: UUID?
    @Published private(set) var latencyDetectionEnabled: Bool
    @Published private(set) var disconnectCounts: [UUID: Int]
    @Published private(set) var disconnectLogs: [DisconnectLogEntry]

    private let storageKey = "nodes"
    private let selectedNodeIDStorageKey = "selectedNodeID"
    private let latencyDetectionStorageKey = "latencyDetectionEnabled"
    private let disconnectCountsStorageKey = "disconnectCounts"
    private let disconnectLogsStorageKey = "disconnectLogs"
    private let latencyRefreshInterval: TimeInterval = 15
    private let statusRefreshInterval: TimeInterval = 5
    private let latencyProbeURL = URL(string: "http://cp.cloudflare.com/generate_204")!
    private let maxDisconnectLogEntries = 300
    private var refreshTimer: Timer?
    private var hysteriaProxies: [UUID: HysteriaProxy] = [:]

    init() {
        let loadedNodes = Self.loadNodes(storageKey: storageKey)
        nodes = loadedNodes.map { node in
            var normalizedNode = node
            normalizedNode.urlString = Self.normalizeURL(node.urlString)
            return normalizedNode
        }
        latencyDetectionEnabled = UserDefaults.standard.object(forKey: latencyDetectionStorageKey) as? Bool ?? true
        disconnectCounts = Self.loadDisconnectCounts(storageKey: disconnectCountsStorageKey)
        disconnectLogs = Self.loadDisconnectLogs(storageKey: disconnectLogsStorageKey)
        let didNormalizeStoredNodes = zip(loadedNodes, nodes).contains { $0.urlString != $1.urlString }
        selectedNodeID = Self.loadSelectedNodeID(storageKey: selectedNodeIDStorageKey, nodes: nodes)

        for node in nodes {
            statuses[node.id] = .unknown
        }

        if nodes.isEmpty {
            nodes = [
                NodeEndpoint(name: "Apple", urlString: "https://www.apple.com"),
                NodeEndpoint(name: "GitHub", urlString: "https://github.com")
            ]
            persistNodes()
        } else if didNormalizeStoredNodes {
            persistNodes()
        }

        if selectedNodeID == nil {
            selectedNodeID = nodes.first?.id
            persistSelectedNodeID()
        }
    }

    func start() {
        scheduleRefreshTimer()

        Task {
            await refresh()
        }
    }

    func setLatencyDetectionEnabled(_ isEnabled: Bool) {
        guard latencyDetectionEnabled != isEnabled else {
            return
        }

        latencyDetectionEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: latencyDetectionStorageKey)
        scheduleRefreshTimer()

        Task {
            await refresh()
        }
    }

    func toggleLatencyDetection() {
        setLatencyDetectionEnabled(!latencyDetectionEnabled)
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: currentRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private var currentRefreshInterval: TimeInterval {
        latencyDetectionEnabled ? latencyRefreshInterval : statusRefreshInterval
    }

    func refresh() async {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true

        for node in refreshOrderedNodes {
            let health = await check(node)
            updateStatus(health, for: node)
        }

        isRefreshing = false
    }

    private var refreshOrderedNodes: [NodeEndpoint] {
        guard let selectedStatusBarNode else {
            return nodes
        }

        return [selectedStatusBarNode] + nodes.filter { $0.id != selectedStatusBarNode.id }
    }

    func addNode(name: String, urlString: String) {
        let normalizedURL = Self.normalizeURL(urlString)
        guard isSupportedNodeURL(normalizedURL) else {
            return
        }

        let node = NodeEndpoint(name: name, urlString: normalizedURL)
        nodes.append(node)
        statuses[node.id] = .unknown
        if selectedNodeID == nil {
            selectedNodeID = node.id
            persistSelectedNodeID()
        }
        persistNodes()

        Task {
            await refresh()
        }
    }

    func updateNode(_ node: NodeEndpoint, name: String, urlString: String) {
        let normalizedURL = Self.normalizeURL(urlString)
        guard let index = nodes.firstIndex(where: { $0.id == node.id }),
              isSupportedNodeURL(normalizedURL) else {
            return
        }

        let shouldRestartProxy = nodes[index].urlString != normalizedURL
        if shouldRestartProxy {
            stopHysteriaProxy(for: node.id)
        }

        nodes[index].name = name
        nodes[index].urlString = normalizedURL
        persistNodes()

        Task {
            await refresh()
        }
    }

    func removeNode(_ node: NodeEndpoint) {
        stopHysteriaProxy(for: node.id)
        nodes.removeAll { $0.id == node.id }
        statuses[node.id] = nil
        disconnectCounts[node.id] = nil
        disconnectLogs.removeAll { $0.nodeID == node.id }
        persistDisconnectCounts()
        persistDisconnectLogs()
        if selectedNodeID == node.id {
            selectedNodeID = nodes.first?.id
            persistSelectedNodeID()
        }
        persistNodes()
    }

    func selectForStatusBar(_ node: NodeEndpoint) {
        guard nodes.contains(where: { $0.id == node.id }) else {
            return
        }

        selectedNodeID = node.id
        persistSelectedNodeID()
    }

    func isSelectedForStatusBar(_ node: NodeEndpoint) -> Bool {
        selectedNodeID == node.id
    }

    func status(for node: NodeEndpoint) -> NodeHealth {
        statuses[node.id] ?? .unknown
    }

    func disconnectCount(for node: NodeEndpoint) -> Int {
        disconnectCounts[node.id] ?? 0
    }

    func disconnectLogs(for node: NodeEndpoint) -> [DisconnectLogEntry] {
        disconnectLogs.filter { $0.nodeID == node.id }
    }

    func latestDisconnectLog(for node: NodeEndpoint) -> DisconnectLogEntry? {
        disconnectLogs.first { $0.nodeID == node.id }
    }

    func resetDisconnectCount(for node: NodeEndpoint) {
        disconnectCounts[node.id] = 0
        disconnectLogs.removeAll { $0.nodeID == node.id }
        persistDisconnectCounts()
        persistDisconnectLogs()
    }

    func resetAllDisconnectCounts() {
        disconnectCounts = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, 0) })
        disconnectLogs = []
        persistDisconnectCounts()
        persistDisconnectLogs()
    }

    func deleteDisconnectLog(_ log: DisconnectLogEntry) {
        let originalCount = disconnectLogs.count
        disconnectLogs.removeAll { $0.id == log.id }

        let shouldDecrementCount = !log.isLocalProbeFailure || log.message == "通过节点访问测试地址连接中断"
        if disconnectLogs.count < originalCount && shouldDecrementCount {
            disconnectCounts[log.nodeID] = max(0, (disconnectCounts[log.nodeID] ?? 0) - 1)
            persistDisconnectCounts()
        }

        persistDisconnectLogs()
    }

    var onlineCount: Int {
        nodes.filter { status(for: $0).isOnline }.count
    }

    var slowestLatencyMilliseconds: Int? {
        nodes.compactMap { status(for: $0).latencyMilliseconds }.max()
    }

    var totalDisconnectCount: Int {
        nodes.reduce(0) { $0 + disconnectCount(for: $1) }
    }

    var statusBarSnapshot: StatusBarSnapshot {
        guard !nodes.isEmpty else {
            return StatusBarSnapshot(color: .gray, title: "节点 --")
        }

        let selectedNode = selectedStatusBarNode ?? nodes[0]
        let health = status(for: selectedNode)

        switch health {
        case .online:
            return StatusBarSnapshot(color: .green, title: statusBarTitle(for: selectedNode))
        case .offline:
            return StatusBarSnapshot(color: .red, title: statusBarTitle(for: selectedNode))
        case .checking:
            return StatusBarSnapshot(color: .orange, title: statusBarTitle(for: selectedNode))
        case .unknown:
            return StatusBarSnapshot(color: .gray, title: statusBarTitle(for: selectedNode))
        }
    }

    var selectedStatusBarNode: NodeEndpoint? {
        guard let selectedNodeID else {
            return nodes.first
        }

        return nodes.first { $0.id == selectedNodeID } ?? nodes.first
    }

    private func check(_ node: NodeEndpoint) async -> NodeHealth {
        switch node.kind {
        case .http:
            return await checkHTTP(node)
        case .hysteria2:
            return await checkHysteria2(node)
        case let .unsupported(scheme):
            return .offline(message: "暂不支持 \(scheme) 协议", checkedAt: Date())
        }
    }

    private func updateStatus(_ health: NodeHealth, for node: NodeEndpoint) {
        let previousStatus = status(for: node)

        if health.isLocalProbeFailure {
            recordLocalProbeFailure(for: node, health: health)

            if previousStatus.isTransient {
                var updatedStatuses = statuses
                updatedStatuses[node.id] = health
                statuses = updatedStatuses
            }
            return
        }

        if previousStatus.isOnline && !health.isOnline {
            recordDisconnectStart(for: node, health: health)
        } else if !previousStatus.isOnline && health.isOnline {
            recordDisconnectEnd(for: node, health: health)
        }

        var updatedStatuses = statuses
        updatedStatuses[node.id] = health
        statuses = updatedStatuses
    }

    private func recordLocalProbeFailure(for node: NodeEndpoint, health: NodeHealth) {
        let checkedAt = health.checkedAt ?? Date()
        let entry = DisconnectLogEntry(
            nodeID: node.id,
            nodeName: node.displayName,
            startedAt: checkedAt,
            endedAt: checkedAt,
            message: health.offlineMessage ?? "本地检测失败"
        )
        disconnectLogs.insert(entry, at: 0)

        if disconnectLogs.count > maxDisconnectLogEntries {
            disconnectLogs.removeLast(disconnectLogs.count - maxDisconnectLogEntries)
        }

        persistDisconnectLogs()
    }

    private func recordDisconnectStart(for node: NodeEndpoint, health: NodeHealth) {
        guard !disconnectLogs.contains(where: { $0.nodeID == node.id && $0.isOngoing }) else {
            return
        }

        disconnectCounts[node.id] = disconnectCount(for: node) + 1
        persistDisconnectCounts()

        let entry = DisconnectLogEntry(
            nodeID: node.id,
            nodeName: node.displayName,
            startedAt: health.checkedAt ?? Date(),
            message: health.offlineMessage ?? "节点离线"
        )
        disconnectLogs.insert(entry, at: 0)
        playAlertSound(preferredNames: ["Hero", "Glass", "Tink"])

        if disconnectLogs.count > maxDisconnectLogEntries {
            disconnectLogs.removeLast(disconnectLogs.count - maxDisconnectLogEntries)
        }

        persistDisconnectLogs()
    }

    private func recordDisconnectEnd(for node: NodeEndpoint, health: NodeHealth) {
        guard let index = disconnectLogs.firstIndex(where: { $0.nodeID == node.id && $0.isOngoing }) else {
            return
        }

        disconnectLogs[index].nodeName = node.displayName
        disconnectLogs[index].endedAt = health.checkedAt ?? Date()
        persistDisconnectLogs()
        playAlertSound(preferredNames: ["Basso", "Sosumi", "Submarine"])
    }

    private func playAlertSound(preferredNames: [String]) {
        for name in preferredNames {
            if let sound = NSSound(named: NSSound.Name(name)) {
                sound.play()
                return
            }
        }

        NSSound.beep()
    }

    private func checkHTTP(_ node: NodeEndpoint) async -> NodeHealth {
        guard let url = URL(string: node.urlString) else {
            return .offline(message: "URL 无效", checkedAt: Date())
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let startedAt = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let elapsed = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))

            if let httpResponse = response as? HTTPURLResponse,
               !(200...399).contains(httpResponse.statusCode) {
                return .offline(message: "HTTP \(httpResponse.statusCode)", checkedAt: Date())
            }

            return .online(
                latencyMilliseconds: latencyDetectionEnabled ? elapsed : nil,
                message: latencyDetectionEnabled ? "HTTP OK" : "节点正常",
                checkedAt: Date()
            )
        } catch {
            return .offline(message: error.localizedDescription, checkedAt: Date())
        }
    }

    private func checkHysteria2(_ node: NodeEndpoint) async -> NodeHealth {
        await performHysteria2Check(node)
    }

    private func performHysteria2Check(_ node: NodeEndpoint) async -> NodeHealth {
        let proxy: HysteriaProxy
        do {
            proxy = try await ensureHysteriaProxy(for: node)
        } catch let error as HysteriaProxyError {
            return .offline(message: error.message, checkedAt: Date())
        } catch {
            return .offline(message: error.localizedDescription, checkedAt: Date())
        }

        do {
            let latency = try await measureLatencyThroughHTTPProxy(port: proxy.port)
            return .online(
                latencyMilliseconds: latencyDetectionEnabled ? latency : nil,
                message: latencyDetectionEnabled ? "HY2 常驻代理测速" : "节点正常",
                checkedAt: Date()
            )
        } catch {
            let message = await localProbeFailureMessage(error: error, proxy: proxy)
            return .offline(message: message, checkedAt: Date())
        }
    }

    private func ensureHysteriaProxy(for node: NodeEndpoint) async throws -> HysteriaProxy {
        if let proxy = hysteriaProxies[node.id] {
            if proxy.urlString == node.urlString,
               proxy.process.isRunning {
                if await canOpenTCPConnection(port: proxy.port) {
                    return proxy
                }

                if await waitForLocalTCPPort(proxy.port, process: proxy.process, timeout: 2) {
                    return proxy
                }
            }

            stopHysteriaProxy(for: node.id)
        }

        guard Hysteria2Endpoint(urlString: node.urlString) != nil else {
            throw HysteriaProxyError(message: "HY2 链接格式无效")
        }

        guard let executableURL = hysteriaExecutableURL() else {
            throw HysteriaProxyError(message: "未找到 Hysteria 客户端")
        }

        guard let proxyPort = availableLocalTCPPort() else {
            throw HysteriaProxyError(message: "无法分配本地代理端口")
        }

        let configURL = temporaryConfigURL(for: node)
        let config = hysteriaConfig(for: node, proxyPort: proxyPort)

        do {
            try config.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            throw HysteriaProxyError(message: "写入 HY2 配置失败")
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "client",
            "--config", configURL.path,
            "--disable-update-check",
            "--log-level", "warn"
        ]

        let logPipe = Pipe()
        let logBuffer = ProcessOutputBuffer()
        logBuffer.attach(to: logPipe)
        process.standardOutput = logPipe
        process.standardError = logPipe

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: configURL)
            throw HysteriaProxyError(message: "启动 Hysteria 失败")
        }

        let proxy = HysteriaProxy(
            nodeID: node.id,
            urlString: node.urlString,
            port: proxyPort,
            process: process,
            configURL: configURL,
            logPipe: logPipe,
            logBuffer: logBuffer
        )

        guard await waitForLocalTCPPort(proxyPort, process: process, timeout: 8) else {
            let message = hysteriaLogMessage(from: logBuffer) ?? "本地代理启动超时"
            stopHysteriaProxy(proxy)
            throw HysteriaProxyError(message: message)
        }

        hysteriaProxies[node.id] = proxy
        return proxy
    }

    func stopAllHysteriaProxies() {
        refreshTimer?.invalidate()
        for proxy in hysteriaProxies.values {
            stopHysteriaProxy(proxy)
        }

        hysteriaProxies.removeAll()
    }

    private func stopHysteriaProxy(for nodeID: UUID) {
        guard let proxy = hysteriaProxies.removeValue(forKey: nodeID) else {
            return
        }

        stopHysteriaProxy(proxy)
    }

    private func stopHysteriaProxy(_ proxy: HysteriaProxy) {
        proxy.logPipe.fileHandleForReading.readabilityHandler = nil

        if proxy.process.isRunning {
            proxy.process.terminate()
            forceKill(proxy.process, after: 1)
        }

        try? FileManager.default.removeItem(at: proxy.configURL)
    }

    private func forceKill(_ process: Process, after delay: TimeInterval) {
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            if process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    private func statusBarTitle(for node: NodeEndpoint) -> String {
        let name = node.displayName
        let compactName = name.count > 16 ? "\(name.prefix(15))..." : name
        if let latency = status(for: node).latencyMilliseconds {
            return "\(compactName) \(latency)ms"
        }

        if status(for: node).isOnline {
            return "\(compactName) 节点正常"
        }

        if case .offline = status(for: node) {
            return "\(compactName) 节点挂了"
        }

        return compactName
    }

    private func hysteriaExecutableURL() -> URL? {
        let fileManager = FileManager.default
        let candidateURLs = [
            Bundle.main.url(forResource: "hysteria", withExtension: nil),
            URL(fileURLWithPath: "/opt/homebrew/bin/hysteria"),
            URL(fileURLWithPath: "/usr/local/bin/hysteria")
        ].compactMap { $0 }

        return candidateURLs.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func hysteriaConfig(for node: NodeEndpoint, proxyPort: UInt16) -> String {
        """
        server: '\(yamlSingleQuoted(node.urlString))'
        lazy: true
        http:
          listen: 127.0.0.1:\(proxyPort)
        """
    }

    private func temporaryConfigURL(for node: NodeEndpoint) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NodeStatusBar-\(node.id.uuidString)")
            .appendingPathExtension("yaml")
    }

    private func yamlSingleQuoted(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func availableLocalTCPPort() -> UInt16? {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            return nil
        }

        defer {
            close(socketDescriptor)
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                bind(socketDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            return nil
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(socketDescriptor, socketAddress, &boundAddressLength)
            }
        }

        guard nameResult == 0 else {
            return nil
        }

        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private func waitForLocalTCPPort(_ port: UInt16, process: Process, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            guard process.isRunning else {
                return false
            }

            if await canOpenTCPConnection(port: port) {
                return true
            }

            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return false
    }

    private func canOpenTCPConnection(port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.canConnectToLocalTCPPort(port))
            }
        }
    }

    nonisolated private static func canConnectToLocalTCPPort(_ port: UInt16) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            return false
        }
        defer {
            close(socketDescriptor)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    private func measureLatencyThroughHTTPProxy(port: UInt16) async throws -> Int {
        do {
            return try await latencySampleThroughHTTPProxy(port: port, timeout: 7)
        } catch NodeProbeError.httpStatus(let statusCode) where Self.shouldRetryHTTPProxyStatus(statusCode) {
            try? await Task.sleep(nanoseconds: 450_000_000)
            return try await latencySampleThroughHTTPProxy(port: port, timeout: 7)
        }
    }

    private func latencySampleThroughHTTPProxy(port: UInt16, timeout: TimeInterval) async throws -> Int {
        let startedAt = Date()
        let responseHeader = try await httpProxyRequest(port: port, timeout: timeout)
        let elapsed = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))

        let statusCode = Self.httpStatusCode(from: responseHeader)
        guard (200...399).contains(statusCode) else {
            throw NodeProbeError.httpStatus(statusCode)
        }

        return elapsed
    }

    private func httpProxyRequest(port: UInt16, timeout: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let responseHeader = try Self.performHTTPProxyRequest(port: port, timeout: timeout)
                    continuation.resume(returning: responseHeader)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func performHTTPProxyRequest(port: UInt16, timeout: TimeInterval) throws -> String {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw NodeProbeError.socket("创建本地 socket 失败")
        }
        defer {
            close(socketDescriptor)
        }

        var timeoutValue = timeval(
            tv_sec: Int(timeout),
            tv_usec: suseconds_t((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(socketDescriptor, SOL_SOCKET, SO_RCVTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(socketDescriptor, SOL_SOCKET, SO_SNDTIMEO, &timeoutValue, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(socketDescriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            throw NodeProbeError.socket("连接本地代理端口失败：\(Self.errnoMessage())")
        }

        let request = "GET http://cp.cloudflare.com/generate_204 HTTP/1.1\r\n" +
            "Host: cp.cloudflare.com\r\n" +
            "User-Agent: NodeStatusBar\r\n" +
            "Connection: close\r\n" +
            "\r\n"
        guard let requestData = request.data(using: .utf8) else {
            throw NodeProbeError.socket("生成测速请求失败")
        }

        try requestData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw NodeProbeError.socket("测速请求为空")
            }

            var bytesSent = 0
            while bytesSent < rawBuffer.count {
                let sent = send(socketDescriptor, baseAddress.advanced(by: bytesSent), rawBuffer.count - bytesSent, 0)
                guard sent > 0 else {
                    throw NodeProbeError.socket("发送测速请求失败：\(Self.errnoMessage())")
                }
                bytesSent += sent
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)

        while response.range(of: Data([13, 10, 13, 10])) == nil {
            let count = recv(socketDescriptor, &buffer, buffer.count, 0)
            if count > 0 {
                response.append(buffer, count: count)
                if response.count > 16_384 {
                    break
                }
                continue
            }

            if count == 0 {
                break
            }

            throw NodeProbeError.socket("读取测速响应失败：\(Self.errnoMessage())")
        }

        guard !response.isEmpty else {
            throw NodeProbeError.socket("本地代理未返回测速响应")
        }

        let headerData: Data
        if let headerEnd = response.range(of: Data([13, 10, 13, 10])) {
            headerData = response[..<headerEnd.upperBound]
        } else {
            headerData = response
        }

        guard let header = String(data: headerData, encoding: .isoLatin1) ??
            String(data: headerData, encoding: .utf8) else {
            throw NodeProbeError.socket("测速响应无法解析")
        }

        return header
    }

    nonisolated private static func httpStatusCode(from responseHeader: String) -> Int {
        guard let statusLine = responseHeader.split(separator: "\r\n", omittingEmptySubsequences: false).first else {
            return 0
        }

        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2,
              let statusCode = Int(parts[1]) else {
            return 0
        }

        return statusCode
    }

    nonisolated private static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }

    private func localProbeFailureMessage(error: Error, proxy: HysteriaProxy) async -> String {
        let errorSummary = Self.errorSummary(error)
        if let nodeProbeFailureMessage = DisconnectLogEntry.nodeProbeFailureMessage(errorSummary) {
            return nodeProbeFailureMessage
        }

        if let latestLog = hysteriaLogMessage(from: proxy.logBuffer) {
            if let nodeProbeFailureMessage = DisconnectLogEntry.nodeProbeFailureMessage(latestLog) {
                return nodeProbeFailureMessage
            }

            if let localProbeResetMessage = DisconnectLogEntry.localProbeResetMessage(latestLog) {
                return localProbeResetMessage
            }
        }

        let isPortOpen = await canOpenTCPConnection(port: proxy.port)
        let processState = proxy.process.isRunning ? "运行中" : "已退出"
        let portState = isPortOpen ? "可连接" : "不可连接"
        var details = [
            "本地测速请求失败：\(errorSummary)",
            "本地端口 \(proxy.port) \(portState)",
            "Hysteria 进程\(processState)"
        ]

        if let latestLog = hysteriaLogMessage(from: proxy.logBuffer), !latestLog.isEmpty {
            details.append("最近 HY2 日志：\(latestLog)")
        }

        return details.joined(separator: "；")
    }

    private func hysteriaLogMessage(from buffer: ProcessOutputBuffer) -> String? {
        buffer.latestLine(maxLength: 600).map(DisconnectLogEntry.cleanedMessage)
    }

    private static func errorSummary(_ error: Error) -> String {
        if let nodeProbeError = error as? NodeProbeError,
           let description = nodeProbeError.errorDescription {
            return description
        }

        let nsError = error as NSError
        let summary = errorCodeSummary(nsError)
        let localizedDescription = nsError.localizedDescription
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map(errorCodeSummary)

        var parts = [summary]
        if !localizedDescription.isEmpty,
           localizedDescription != summary,
           !localizedDescription.localizedCaseInsensitiveContains(summary) {
            parts.append(localizedDescription)
        }
        if let underlying, underlying != summary {
            parts.append("底层 \(underlying)")
        }

        return parts.joined(separator: " / ")
    }

    private static func shouldRetryHTTPProxyStatus(_ statusCode: Int) -> Bool {
        [502, 503, 504].contains(statusCode)
    }

    private static func errorCodeSummary(_ error: NSError) -> String {
        let lowercasedDomain = error.domain.lowercased()

        if lowercasedDomain.contains("cfnetwork"), error.code == 310 {
            return "CFNetwork 310"
        }

        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorTimedOut:
                return "URLSession 超时 (\(error.domain) \(error.code))"
            case NSURLErrorCannotConnectToHost:
                return "无法连接到本地代理 (\(error.domain) \(error.code))"
            case NSURLErrorNetworkConnectionLost:
                return "本地代理连接中断 (\(error.domain) \(error.code))"
            default:
                return "\(error.domain) \(error.code)"
            }
        }

        return "\(error.domain) \(error.code)"
    }

    private static func normalizeURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if let correctedHysteriaURL = correctedAccidentalHTTPPrefix(from: trimmed) {
            return correctedHysteriaURL
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://") ||
            lowercased.hasPrefix("https://") ||
            lowercased.hasPrefix("hysteria2://") ||
            lowercased.hasPrefix("hy2://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private static func correctedAccidentalHTTPPrefix(from urlString: String) -> String? {
        let lowercased = urlString.lowercased()
        let accidentalPrefixes = [
            "https://hysteria2://",
            "http://hysteria2://",
            "https://hy2://",
            "http://hy2://"
        ]

        guard let prefix = accidentalPrefixes.first(where: { lowercased.hasPrefix($0) }) else {
            return nil
        }

        return String(urlString.dropFirst(prefix.hasPrefix("https://") ? "https://".count : "http://".count))
    }

    private func isSupportedNodeURL(_ urlString: String) -> Bool {
        switch NodeKind(urlString: urlString) {
        case .http:
            return URL(string: urlString) != nil
        case .hysteria2:
            return Hysteria2Endpoint(urlString: urlString) != nil
        case .unsupported:
            return false
        }
    }

    private func persistNodes() {
        if let data = try? JSONEncoder().encode(nodes) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func persistSelectedNodeID() {
        if let selectedNodeID {
            UserDefaults.standard.set(selectedNodeID.uuidString, forKey: selectedNodeIDStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: selectedNodeIDStorageKey)
        }
    }

    private func persistDisconnectCounts() {
        let encodedCounts = Dictionary(uniqueKeysWithValues: disconnectCounts.map { key, value in
            (key.uuidString, value)
        })
        UserDefaults.standard.set(encodedCounts, forKey: disconnectCountsStorageKey)
    }

    private func persistDisconnectLogs() {
        if let data = try? JSONEncoder().encode(disconnectLogs) {
            UserDefaults.standard.set(data, forKey: disconnectLogsStorageKey)
        }
    }

    private static func loadNodes(storageKey: String) -> [NodeEndpoint] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let nodes = try? JSONDecoder().decode([NodeEndpoint].self, from: data) else {
            return []
        }
        return nodes
    }

    private static func loadSelectedNodeID(storageKey: String, nodes: [NodeEndpoint]) -> UUID? {
        guard let uuidString = UserDefaults.standard.string(forKey: storageKey),
              let uuid = UUID(uuidString: uuidString),
              nodes.contains(where: { $0.id == uuid }) else {
            return nodes.first?.id
        }

        return uuid
    }

    private static func loadDisconnectCounts(storageKey: String) -> [UUID: Int] {
        guard let rawCounts = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Int] else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: rawCounts.compactMap { key, value in
            guard let uuid = UUID(uuidString: key) else {
                return nil
            }
            return (uuid, value)
        })
    }

    private static func loadDisconnectLogs(storageKey: String) -> [DisconnectLogEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let entries = try? JSONDecoder().decode([DisconnectLogEntry].self, from: data) else {
            return []
        }

        return entries.sorted { $0.startedAt > $1.startedAt }
    }

}

struct StatusBarSnapshot: Equatable {
    enum LightColor: Equatable {
        case green
        case red
        case orange
        case gray
    }

    let color: LightColor
    let title: String
}

private struct HysteriaProxy {
    let nodeID: UUID
    let urlString: String
    let port: UInt16
    let process: Process
    let configURL: URL
    let logPipe: Pipe
    let logBuffer: ProcessOutputBuffer
}

private struct HysteriaProxyError: Error {
    let message: String
}

enum NodeProbeError: LocalizedError {
    case httpStatus(Int)
    case socket(String)

    var errorDescription: String? {
        switch self {
        case let .httpStatus(statusCode):
            return "测试请求 HTTP \(statusCode)"
        case let .socket(message):
            return message
        }
    }
}

private final class ProcessOutputBuffer {
    private let lock = NSLock()
    private var output = ""

    func attach(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData

            guard !data.isEmpty else {
                fileHandle.readabilityHandler = nil
                return
            }

            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                return
            }

            self?.append(text)
        }
    }

    func latestLine(maxLength: Int) -> String? {
        lock.lock()
        let snapshot = output
        lock.unlock()

        guard let line = snapshot
            .split(separator: "\n")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !line.isEmpty else {
            return nil
        }

        return String(line.prefix(maxLength))
    }

    private func append(_ text: String) {
        lock.lock()
        output += text

        if output.count > 4_000 {
            output = String(output.suffix(4_000))
        }

        lock.unlock()
    }
}
