import AsyncDisplayKit
import Testing
import UIKit
@testable import nodeseek

@Suite(.serialized)
@MainActor
struct ScrollRenderingPerformanceTests {
    @Test func repeatedMeasurementReusesLayoutAndInvalidatesForContentWidthAndTheme() {
        let view = DetailRichTextView(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        let text = NSAttributedString(string: String(repeating: "长回复测量 ", count: 60),
                                      attributes: [.font: UIFont.systemFont(ofSize: 17)])
        view.configure(text, onLayoutInvalidated: nil)
        let first = view.systemLayoutSizeFitting(CGSize(width: 320, height: 0))
        let count = view.measurementCount
        for _ in 0..<30 {
            #expect(view.systemLayoutSizeFitting(CGSize(width: 320, height: 0)) == first)
        }
        #expect(view.measurementCount == count)
        let narrow = view.systemLayoutSizeFitting(CGSize(width: 160, height: 0))
        #expect(narrow.height > first.height)
        #expect(view.measurementCount > count)
        view.configure(NSAttributedString(string: "短回复", attributes: [.font: UIFont.systemFont(ofSize: 17)]),
                       onLayoutInvalidated: nil)
        #expect(view.systemLayoutSizeFitting(CGSize(width: 160, height: 0)).height < narrow.height)
        let beforeTheme = view.measurementCount
        view.refreshAppearanceForCurrentTraits()
        _ = view.systemLayoutSizeFitting(CGSize(width: 160, height: 0))
        #expect(view.measurementCount > beforeTheme)
    }

    @Test func svgSchedulerDefersDuringDragAndDrainsVisibleWorkFirst() {
        let scheduler = AvatarRenderScheduler()
        var scrolling = true
        scheduler.isScrollingOverride = { scrolling }
        var completed: [Int] = []
        let cancelledID = UUID()
        scheduler.enqueue(id: UUID(), visible: { false }) { completed.append(1) }
        scheduler.enqueue(id: UUID(), visible: { true }) { completed.append(2) }
        scheduler.enqueue(id: cancelledID, visible: { true }) { completed.append(3) }
        scheduler.cancel(id: cancelledID)
        scheduler.drainOne()
        #expect(completed.isEmpty)
        scrolling = false
        scheduler.drainOne()
        #expect(completed == [2])
        scheduler.drainOne()
        #expect(completed == [2, 1])
    }

    @Test func matchingInitialThemeIsNotAppliedAgain() {
        let node = ThemeProbeNode()
        // 与实际 view 的 trait 完全一致，模拟 nodeBlock 捕获的主题。
        let observer = ThemeTraitObserver()
        node.view.traitCollection.performAsCurrent { observer.recordAppliedTheme() }
        observer.install(on: node)
        #expect(node.applyCount == 0)
        node.refreshAppearanceForCurrentTraits()
        #expect(node.applyCount == 1)
    }
}

private final class ThemeProbeNode: ASDisplayNode, ThemeRefreshableNode {
    var applyCount = 0
    func applyCurrentTheme() { applyCount += 1 }
}
