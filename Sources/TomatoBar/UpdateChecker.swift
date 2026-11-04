import AppKit

/// 对照 GitHub 最新 Release 检查更新。只提示，不下载安装包。
@MainActor
enum UpdateChecker {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/teojs/TomatoBar/releases/latest")!
    private static var isChecking = false

    static func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            do {
                present(try await fetchLatest())
            } catch {
                presentFailure()
            }
        }
    }

    private static func fetchLatest() async throws -> CheckResult {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 20)
        request.setValue("TomatoBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CheckError.failed }
        if http.statusCode == 404 {
            return .upToDate
        }
        guard http.statusCode == 200 else { throw CheckError.failed }

        let release = try JSONDecoder().decode(Release.self, from: data)
        guard let latest = Version(release.tagName), let current = currentVersion() else {
            throw CheckError.failed
        }
        if latest > current {
            return .updateAvailable(version: latest.description, url: release.htmlURL)
        }
        return .upToDate
    }

    private static func currentVersion() -> Version? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return raw.flatMap(Version.init)
    }

    private static func present(_ result: CheckResult) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        switch result {
        case .upToDate:
            alert.messageText = "已经是最新版本"
            alert.addButton(withTitle: "好")
            alert.runModal()
        case let .updateAvailable(version, url):
            alert.messageText = "前往更新"
            alert.informativeText = "最新版本 \(version)"
            alert.addButton(withTitle: "前往更新")
            alert.addButton(withTitle: "取消")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func presentFailure() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "无法检查更新"
        alert.informativeText = "请稍后再试"
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

private enum CheckResult {
    case upToDate
    case updateAvailable(version: String, url: URL)
}

private struct Release: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}

private struct Version: Comparable, CustomStringConvertible {
    let numbers: [Int]

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" {
            text.removeFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        self.numbers = numbers
    }

    var description: String {
        numbers.map(String.init).joined(separator: ".")
    }

    static func < (lhs: Version, rhs: Version) -> Bool {
        for (left, right) in zip(lhs.numbers, rhs.numbers) where left != right {
            return left < right
        }
        return false
    }
}

private enum CheckError: Error {
    case failed
}
