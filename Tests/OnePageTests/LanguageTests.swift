import Foundation
import XCTest
@testable import OnePage

final class LanguageTests: XCTestCase {
    func testSystemLanguageResolutionAndSupportedFallbacks() {
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["zh-Hans-CN", "en-US"]), .chinese)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["zh-Hant-TW"]), .chinese)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["fr-FR", "zh_CN"]), .chinese)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(L10n.resolve(.system, preferredLanguages: []), .english)
    }

    func testManualSelectionAlwaysOverridesDeviceLanguage() {
        XCTAssertEqual(L10n.resolve(.english, preferredLanguages: ["zh-Hans"]), .english)
        XCTAssertEqual(L10n.resolve(.chinese, preferredLanguages: ["en-US"]), .chinese)
    }

    @MainActor func testDefaultIsSystemAndManualChoiceSurvivesRecreation() throws {
        let defaults = try isolatedDefaults()
        let key = "preference"
        let originalSystemLanguages = defaults.stringArray(forKey: "AppleLanguages")
        let initial = LanguageSettings(defaults: defaults, key: key, systemLanguages: { ["zh-Hans"] })
        XCTAssertEqual(initial.preference, .system)
        XCTAssertEqual(initial.effectiveLanguage, .chinese)
        XCTAssertNil(defaults.object(forKey: key))
        initial.preference = .english
        XCTAssertEqual(defaults.string(forKey: key), "en")
        XCTAssertEqual(initial.effectiveLanguage, .english)
        let recreated = LanguageSettings(defaults: defaults, key: key, systemLanguages: { ["zh-Hans"] })
        XCTAssertEqual(recreated.preference, .english)
        XCTAssertEqual(recreated.effectiveLanguage, .english)
        recreated.preference = .system
        XCTAssertEqual(recreated.effectiveLanguage, .chinese)
        XCTAssertEqual(defaults.string(forKey: key), "system")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), originalSystemLanguages)
    }

    @MainActor func testSystemChangesRefreshOnlyAutomaticChoice() throws {
        let defaults = try isolatedDefaults()
        var system = ["en-US"]
        let settings = LanguageSettings(defaults: defaults, key: "language", systemLanguages: { system })
        XCTAssertEqual(settings.effectiveLanguage, .english)
        system = ["zh-Hans"]
        settings.refreshSystemLanguage()
        XCTAssertEqual(settings.effectiveLanguage, .chinese)
        settings.preference = .english
        settings.refreshSystemLanguage()
        XCTAssertEqual(settings.effectiveLanguage, .english)
        settings.preference = .system
        XCTAssertEqual(settings.effectiveLanguage, .chinese)
    }

    @MainActor func testInvalidPreferenceFallsBackWithoutChangingOtherSettings() throws {
        let defaults = try isolatedDefaults()
        defaults.set("invalid", forKey: "language")
        defaults.set("keep", forKey: "unrelated")
        let originalSystemLanguages = defaults.stringArray(forKey: "AppleLanguages")
        let settings = LanguageSettings(defaults: defaults, key: "language", systemLanguages: { ["en"] })
        XCTAssertEqual(settings.preference, .system)
        XCTAssertEqual(settings.effectiveLanguage, .english)
        settings.preference = .chinese
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), originalSystemLanguages)
    }

    func testEnglishUIAndFormatStrings() {
        XCTAssertEqual(L10n.text("设置", language: .english), "Settings")
        XCTAssertEqual(L10n.text("任务", language: .english), "Tasks")
        XCTAssertEqual(L10n.text("今天", language: .english), "Today")
        XCTAssertEqual(L10n.text("一页待办", language: .english), "OnePage")
        XCTAssertEqual(L10n.text("设置", language: .chinese), "设置")
        XCTAssertEqual(L10n.format("已完成 %ld", arguments: [2], language: .english), "Completed 2")
        XCTAssertEqual(L10n.format("版本 %@（构建 %@）", arguments: ["1.0", "9"], language: .english), "Version 1.0 (Build 9)")
        XCTAssertEqual(L10n.format("完成 %@", arguments: ["中文标题"], language: .english), "Complete 中文标题")
    }

    func testLocalizedUILeavesUserContentAndErrorPathsIntact() {
        let title = "今天"
        let task = Todo(title: title, details: "用户自己的备注", date: nil)
        XCTAssertEqual(task.displayTitle, title)
        XCTAssertEqual(task.details, "用户自己的备注")
        XCTAssertEqual(L10n.text("用户自己的备注", language: .english), "用户自己的备注")
        let path = "/test/未安排/中文任务.json"
        let message = "无法读取任务文件，已保留原文件。请检查 " + path
        let translated = L10n.text(message, language: .english)
        XCTAssertTrue(translated.hasSuffix(path))
        XCTAssertNotEqual(translated, message)
    }

    func testAllEnglishCatalogEntriesAreNonemptyAndKeepFormatArguments() {
        let regex = try! NSRegularExpression(pattern: #"%(?:ld|@)"#)
        for (key, translation) in LocalizationCatalog.english {
            XCTAssertFalse(translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key)
            func tokens(_ text: String) -> [String] {
                let text = text as NSString
                return regex.matches(in: text as String, range: NSRange(location: 0, length: text.length))
                    .map { text.substring(with: $0.range) }.sorted()
            }
            XCTAssertEqual(tokens(key), tokens(translation), key)
        }
    }

    private func isolatedDefaults() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "OnePage.LanguageTests." + UUID().uuidString))
    }
}
