//
//  NodeStatusBarApp.swift
//  NodeStatusBar
//
//  Created by LPP on 2026/6/2.
//

import SwiftUI

@main
struct NodeStatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            PreferencesView(monitor: appDelegate.monitor)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = NodeMonitor()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBarController = StatusBarController(monitor: monitor)
        statusBarController?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stopAllHysteriaProxies()
    }
}
