import SwiftUI

struct PreferencesView: View {
    @ObservedObject var monitor: NodeMonitor
    @State private var newName = ""
    @State private var newURL = ""
    @State private var logSearchText = ""
    @State private var logFilter: DisconnectLogFilter = .all
    @State private var showsResetAllConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            latencyToggle
            nodeList
            disconnectLogList
            addNodeForm
        }
        .padding(20)
        .frame(width: 700, height: 720)
        .alert("清空全部断连记录？", isPresented: $showsResetAllConfirmation) {
            Button("清空", role: .destructive) {
                monitor.resetAllDisconnectCounts()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除所有节点的断连次数和断连日志，操作不可撤销。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("节点状态")
                    .font(.title2.weight(.semibold))
                Text("NodeStatusBar \(AppInfo.displayVersion) · 延迟检测开启时显示真实链路延迟；关闭时只显示节点是否正常。")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await monitor.refresh()
                }
            } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
        }
    }

    private var latencyToggle: some View {
        Toggle(isOn: Binding(
            get: { monitor.latencyDetectionEnabled },
            set: { monitor.setLatencyDetectionEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("延迟检测")
                    .font(.headline)
                Text(monitor.latencyDetectionEnabled ? "状态栏显示真实延迟。" : "状态栏显示节点正常，检测频率更高。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }

    private var nodeList: some View {
        Group {
            if monitor.nodes.isEmpty {
                ContentUnavailableView("没有节点", systemImage: "network.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(monitor.nodes) { node in
                        NodeEditorRow(node: node, status: monitor.status(for: node), monitor: monitor)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minHeight: 210)
    }

    private var disconnectLogList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("断连日志")
                    .font(.headline)

                Text("\(monitor.disconnectLogs.count) 条")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                logFilterControl
                    .frame(width: 210)

                TextField("搜索节点或原因", text: $logSearchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)

                Button("清空全部") {
                    showsResetAllConfirmation = true
                }
                .disabled(monitor.disconnectLogs.isEmpty && monitor.totalDisconnectCount == 0)
            }

            if filteredDisconnectLogs.isEmpty {
                Text("暂无断连记录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    DisconnectLogHeader()

                    List {
                        ForEach(filteredDisconnectLogs) { log in
                            DisconnectLogRow(log: log) {
                                monitor.deleteDisconnectLog(log)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(height: 210)
            }
        }
    }

    private var filteredDisconnectLogs: [DisconnectLogEntry] {
        let trimmedSearchText = logSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return monitor.disconnectLogs.filter { log in
            switch logFilter {
            case .all:
                break
            case .local:
                guard log.isLocalProbeFailure else {
                    return false
                }
            case .recovered:
                guard !log.isOngoing && !log.isLocalProbeFailure else {
                    return false
                }
            }

            guard !trimmedSearchText.isEmpty else {
                return true
            }

            return log.nodeName.lowercased().contains(trimmedSearchText) ||
                log.displayMessage.lowercased().contains(trimmedSearchText)
        }
    }

    private var logFilterControl: some View {
        HStack(spacing: 0) {
            ForEach(DisconnectLogFilter.allCases) { filter in
                Button {
                    logFilter = filter
                } label: {
                    Text(filter.title)
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(logFilter == filter ? Color.accentColor : Color.clear)
                        .foregroundStyle(logFilter == filter ? .white : .primary)
                }
                .buttonStyle(.plain)

                if filter.id != DisconnectLogFilter.allCases.last?.id {
                    Divider()
                        .frame(height: 18)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var addNodeForm: some View {
        HStack(spacing: 10) {
            TextField("名称", text: $newName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)

            TextField("https://example.com/health 或 hysteria2://...", text: $newURL)
                .textFieldStyle(.roundedBorder)

            Button {
                monitor.addNode(name: newName, urlString: newURL)
                newName = ""
                newURL = ""
            } label: {
                Label("添加", systemImage: "plus")
            }
            .disabled(newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

private struct NodeEditorRow: View {
    let node: NodeEndpoint
    let status: NodeHealth
    @ObservedObject var monitor: NodeMonitor

    @State private var name: String
    @State private var urlString: String
    @State private var isURLVisible = false
    @State private var showsResetDisconnectConfirmation = false

    init(node: NodeEndpoint, status: NodeHealth, monitor: NodeMonitor) {
        self.node = node
        self.status = status
        self.monitor = monitor
        _name = State(initialValue: node.name)
        _urlString = State(initialValue: node.urlString)
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button {
                        monitor.selectForStatusBar(node)
                    } label: {
                        Image(systemName: monitor.isSelectedForStatusBar(node) ? "pin.fill" : "pin")
                    }
                    .help("显示到状态栏")

                    TextField("名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)

                    urlField

                    Button {
                        isURLVisible.toggle()
                    } label: {
                        Image(systemName: isURLVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28)
                    .help(isURLVisible ? "隐藏节点地址" : "显示节点地址")
                }

                Text(status.menuDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Text("断连 \(monitor.disconnectCount(for: node)) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("清零断连") {
                        showsResetDisconnectConfirmation = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .disabled(monitor.disconnectCount(for: node) == 0)
                }

                if let latestLog = monitor.latestDisconnectLog(for: node) {
                    Text("最近断连 \(DisconnectLogFormat.startedAt(latestLog)) · \(DisconnectLogFormat.duration(latestLog))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                monitor.updateNode(node, name: name, urlString: urlString)
            } label: {
                Image(systemName: "checkmark")
            }
            .help("保存")

            Button(role: .destructive) {
                monitor.removeNode(node)
            } label: {
                Image(systemName: "trash")
            }
            .help("删除")
        }
        .padding(.vertical, 4)
        .alert("清零 \(node.displayName) 的断连记录？", isPresented: $showsResetDisconnectConfirmation) {
            Button("清零", role: .destructive) {
                monitor.resetDisconnectCount(for: node)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这会删除该节点的断连次数和断连日志，操作不可撤销。")
        }
    }

    @ViewBuilder
    private var urlField: some View {
        if isURLVisible {
            TextField("URL", text: $urlString)
                .textFieldStyle(.roundedBorder)
        } else {
            SecureField("URL", text: $urlString)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var statusColor: Color {
        switch status {
        case .online:
            return .green
        case .offline:
            return .red
        case .checking:
            return .orange
        case .unknown:
            return .secondary
        }
    }
}

private enum DisconnectLogFilter: String, CaseIterable, Identifiable {
    case all
    case local
    case recovered

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .all:
            return "全部"
        case .local:
            return "本地原因"
        case .recovered:
            return "已恢复"
        }
    }
}

private struct DisconnectLogHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("节点")
                .frame(width: 82, alignment: .leading)
            Text("时间")
                .frame(width: 130, alignment: .leading)
            Text("时长")
                .frame(width: 66, alignment: .leading)
            Text("状态")
                .frame(width: 58, alignment: .leading)
            Text("原因")
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            Text("")
                .frame(width: 32)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct DisconnectLogRow: View {
    let log: DisconnectLogEntry
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(log.nodeName)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .frame(width: 82, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(DisconnectLogFormat.startedAt(log))
                Text(DisconnectLogFormat.endedAt(log))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 130, alignment: .leading)

            Text(DisconnectLogFormat.duration(log))
                .font(.caption.monospacedDigit())
                .foregroundStyle(log.isOngoing ? .red : .secondary)
                .frame(width: 66, alignment: .leading)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusColor)
                .frame(width: 58, alignment: .leading)

            Text(log.displayMessage.isEmpty ? "-" : log.displayMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("删除这条日志")
        }
        .padding(.vertical, 3)
    }

    private var statusText: String {
        if log.isLocalProbeFailure {
            return "本地原因"
        }

        return log.isOngoing ? "断连中" : "已恢复"
    }

    private var statusColor: Color {
        if log.isLocalProbeFailure {
            return .orange
        }

        return log.isOngoing ? .red : .green
    }
}

private enum DisconnectLogFormat {
    static func startedAt(_ log: DisconnectLogEntry) -> String {
        "开始 \(dateFormatter.string(from: log.startedAt))"
    }

    static func endedAt(_ log: DisconnectLogEntry) -> String {
        guard let endedAt = log.endedAt else {
            return "恢复 进行中"
        }

        return "恢复 \(dateFormatter.string(from: endedAt))"
    }

    static func duration(_ log: DisconnectLogEntry) -> String {
        let elapsed = log.endedAt?.timeIntervalSince(log.startedAt) ?? Date().timeIntervalSince(log.startedAt)
        return (log.isOngoing ? "已断连 " : "持续 ") + formatDuration(elapsed)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()

    private static func formatDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if days > 0 {
            return "\(days)天 \(hours)小时"
        }

        if hours > 0 {
            return "\(hours)小时 \(minutes)分"
        }

        if minutes > 0 {
            return "\(minutes)分 \(seconds)秒"
        }

        return "\(seconds)秒"
    }
}

#Preview {
    PreferencesView(monitor: NodeMonitor())
}
