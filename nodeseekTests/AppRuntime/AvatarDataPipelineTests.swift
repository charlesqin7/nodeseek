import Foundation
import UIKit
import XCTest
@testable import nodeseek

@MainActor
final class AvatarDataPipelineTests: XCTestCase {
    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AvatarStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func bitmap() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }.pngData()!
    }

    func testRequestsCoalesceAndCancelledConsumerDoesNotCancelOtherConsumer() async throws {
        let url = URL(string: "https://avatar.test/\(UUID()).svg")!
        AvatarStubURLProtocol.setResponses([Data("<svg xmlns=\"http://www.w3.org/2000/svg\"/>".utf8)], for: url)
        let scheduler = AvatarRenderScheduler()
        var scrolling = true
        scheduler.isScrollingOverride = { scrolling }
        var renders = 0
        let imageData = bitmap()
        let pipeline = AvatarDataPipeline(session: session(), scheduler: scheduler, rasterize: { _, _ in
            XCTAssertTrue(Thread.isMainThread)
            renders += 1
            return imageData
        })
        let first = expectation(description: "第一个订阅取消")
        let second = expectation(description: "第二个订阅完成")
        let cancelledID = UUID()
        pipeline.load(id: cancelledID, key: url.absoluteString, url: url, pixelSize: CGSize(width: 56, height: 56),
                      visible: { true }) { result in
            if case .success = result { XCTFail("取消的请求不能成功") }
            first.fulfill()
        }
        pipeline.load(id: UUID(), key: url.absoluteString, url: url, pixelSize: CGSize(width: 56, height: 56),
                      visible: { true }) { result in
            XCTAssertEqual(try? result.get(), imageData)
            second.fulfill()
        }
        pipeline.cancel(id: cancelledID, key: url.absoluteString)
        await fulfillment(of: [first], timeout: 2)
        // 给网络响应入队机会；滚动期间绝不能调用 SVGKit。
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(renders, 0)
        scrolling = false
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(renders, 1)
        XCTAssertEqual(AvatarStubURLProtocol.requestCount(for: url), 1)
        let cached = expectation(description: "已处理位图直接复用")
        scrolling = true
        pipeline.load(id: UUID(), key: url.absoluteString, url: url, pixelSize: CGSize(width: 56, height: 56),
                      visible: { true }) { result in
            XCTAssertEqual(try? result.get(), imageData)
            cached.fulfill()
        }
        await fulfillment(of: [cached], timeout: 1)
        XCTAssertEqual(renders, 1)
    }

    func testCancellingLastConsumerPreventsRasterization() async throws {
        let url = URL(string: "https://avatar.test/\(UUID()).svg")!
        AvatarStubURLProtocol.setResponses([Data("<svg/>".utf8)], for: url)
        let scheduler = AvatarRenderScheduler()
        scheduler.isScrollingOverride = { true }
        var renders = 0
        let pipeline = AvatarDataPipeline(session: session(), scheduler: scheduler, rasterize: { _, _ in
            renders += 1
            return nil
        })
        let cancelled = expectation(description: "取消")
        let id = UUID()
        pipeline.load(id: id, key: url.absoluteString, url: url, pixelSize: CGSize(width: 56, height: 56),
                      visible: { true }) { result in
            if case .success = result { XCTFail("取消的请求不能成功") }
            cancelled.fulfill()
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        pipeline.cancel(id: id, key: url.absoluteString)
        scheduler.isScrollingOverride = { false }
        scheduler.drainOne()
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertEqual(renders, 0)
    }

    func testHTMLChallengeRetriesOnceAndLoadedImageSurvivesReentry() async {
        let url = URL(string: "https://avatar.test/\(UUID()).png")!
        AvatarStubURLProtocol.setResponses([Data("<!DOCTYPE html><html>challenge</html>".utf8), bitmap()], for: url)
        let cookies = AvatarCookieSessionSpy()
        let pipeline = AvatarDataPipeline(session: session())
        let loader = AvatarImageLoader(cookieSession: cookies, pipeline: pipeline)
        let imageView = UIImageView()
        let loaded = expectation(description: "同步 Cookie 后完成")
        loader.loadAvatar(into: imageView, postID: "test", avatarURL: url) { result in
            if case .failure = result { XCTFail("应在 Cookie 同步后成功") }
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: 3)
        XCTAssertEqual(cookies.syncCount, 1)
        XCTAssertEqual(AvatarStubURLProtocol.requestCount(for: url), 2)
        let image = imageView.image
        loader.cancel(on: imageView)
        loader.loadAvatar(into: imageView, postID: "test", avatarURL: url)
        XCTAssertTrue(imageView.image === image)
        XCTAssertEqual(AvatarStubURLProtocol.requestCount(for: url), 2)
    }
}

@MainActor
private final class AvatarCookieSessionSpy: NodeSeekCookieSessionManaging {
    var syncCount = 0
    func prepareWebViewLoad(userInterfaceStyle: UIUserInterfaceStyle?) async {}
    func captureWebViewSession() async {}
    func prepareHTTPLoad() async {}
    func prepareMediaRequest() async { syncCount += 1 }
    func clearLoginSession() async {}
}

private final class AvatarStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [URL: [Data]] = [:]
    nonisolated(unsafe) private static var counts: [URL: Int] = [:]

    static func setResponses(_ data: [Data], for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        responses[url] = data
        counts[url] = 0
    }

    static func requestCount(for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[url, default: 0]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        let count = Self.counts[url, default: 0]
        let values = Self.responses[url] ?? []
        Self.counts[url] = count + 1
        let data = values.isEmpty ? Data() : values[min(count, values.count - 1)]
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
