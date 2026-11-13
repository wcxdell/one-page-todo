import Foundation
import Combine

enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case chinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: L("跟随系统")
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
}

enum AppInterfaceLanguage: String, CaseIterable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"
    var locale: Locale { Locale(identifier: rawValue) }
}

enum L10n {
    static var defaults: UserDefaults { .standard }

    static var preferenceKey: String {
        #if DEBUG
        // UI automation has its own preference key, just as it has its own task file.
        // Tests must never reset the user's real language selection.
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--test-store"), arguments.indices.contains(index + 1),
           let id = UUID(uuidString: arguments[index + 1]) {
            return "OnePage.interfaceLanguage.test." + id.uuidString
        }
        #endif
        return "OnePage.interfaceLanguage"
    }

    static func resolve(_ preference: AppLanguagePreference, preferredLanguages: [String]) -> AppInterfaceLanguage {
        switch preference {
        case .chinese: return .chinese
        case .english: return .english
        case .system:
            for language in preferredLanguages {
                let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
                if code == "zh" || code.hasPrefix("zh-") { return .chinese }
                if code == "en" || code.hasPrefix("en-") { return .english }
            }
            return .english
        }
    }

    static var currentLanguage: AppInterfaceLanguage {
        let preference = AppLanguagePreference(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .system
        return resolve(preference, preferredLanguages: Locale.preferredLanguages)
    }

    static var locale: Locale { currentLanguage.locale }

    static func text(_ key: String, language: AppInterfaceLanguage? = nil) -> String {
        let language = language ?? currentLanguage
        guard language == .english else { return key }
        if let translated = LocalizationCatalog.english[key] { return translated }
        // Only translate known UI prefixes. Never translate task data, paths or arbitrary diagnostics.
        for prefix in [
            "无法读取任务文件，已保留原文件。请检查 ",
            "保存失败，请检查磁盘空间和文件权限。\n",
            "网络暂不可用。", "iCloud 账户暂时不可用。", "iCloud 服务暂忙或请求受限。"
        ] where key.hasPrefix(prefix) {
            let suffix = String(key.dropFirst(prefix.count))
            return (LocalizationCatalog.english[prefix] ?? prefix) + text(suffix, language: language)
        }
        return key
    }

    static func format(_ key: String, arguments: [CVarArg], language: AppInterfaceLanguage? = nil) -> String {
        let language = language ?? currentLanguage
        return String(format: text(key, language: language), locale: language.locale, arguments: arguments)
    }

    static func dateFormat(_ chinese: String, _ english: String) -> String {
        currentLanguage == .chinese ? chinese : english
    }
}

func L(_ key: String) -> String { L10n.text(key) }
func LF(_ key: String, _ arguments: CVarArg...) -> String { L10n.format(key, arguments: arguments) }

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()

    @Published var preference: AppLanguagePreference {
        didSet {
            guard preference != oldValue else { return }
            defaults.set(preference.rawValue, forKey: key)
            refreshSystemLanguage()
        }
    }
    @Published private(set) var effectiveLanguage: AppInterfaceLanguage
    var locale: Locale { effectiveLanguage.locale }
    private let defaults: UserDefaults
    private let key: String
    private let systemLanguages: () -> [String]
    private var observer: LocaleObserver?

    init(defaults: UserDefaults = L10n.defaults, key: String = L10n.preferenceKey,
         systemLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.key = key
        self.systemLanguages = systemLanguages
        let choice = AppLanguagePreference(rawValue: defaults.string(forKey: key) ?? "") ?? .system
        preference = choice
        effectiveLanguage = L10n.resolve(choice, preferredLanguages: systemLanguages())
        observer = LocaleObserver { [weak self] in
            Task { @MainActor [weak self] in self?.refreshSystemLanguage() }
        }
    }

    func refreshSystemLanguage() {
        let resolved = L10n.resolve(preference, preferredLanguages: systemLanguages())
        if resolved != effectiveLanguage { effectiveLanguage = resolved }
    }

    private final class LocaleObserver: @unchecked Sendable {
        private let token: any NSObjectProtocol
        init(onChange: @escaping @Sendable () -> Void) {
            token = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                                                            object: nil, queue: nil) { _ in onChange() }
        }
        deinit { NotificationCenter.default.removeObserver(token) }
    }
}
