import Testing
import UIKit
@testable import nodeseek

@MainActor
@Suite(.serialized)
struct AppTextSizeSettingsTests {
    private func settings(_ defaults: UserDefaults, category: UIContentSizeCategory = .large) -> AppTextSizeSettings {
        AppTextSizeSettings(userDefaults: defaults, storageKey: "size", contentSizeCategory: category, observeSystemChanges: false)
    }

    @Test func newInstallFollowsSystemAndExistingOffsetRemainsManual() throws {
        let name = "typography-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(settings(defaults).followsSystem)
        #expect(settings(defaults).displayText == "跟随系统")
        defaults.removeObject(forKey: "size.followsSystem")
        defaults.set(2, forKey: "size")
        let migrated = settings(defaults)
        #expect(!migrated.followsSystem)
        #expect(migrated.pointOffset == 2)
        #expect(migrated.displayText == "+2")
        migrated.setFollowsSystem(true)
        #expect(settings(defaults).followsSystem)
        migrated.setFollowsSystem(false)
        #expect(settings(defaults).pointOffset == 2)
    }

    @Test func systemCategoryOnlyNotifiesInSystemModeAndSuppressesDuplicates() throws {
        let name = "typography-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = settings(defaults)
        var changes = 0
        let observer = NotificationCenter.default.addObserver(forName: AppTextSizeSettings.didChangeNotification,
            object: store, queue: .main) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        store.synchronizeSystemCategory(.extraExtraLarge)
        store.synchronizeSystemCategory(.extraExtraLarge)
        #expect(changes == 1)
        store.setFollowsSystem(false)
        let before = changes
        let configuration = store.configuration
        store.synchronizeSystemCategory(.accessibilityExtraExtraExtraLarge)
        #expect(changes == before)
        #expect(store.configuration == configuration)
        store.setFollowsSystem(true)
        #expect(store.configuration.category == .accessibilityExtraExtraExtraLarge)
    }

    @Test func regularTitleScalesWithSystemButManualSizeDoesNot() {
        let standard = AppTypography.Configuration(followsSystem: true, pointOffset: 8, category: .large)
        let large = AppTypography.Configuration(followsSystem: true, pointOffset: 8, category: .accessibilityExtraExtraExtraLarge)
        let title = standard.performAsCurrent { AppTypography.listTitleFont() }
        #expect(title.pointSize == 17)
        #expect(title.fontName == UIFont.systemFont(ofSize: 17, weight: .regular).fontName)
        #expect(!title.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(large.performAsCurrent { AppTypography.listTitleFont().pointSize } > title.pointSize)
        let manual = AppTypography.Configuration(followsSystem: false, pointOffset: 2, category: large.category)
        #expect(manual.performAsCurrent { AppTypography.listTitleFont().pointSize } == 19)
        #expect(manual.performAsCurrent { AppTypography.commentBodyFont().pointSize } == 19)
        #expect(large.performAsCurrent { AppTypography.listTitleFont(pointOffset: 2).pointSize } == 19)
    }

    @Test func backgroundTaskUsesCapturedConfigurationAndRestoresNestedScope() async {
        let captured = AppTypography.Configuration(followsSystem: false, pointOffset: 2, category: .large)
        let next = AppTypography.Configuration(followsSystem: false, pointOffset: 8, category: .large)
        let size: CGFloat = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                captured.performAsCurrent {
                    #expect(next.performAsCurrent { AppTypography.commentBodyFont().pointSize } == 25)
                    continuation.resume(returning: AppTypography.commentBodyFont().pointSize)
                }
            }
        }
        #expect(size == 19)
    }

    @Test func previewAndHTMLBodyUseSameSystemConfigurationAndPreserveEmphasis() throws {
        let configuration = AppTypography.Configuration(followsSystem: true, pointOffset: 0, category: .accessibilityExtraLarge)
        let preview = SettingsTextSizePreviewCell(style: .default, reuseIdentifier: nil)
        preview.configure(configuration: configuration)
        let blocks = configuration.performAsCurrent {
            DTCoreTextHTMLContentRenderer().render(fragment: "<p>普通文字 <strong>强调文字</strong></p>",
                baseURL: URL(string: "https://www.nodeseek.com")!, maxImageWidth: 320)
        }
        let text = try #require(blocks.compactMap { block -> NSAttributedString? in
            if case .text(let attributed) = block { return attributed }; return nil
        }.first)
        let normal = try #require(text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        let range = (text.string as NSString).range(of: "强调文字")
        let bold = try #require(text.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
        #expect(normal.pointSize == preview.debugCommentBodyFont?.pointSize)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.traitBold))
        #expect(preview.debugListTitleFont?.pointSize == configuration.performAsCurrent { AppTypography.listTitleFont().pointSize })
    }
}
