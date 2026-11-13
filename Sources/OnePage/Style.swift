import SwiftUI
import Observation

// Both apps use the same palettes; only confirmed choices are persisted.
enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case graphite, sage, slate, clay, plum

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .sage: L("灰绿")
        case .slate: L("岩蓝")
        case .graphite: L("石墨")
        case .clay: L("暖陶棕")
        case .plum: L("烟紫")
        }
    }

    private var colors: (accent: UInt32, background: UInt32, selection: UInt32, sidebar: UInt32) {
        switch self {
        case .sage: (0x566C5D, 0xF8F8F6, 0xE9EEE8, 0xF0F1EE)
        case .slate: (0x526B8A, 0xF7F8FA, 0xE8EDF4, 0xEEF0F3)
        case .graphite: (0x34373C, 0xF8F8F7, 0xE9EAEB, 0xEFEFF0)
        case .clay: (0x826451, 0xFAF8F5, 0xEEE7E0, 0xF2EFEB)
        case .plum: (0x726582, 0xF9F8FA, 0xEDE9F1, 0xF1EFF3)
        }
    }

    var accent: Color { color(colors.accent) }
    var background: Color { color(colors.background) }
    var selection: Color { color(colors.selection) }
    var sidebar: Color { color(colors.sidebar) }

    private func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }
}

@MainActor
@Observable
final class ThemeSettings {
    static let shared = ThemeSettings()

    var current: AppTheme {
        didSet {
            guard current != oldValue else { return }
            defaults.set(current.rawValue, forKey: key)
        }
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "OnePage.interfaceTheme") {
        self.defaults = defaults
        self.key = key
        current = AppTheme(rawValue: defaults.string(forKey: key) ?? "") ?? .graphite
    }
}

// Computed tokens keep SwiftUI's Observation dependency on the committed theme.
// Do not cache theme-dependent colors in static lets or reset view identity on changes.
enum Style {
    static let brand = AppTheme.graphite.accent
    @MainActor static var background: Color { ThemeSettings.shared.current.background }
    @MainActor static var sidebar: Color { ThemeSettings.shared.current.sidebar }
    @MainActor static var toolRail: Color { sidebar }
    static let detail = Color.white
    @MainActor static var selection: Color { ThemeSettings.shared.current.selection }
    @MainActor static var buttonFill: Color { sidebar }
    @MainActor static var accent: Color { ThemeSettings.shared.current.accent }
    @MainActor static var accentInk: Color { accent }
    static let ink = Color(red: 36 / 255, green: 39 / 255, blue: 35 / 255)
    static let secondaryText = Color(red: 101 / 255, green: 107 / 255, blue: 100 / 255)
    static let mutedText = Color(red: 116 / 255, green: 122 / 255, blue: 115 / 255)
    static let separator = Color(red: 224 / 255, green: 227 / 255, blue: 221 / 255)
    static let overdue = Color(red: 166 / 255, green: 83 / 255, blue: 69 / 255)
    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size, weight: bold ? .semibold : .regular)
    }
}

@MainActor
struct ThemeSelectionView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @Binding var selection: AppTheme
    let current: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("主题色")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                .accessibilityAddTraits(.isHeader)
            Label {
                Text(LF("当前主题：%@", current.displayName))
            } icon: {
                Circle().fill(current.accent).frame(width: 12, height: 12)
            }
            .font(Style.font(14)).foregroundStyle(Style.ink)
            .accessibilityIdentifier("settings-current-theme")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(AppTheme.allCases) { theme in
                    Button { selection = theme } label: {
                        HStack(spacing: 8) {
                            Circle().fill(theme.accent).frame(width: 20, height: 20)
                            Text(theme.displayName).font(Style.font(15, bold: selection == theme))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if selection == theme {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                            }
                        }
                        .foregroundStyle(Style.ink)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(theme.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(selection == theme ? theme.accent : Style.separator,
                                              lineWidth: selection == theme ? 1.5 : 1)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.displayName)
                    .accessibilityAddTraits(selection == theme ? .isSelected : [])
                    .accessibilityIdentifier("theme-\(theme.rawValue)")
                }
            }
            if selection != current {
                Text(LF("待确认主题：%@", selection.displayName))
                    .font(Style.font(13)).foregroundStyle(Style.secondaryText)
                    .accessibilityIdentifier("settings-pending-theme")
            }
            Text(L("点击“确认”后应用主题，取消或离开不会保存。主题仅保存在本机。"))
                .font(Style.font(13)).foregroundStyle(Style.secondaryText).lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
