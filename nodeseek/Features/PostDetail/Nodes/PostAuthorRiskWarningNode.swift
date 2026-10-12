import AsyncDisplayKit
import UIKit

final class PostAuthorRiskWarningNode: ASDisplayNode, ThemeRefreshableNode {
    static let message = "『温馨提醒』检测到楼主用户等级在lv1以下，交易需要通过中介，禁止发起拼车"

    private let textNode = ASTextNode()
    private let iconNode = ASImageNode()
    private let themeTraitObserver = ThemeTraitObserver()

    override init() {
        super.init()
        automaticallyManagesSubnodes = true
        cornerRadius = 12
        clipsToBounds = true
        textNode.maximumNumberOfLines = 0
        textNode.style.flexShrink = 1
        textNode.style.flexGrow = 1
        iconNode.style.preferredSize = CGSize(width: 20, height: 20)
        iconNode.isAccessibilityElement = false
        applyCurrentTheme()
    }

    override func didLoad() {
        super.didLoad()
        layer.cornerCurve = .continuous
        themeTraitObserver.install(on: self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentSizeCategoryDidChange),
            name: UIContentSizeCategory.didChangeNotification,
            object: nil
        )
    }

    func applyCurrentTheme() {
        backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
        configureText()
        iconNode.image = UIImage(systemName: "exclamationmark.shield.fill")?
            .withTintColor(.systemOrange, renderingMode: .alwaysOriginal)
        iconNode.setNeedsDisplay()
        setNeedsLayout()
    }

    private func configureText() {
        textNode.attributedText = NSAttributedString(
            string: Self.message,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .subheadline),
                .foregroundColor: UIColor.label
            ]
        )
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let row = ASStackLayoutSpec.horizontal()
        row.alignItems = .start
        row.spacing = 8
        row.children = [
            ASInsetLayoutSpec(insets: UIEdgeInsets(top: 2, left: 0, bottom: 0, right: 0), child: iconNode),
            textNode
        ]
        return ASInsetLayoutSpec(insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12), child: row)
    }

    @objc private func contentSizeCategoryDidChange() {
        configureText()
        // 字号变化只更新文字，并显式重绘 Texture 缓存的图标。
        iconNode.setNeedsDisplay()
        setNeedsLayout()
    }
}
