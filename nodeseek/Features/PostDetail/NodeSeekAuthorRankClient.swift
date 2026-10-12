import Foundation

@MainActor
protocol PostAuthorRankLoading {
    func loadRank(authorID: Int, referer: URL) async throws -> Int?
}

@MainActor
final class NodeSeekAuthorRankClient: PostAuthorRankLoading {
    private let session: URLSession
    private let baseURL: URL
    private let cookieSession: NodeSeekCookieSessionManaging?

    convenience init() {
        self.init(session: .shared, cookieSession: NodeSeekCookieSession())
    }

    init(
        session: URLSession,
        baseURL: URL = NodeSeekSite.baseURL,
        cookieSession: NodeSeekCookieSessionManaging? = nil
    ) {
        self.session = session
        self.baseURL = baseURL
        self.cookieSession = cookieSession
    }

    func loadRank(authorID: Int, referer: URL) async throws -> Int? {
        await cookieSession?.prepareHTTPLoad()
        let url = baseURL.appendingPathComponent("api/account/getInfo/\(authorID)")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        WebRequestFingerprint.applyJSONHeaders(to: &request, referer: referer)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let result = try JSONDecoder().decode(RankResponse.self, from: data)
        guard result.success else {
            throw NodeSeekAuthorRankClientError.unsuccessfulResponse
        }
        return result.detail?.rank
    }

    private struct RankResponse: Decodable {
        let success: Bool
        let detail: Detail?

        struct Detail: Decodable {
            let rank: Int?
        }
    }
}

enum NodeSeekAuthorRankClientError: LocalizedError {
    case unsuccessfulResponse

    var errorDescription: String? { "楼主等级接口返回失败" }
}
