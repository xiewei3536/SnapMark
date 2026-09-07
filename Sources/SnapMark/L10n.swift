import AppKit
import Combine

/// Localization engine with instant in-app language switching (no relaunch needed).
///
/// Strings live in `<code>.lproj/Localizable.strings`. We locate them ourselves instead of
/// relying on SwiftPM's `Bundle.module`, whose generated accessor looks *next to* the .app
/// and otherwise hard-codes this machine's build directory — i.e. it would crash on launch
/// on any other Mac.
final class L10n: ObservableObject {
    static let shared = L10n()

    enum Language: String, CaseIterable, Identifiable {
        case system = "system"
        case english = "en"
        case simplifiedChinese = "zh-Hans"
        case traditionalChinese = "zh-Hant"
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: return L("lang.system")
            case .english: return "English"
            case .simplifiedChinese: return "简体中文"
            case .traditionalChinese: return "繁體中文"
            }
        }
    }

    /// Bumped on every language change so SwiftUI views refresh.
    @Published private(set) var revision: Int = 0

    private var table: [String: String] = [:]
    private var fallback: [String: String] = [:]
    private(set) var language: Language = .system

    private init() {
        let stored = UserDefaults.standard.string(forKey: "language") ?? "system"
        language = Language(rawValue: stored) ?? .system
        fallback = Self.loadTable(code: "en")
        reload()
    }

    func setLanguage(_ lang: Language) {
        guard lang != language else { return }
        language = lang
        UserDefaults.standard.set(lang.rawValue, forKey: "language")
        reload()
        DispatchQueue.main.async {
            self.revision += 1
            NotificationCenter.default.post(name: .snapMarkLanguageChanged, object: nil)
        }
    }

    var effectiveCode: String {
        if language != .system { return language.rawValue }
        for pref in Locale.preferredLanguages {
            let low = pref.lowercased()
            if low.hasPrefix("zh") {
                if low.contains("hant") || low.contains("tw") || low.contains("hk") || low.contains("mo") {
                    return "zh-Hant"
                }
                return "zh-Hans"
            }
            if low.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    private func reload() {
        table = Self.loadTable(code: effectiveCode)
    }

    fileprivate func string(_ key: String) -> String {
        table[key] ?? fallback[key] ?? key
    }

    // MARK: Resource lookup

    /// Directories that may contain `<code>.lproj`, in priority order:
    /// 1. `SnapMark.app/Contents/Resources` (build.sh layout)
    /// 2. `…/Resources/SnapMark_SnapMark.bundle` (SwiftPM bundle copied into the app)
    /// 3. next to the executable (`swift build` / `swift run` layout)
    private static let searchDirectories: [URL] = {
        var dirs: [URL] = []
        let bundleName = "SnapMark_SnapMark.bundle"
        if let res = Bundle.main.resourceURL {
            dirs.append(res)
            dirs.append(res.appendingPathComponent(bundleName))
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            dirs.append(exeDir.appendingPathComponent(bundleName))
            dirs.append(exeDir)
        }
        dirs.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        return dirs
    }()

    private static func loadTable(code: String) -> [String: String] {
        for dir in searchDirectories {
            let url = dir.appendingPathComponent("\(code).lproj").appendingPathComponent("Localizable.strings")
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dict = plist as? [String: String]
            else { continue }
            return dict
        }
        NSLog("SnapMark: Localizable.strings for '\(code)' not found in \(searchDirectories.map(\.path))")
        return [:]
    }
}

extension Notification.Name {
    static let snapMarkLanguageChanged = Notification.Name("SnapMarkLanguageChanged")
}

/// Global convenience: localized string lookup.
func L(_ key: String) -> String {
    L10n.shared.string(key)
}

/// Localized string with format arguments.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.shared.string(key), arguments: args)
}
