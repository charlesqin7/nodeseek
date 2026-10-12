import AsyncDisplayKit
import UIKit

final class AuthorStatusBadgeNode: ASButtonNode, ThemeRefreshableNode {
    private let text: String

    init(text: String) {
        self.text = text
        super.init()
        contentEdgeInsets = UIEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)
        cornerRadius = 4
        borderWidth = 1
        isUserInteractionEnabled = false
        accessibilityLabel = text
        applyCurrentTheme()
    }

    func applyCurrentTheme() {
        let isMuted = text.contains("禁言") || text.contains("封禁")
        let color: UIColor = isMuted ? .systemRed : .label
        setAttributedTitle(NSAttributedString(
            string: text,
            attributes: [
                .font: AppTypography.commentBadgeFont(),
                .foregroundColor: color
            ]
        ), for: .normal)
        borderColor = (isMuted ? UIColor.systemRed : UIColor.separator).cgColor
    }
}
