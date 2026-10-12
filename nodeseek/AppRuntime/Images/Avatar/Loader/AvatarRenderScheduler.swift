import UIKit

/// 只延后尚未开始的 SVG 工作。缓存图片和普通位图不受滚动状态影响。
@MainActor
final class AvatarRenderScheduler {
    static let shared = AvatarRenderScheduler()
    private let scrollViews = NSHashTable<UIScrollView>.weakObjects()
    private var jobs: [(id: UUID, visible: () -> Bool, work: () -> Void)] = []
    private var timer: Timer?
    var isScrollingOverride: (() -> Bool)?

    func track(_ scrollView: UIScrollView) {
        scrollViews.add(scrollView)
    }

    var isScrolling: Bool {
        isScrollingOverride?() ?? scrollViews.allObjects.contains {
            $0.window != nil && ($0.isTracking || $0.isDragging || $0.isDecelerating)
        }
    }

    func enqueue(id: UUID, visible: @escaping () -> Bool, work: @escaping () -> Void) {
        jobs.append((id, visible, work))
        scheduleNext()
    }

    func cancel(id: UUID) {
        jobs.removeAll { $0.id == id }
        if jobs.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func scheduleNext() {
        guard timer == nil, !jobs.isEmpty else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.drainOne() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func drainOne() {
        timer?.invalidate()
        timer = nil
        guard !jobs.isEmpty else { return }
        if !isScrolling {
            let index = jobs.firstIndex { $0.visible() } ?? jobs.startIndex
            let job = jobs.remove(at: index)
            ScrollPerformance.measure("AvatarSVGRasterize", job.work)
        }
        // 每个 run loop 周期最多执行一个，给触摸、布局与显示提交留出机会。
        scheduleNext()
    }
}
