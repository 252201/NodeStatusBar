import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private let monitor: NodeMonitor
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var onlineSummaryItem: NSMenuItem?
    private var disconnectSummaryItem: NSMenuItem?
    private var latencyMenuItem: NSMenuItem?
    private var nodeMenuItems: [UUID: NSMenuItem] = [:]

    init(monitor: NodeMonitor) {
        self.monitor = monitor
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.menu = menu
        configureButton()
        rebuildMenu()
        bindMonitor()
    }

    func start() {
        monitor.start()
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            return
        }

        button.image = nil
        button.attributedTitle = attributedStatusTitle(for: monitor.statusBarSnapshot)
    }

    private func bindMonitor() {
        monitor.$nodes
            .combineLatest(monitor.$statuses)
            .combineLatest(monitor.$selectedNodeID)
            .combineLatest(monitor.$latencyDetectionEnabled)
            .combineLatest(monitor.$disconnectCounts)
            .combineLatest(monitor.$disconnectLogs)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItem()
                self?.updateMenu()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        statusItem.button?.attributedTitle = attributedStatusTitle(for: monitor.statusBarSnapshot)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        nodeMenuItems.removeAll()

        let versionItem = NSMenuItem(title: "NodeStatusBar \(AppInfo.displayVersion)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        let summary = NSMenuItem(title: "在线 \(monitor.onlineCount) / \(monitor.nodes.count)", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        onlineSummaryItem = summary
        menu.addItem(summary)
        let disconnectSummary = NSMenuItem(title: "断连 \(monitor.totalDisconnectCount) 次", action: nil, keyEquivalent: "")
        disconnectSummary.isEnabled = false
        disconnectSummaryItem = disconnectSummary
        menu.addItem(disconnectSummary)
        menu.addItem(.separator())

        if monitor.nodes.isEmpty {
            let empty = NSMenuItem(title: "还没有配置节点", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for node in monitor.nodes {
                let item = NSMenuItem(title: "", action: #selector(selectNodeForStatusBar(_:)), keyEquivalent: "")
                item.toolTip = nil
                item.target = self
                item.representedObject = node.id
                nodeMenuItems[node.id] = item
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshNow), keyEquivalent: "r", target: self))
        let latencyItem = NSMenuItem(title: "延迟检测", action: #selector(toggleLatencyDetection), keyEquivalent: "", target: self)
        latencyItem.state = monitor.latencyDetectionEnabled ? .on : .off
        latencyMenuItem = latencyItem
        menu.addItem(latencyItem)
        menu.addItem(NSMenuItem(title: "清零断连次数...", action: #selector(resetDisconnectCounts), keyEquivalent: "", target: self))
        menu.addItem(NSMenuItem(title: "设置节点...", action: #selector(showSettings), keyEquivalent: ",", target: self))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 NodeStatusBar", action: #selector(quit), keyEquivalent: "q", target: self))
        updateMenuItemTitles()
    }

    private func updateMenu() {
        rebuildMenu()
    }

    private func updateMenuItemTitles() {
        onlineSummaryItem?.title = "在线 \(monitor.onlineCount) / \(monitor.nodes.count)"
        disconnectSummaryItem?.title = "断连 \(monitor.totalDisconnectCount) 次"
        latencyMenuItem?.state = monitor.latencyDetectionEnabled ? .on : .off

        for node in monitor.nodes {
            guard let item = nodeMenuItems[node.id] else {
                continue
            }

            let health = monitor.status(for: node)
            let selectionMark = monitor.isSelectedForStatusBar(node) ? "  ✓" : ""
            let disconnectText = "断连 \(monitor.disconnectCount(for: node)) 次"
            item.attributedTitle = attributedMenuTitle(
                "\(symbol(for: health)) \(node.displayName)  \(health.shortLabel)  \(disconnectText)\(selectionMark)",
                health: health
            )
            item.toolTip = nil
        }
    }

    private func symbol(for health: NodeHealth) -> String {
        switch health {
        case .online:
            return "●"
        case .offline:
            return "●"
        case .checking:
            return "◌"
        case .unknown:
            return "○"
        }
    }

    private func attributedStatusTitle(for snapshot: StatusBarSnapshot) -> NSAttributedString {
        let text = "● \(snapshot.title)"
        let attributedString = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor
            ]
        )

        attributedString.addAttribute(
            .foregroundColor,
            value: color(for: snapshot.color),
            range: NSRange(location: 0, length: 1)
        )

        return attributedString
    }

    private func attributedMenuTitle(_ text: String, health: NodeHealth) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor
            ]
        )

        attributedString.addAttribute(
            .foregroundColor,
            value: color(for: lightColor(for: health)),
            range: NSRange(location: 0, length: 1)
        )

        return attributedString
    }

    private func lightColor(for health: NodeHealth) -> StatusBarSnapshot.LightColor {
        switch health {
        case .online:
            return .green
        case .offline:
            return .red
        case .checking:
            return .orange
        case .unknown:
            return .gray
        }
    }

    private func color(for lightColor: StatusBarSnapshot.LightColor) -> NSColor {
        switch lightColor {
        case .green:
            return .systemGreen
        case .red:
            return .systemRed
        case .orange:
            return .systemOrange
        case .gray:
            return .systemGray
        }
    }

    @objc private func refreshNow() {
        Task {
            await monitor.refresh()
        }
    }

    @objc private func toggleLatencyDetection() {
        monitor.toggleLatencyDetection()
    }

    @objc private func resetDisconnectCounts() {
        guard confirmResetDisconnectCounts(title: "清零全部断连次数？", message: "这会删除所有节点的断连次数和断连日志，操作不可撤销。") else {
            return
        }

        monitor.resetAllDisconnectCounts()
    }

    private func confirmResetDisconnectCounts(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "清零")
        alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func selectNodeForStatusBar(_ sender: NSMenuItem) {
        guard let nodeID = sender.representedObject as? UUID,
              let node = monitor.nodes.first(where: { $0.id == nodeID }) else {
            return
        }

        monitor.selectForStatusBar(node)
    }

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: PreferencesView(monitor: monitor))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "节点设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}
