import Foundation

enum AppInfo {
    static var displayVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.5"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "6"
        return "v\(version) (\(build))"
    }
}
