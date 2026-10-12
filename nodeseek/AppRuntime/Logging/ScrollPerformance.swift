import Foundation
import os.signpost

/// Instruments 的 Points of Interest；不记录帖子内容或图片地址。
enum ScrollPerformance {
    nonisolated private static let log = OSLog(subsystem: "com.nodeseek.app", category: .pointsOfInterest)

    nonisolated static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        defer { os_signpost(.end, log: log, name: name, signpostID: id) }
        return try work()
    }
}
