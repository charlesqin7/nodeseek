import Foundation
import Testing
@testable import nodeseek

@Suite(.serialized)
@MainActor
struct NodeSeekAuthorRankClientTests {
    @Test func loadsAuthorRankWithPostReferer() async throws {
        let client = makeClient(body: #"{"success":true,"detail":{"rank":1,"member_id":70925}}"#)
        let rank = try await client.loadRank(authorID: 70925, referer: NodeSeekSite.postURL(id: "975028", page: 1))
        #expect(rank == 1)
        #expect(AuthorRankURLProtocol.request?.url?.path == "/api/account/getInfo/70925")
        #expect(AuthorRankURLProtocol.request?.value(forHTTPHeaderField: "Referer") == "https://www.nodeseek.com/post-975028-1")
        #expect(AuthorRankURLProtocol.request?.value(forHTTPHeaderField: "Accept") == "application/json")
    }

    @Test(arguments: [
        #"{"success":true,"detail":{}}"#,
        #"{"success":true,"detail":{"rank":null}}"#
    ])
    func missingRankIsUnknown(body: String) async throws {
        let rank = try await makeClient(body: body).loadRank(authorID: 70925, referer: NodeSeekSite.baseURL)
        #expect(rank == nil)
    }

    @Test func rejectsUnsuccessfulResponse() async {
        do {
            _ = try await makeClient(body: #"{"success":false}"#)
                .loadRank(authorID: 70925, referer: NodeSeekSite.baseURL)
            Issue.record("接口失败应允许后续重试，不能当作成功的未知等级")
        } catch {}
    }

    @Test(arguments: [
        #"{"success":true,"detail":{"rank":"1"}}"#,
        #"{"success":true,"detail":{"rank":true}}"#,
        "<html>Cloudflare verification</html>"
    ])
    func malformedRankCannotBecomeLowLevel(body: String) async {
        do {
            _ = try await makeClient(body: body).loadRank(authorID: 70925, referer: NodeSeekSite.baseURL)
            Issue.record("无效等级不应被接受")
        } catch {}
    }

    @Test func rejectsHTTPFailure() async {
        do {
            _ = try await makeClient(body: #"{"success":true,"detail":{"rank":0}}"#, status: 403)
                .loadRank(authorID: 70925, referer: NodeSeekSite.baseURL)
            Issue.record("失败的 HTTP 状态不应返回等级")
        } catch {}
    }

    private func makeClient(body: String, status: Int = 200) -> NodeSeekAuthorRankClient {
        AuthorRankURLProtocol.body = Data(body.utf8)
        AuthorRankURLProtocol.status = status
        AuthorRankURLProtocol.request = nil
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthorRankURLProtocol.self]
        return NodeSeekAuthorRankClient(session: URLSession(configuration: configuration), cookieSession: nil)
    }
}

private final class AuthorRankURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = Data()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var request: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.request = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
