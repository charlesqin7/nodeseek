//
//  AppTextSizeSettings.swift
//  nodeseek
//
//  Created by Codex on 2026/5/10.
//

import Foundation
import UIKit

final class AppTextSizeSettings {
    static let didChangeNotification = Notification.Name("AppTextSizeSettings.didChange")
    static let shared = AppTextSizeSettings(contentSizeCategory: UIApplication.shared.preferredContentSizeCategory)

    static let minimumPointOffset: CGFloat = -4
    static let maximumPointOffset: CGFloat = 8
    static let defaultPointOffset: CGFloat = 0

    private let userDefaults: UserDefaults
    private let storageKey: String
    private var observers: [NSObjectProtocol] = []
    private let categoryLock = NSLock()
    private var systemCategory: UIContentSizeCategory

    private var modeKey: String { storageKey + ".followsSystem" }

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = "appTextSizePointOffset",
        contentSizeCategory: UIContentSizeCategory = UITraitCollection.current.preferredContentSizeCategory,
        observeSystemChanges: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.systemCategory = contentSizeCategory == .unspecified ? .large : contentSizeCategory
        if userDefaults.object(forKey: modeKey) == nil {
            userDefaults.set(userDefaults.object(forKey: storageKey) == nil, forKey: modeKey)
        }
        if observeSystemChanges {
            observers.append(NotificationCenter.default.addObserver(
                forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let category = notification.userInfo?[UIContentSizeCategory.newValueUserInfoKey] as? UIContentSizeCategory
                    ?? UIApplication.shared.preferredContentSizeCategory
                self?.synchronizeSystemCategory(category)
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.synchronizeSystemCategory(UIApplication.shared.preferredContentSizeCategory)
            })
        }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    var followsSystem: Bool { userDefaults.bool(forKey: modeKey) }

    var configuration: AppTypography.Configuration {
        categoryLock.lock()
        let category = systemCategory
        categoryLock.unlock()
        return AppTypography.Configuration(followsSystem: followsSystem, pointOffset: pointOffset, category: followsSystem ? category : .large)
    }

    func setFollowsSystem(_ enabled: Bool) {
        guard followsSystem != enabled else { return }
        userDefaults.set(enabled, forKey: modeKey)
        notifyChange()
    }

    func synchronizeSystemCategory(_ category: UIContentSizeCategory) {
        let normalized = category == .unspecified ? UIContentSizeCategory.large : category
        categoryLock.lock()
        let changed = systemCategory != normalized
        systemCategory = normalized
        categoryLock.unlock()
        if changed && followsSystem { notifyChange() }
    }

    var pointOffset: CGFloat {
        guard userDefaults.object(forKey: storageKey) != nil else {
            return Self.defaultPointOffset
        }
        return Self.normalizedPointOffset(CGFloat(userDefaults.double(forKey: storageKey)))
    }

    var displayText: String {
        followsSystem ? "跟随系统" : Self.displayText(for: pointOffset)
    }

    func setPointOffset(_ rawValue: CGFloat) {
        let nextValue = Self.normalizedPointOffset(rawValue)
        guard nextValue != pointOffset || userDefaults.object(forKey: storageKey) == nil else { return }
        userDefaults.set(Double(nextValue), forKey: storageKey)
        if !followsSystem { notifyChange() }
    }

    private func notifyChange() {
        let postNotification = {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        if Thread.isMainThread {
            postNotification()
        } else {
            DispatchQueue.main.async(execute: postNotification)
        }
    }

    func reset() {
        setPointOffset(Self.defaultPointOffset)
    }

    static func normalizedPointOffset(_ rawValue: CGFloat) -> CGFloat {
        min(max(rawValue.rounded(), minimumPointOffset), maximumPointOffset)
    }

    static func adjustedPointSize(basePointSize: CGFloat, pointOffset: CGFloat = shared.pointOffset) -> CGFloat {
        max(8, basePointSize + normalizedPointOffset(pointOffset))
    }

    static func displayText(for pointOffset: CGFloat) -> String {
        let normalized = normalizedPointOffset(pointOffset)
        if normalized == 0 {
            return "标准"
        }
        return normalized > 0 ? "+\(Int(normalized))" : "\(Int(normalized))"
    }
}

enum AppTypography {
    /// 每个后台构建任务使用提交时捕获的字号；嵌套调用结束后恢复线程原配置。
    struct Configuration: Equatable {
        let followsSystem: Bool
        let pointOffset: CGFloat
        let category: UIContentSizeCategory

