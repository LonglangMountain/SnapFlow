import AppKit

/// Checks GitHub Releases for a newer SnapFlow version.
///
/// Compares the latest release tag (e.g. `v0.3.0`) against the bundle's
/// `CFBundleShortVersionString`. Only reads the public releases API; nothing
/// about the user or machine is sent.
@MainActor
enum UpdateChecker {

    static let repoPage = URL(string: "https://github.com/LonglangMountain/SnapFlow")!
    static let releasesPage = URL(string: "https://github.com/LonglangMountain/SnapFlow/releases/latest")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/LonglangMountain/SnapFlow/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    enum Result {
        case upToDate
        case available(version: String)
        case failed(String)
    }

    static func check() async -> Result {
        var request = URLRequest(url: latestAPI, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SnapFlow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Anonymous GitHub API calls are limited to 60/hour per IP.
            if status == 403 || status == 429 { return .failed("请求过于频繁，请稍后再试") }
            guard status == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                return .failed("无法获取版本信息")
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            return isNewer(latest, than: currentVersion) ? .available(version: latest) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func promptUpdate(_ version: String) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(version)"
        alert.informativeText = "当前版本 \(currentVersion)。是否前往下载页面？"
        alert.addButton(withTitle: "前往下载")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(releasesPage)
        }
    }

    /// Numeric dotted-version comparison ("0.10.0" > "0.9.1").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