        func performAsCurrent<T>(_ work: () throws -> T) rethrows -> T {
            let dictionary = Thread.current.threadDictionary
            let previous = dictionary[AppTypography.configurationKey]
            dictionary[AppTypography.configurationKey] = self
            defer {
                if let previous { dictionary[AppTypography.configurationKey] = previous }
                else { dictionary.removeObject(forKey: AppTypography.configurationKey) }
            }
            return try work()
        }
    }

    private static let configurationKey = "nodeseek.typography.configuration"
    static var currentConfiguration: Configuration {
        Thread.current.threadDictionary[configurationKey] as? Configuration ?? AppTextSizeSettings.shared.configuration
    }

    static func font(
        basePointSize: CGFloat,
        weight: UIFont.Weight = .regular,
        pointOffset: CGFloat? = nil,
        textStyle: UIFont.TextStyle = .body
    ) -> UIFont {
        resolvedFont(basePointSize: basePointSize, weight: weight, pointOffset: pointOffset, textStyle: textStyle, monospaced: false)
    }

    static func monospacedFont(
        basePointSize: CGFloat,
        weight: UIFont.Weight = .regular,
        pointOffset: CGFloat? = nil
    ) -> UIFont {
        resolvedFont(basePointSize: basePointSize, weight: weight, pointOffset: pointOffset, textStyle: .body, monospaced: true)
    }

    private static func resolvedFont(basePointSize: CGFloat, weight: UIFont.Weight, pointOffset: CGFloat?,
                                     textStyle: UIFont.TextStyle, monospaced: Bool) -> UIFont {
        let configuration = currentConfiguration
        let followsSystem = pointOffset == nil && configuration.followsSystem
        let size = followsSystem ? basePointSize : AppTextSizeSettings.adjustedPointSize(
            basePointSize: basePointSize, pointOffset: pointOffset ?? configuration.pointOffset
        )
        let font = monospaced ? UIFont.monospacedSystemFont(ofSize: size, weight: weight)
            : UIFont.systemFont(ofSize: size, weight: weight)
        guard followsSystem else { return font }
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(
            for: font, compatibleWith: UITraitCollection(preferredContentSizeCategory: configuration.category)
        )
    }

    static func listTitleFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 17, weight: .regular, pointOffset: pointOffset)
    }

    static func listMetadataFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 13, weight: .regular, pointOffset: pointOffset, textStyle: .caption1)
    }

    static func commentAuthorFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 17, weight: .semibold, pointOffset: pointOffset)
    }

    static func commentBodyFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 17, weight: .regular, pointOffset: pointOffset)
    }

    static func commentMetadataFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 15, weight: .regular, pointOffset: pointOffset, textStyle: .subheadline)
    }

    static func commentBadgeFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 11, weight: .regular, pointOffset: pointOffset, textStyle: .caption2)
    }

    static func commentActionFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 12, weight: .regular, pointOffset: pointOffset, textStyle: .caption1)
    }

    static func signatureFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 11, weight: .regular, pointOffset: pointOffset, textStyle: .caption2)
    }

    static func detailTitleFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 22, weight: .regular, pointOffset: pointOffset, textStyle: .title2)
    }

    static func detailMetadataFont(pointOffset: CGFloat? = nil) -> UIFont {
        font(basePointSize: 15, weight: .regular, pointOffset: pointOffset, textStyle: .subheadline)
    }
}
