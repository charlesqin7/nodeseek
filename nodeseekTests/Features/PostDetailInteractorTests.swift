//
//  PostDetailInteractorTests.swift
//  nodeseekTests
//
//  Created by Codex on 2026/4/27.
//

import Foundation
import Testing
@testable import nodeseek

@MainActor
struct PostDetailInteractorTests {
    @Test(arguments: [0, 1, 2])
    func loadsLowLevelWarningAfterBodyAndOnlyOncePerAuthor(rank: Int) async throws {
        let loader = StubPostAuthorRankLoader(rank: rank, waitsForCompletion: true)
        let (interactor, presenter) = Self.makeWarningInteractor(category: "carpool", loader: loader)
        interactor.loadPostDetail()
        for _ in 0..<100 {
            if presenter.loadedResponse != nil, loader.requestedAuthorIDs.isEmpty == false { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(presenter.loadedResponse != nil)
        #expect(presenter.authorRiskWarningEvents.isEmpty)
        loader.completeRankLookup()
        await waitForInteractorCallbacks()
        #expect(presenter.authorRiskWarningEvents.last?.isVisible == (rank <= 1))
        #expect(loader.requestedAuthorIDs == [70925])
        interactor.loadPostDetail(page: 2)
        await waitForInteractorCallbacks()
        #expect(loader.requestedAuthorIDs == [70925])
    }

    @Test func ordinaryPostDoesNotQueryRank() async {
        let loader = StubPostAuthorRankLoader(rank: 0)
        let (interactor, presenter) = Self.makeWarningInteractor(category: "daily", loader: loader)
        interactor.loadPostDetail()
        await waitForInteractorCallbacks()
        #expect(presenter.loadedResponse != nil)
        #expect(loader.requestedAuthorIDs.isEmpty)
        #expect(presenter.authorRiskWarningEvents.isEmpty)
    }

    @Test func unknownRankCanBeRetriedOnNextDetailLoad() async {
        let loader = StubPostAuthorRankLoader(rank: nil)
        let (interactor, presenter) = Self.makeWarningInteractor(category: "trade", loader: loader)
        interactor.loadPostDetail()
        await waitForInteractorCallbacks()
        #expect(presenter.authorRiskWarningEvents.last?.isVisible == false)

        interactor.loadPostDetail(page: 2)
        await waitForInteractorCallbacks()
        #expect(loader.requestedAuthorIDs == [70925, 70925])
        #expect(presenter.errorMessage == nil)
    }

    @Test func failedRankLookupDoesNotFailDetailLoad() async throws {
        let loader = StubPostAuthorRankLoader(rank: nil, fails: true)
        let (interactor, presenter) = Self.makeWarningInteractor(category: "trade", loader: loader)
        interactor.loadPostDetail()
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(presenter.loadedResponse != nil)
        #expect(presenter.errorMessage == nil)
        #expect(presenter.authorRiskWarningEvents.isEmpty)
    }

    private static func makeWarningInteractor(category: String, loader: PostAuthorRankLoading) -> (PostDetailInteractor, SpyPostDetailInteractorOutput) {
        let config = "{\"postData\":{\"category\":\"\(category)\",\"op\":{\"uid\":70925}}}"
        let html = "<div class='post-title'><h1>测试帖子</h1></div><script id='nodeseek-captured-config'>\(config)</script>"
        let post = makePost()
        let service = NodeSeekService(htmlClient: URLCapturingHTMLClient(response: HTMLResponse(
            statusCode: 200, headers: [:], finalURL: post.url, html: html
        )), currentAccountStore: nil)
        let presenter = SpyPostDetailInteractorOutput()
        let interactor = PostDetailInteractor(post: post, service: service, authorRankLoader: loader, sessionStore: NodeSeekSessionStore())
        interactor.presenter = presenter
        return (interactor, presenter)
    }

    @Test func stopsAfterFirstChallengeAndUpdatesSharedSessionState() async throws {
        let html = try FixtureLoader.html(named: "cloudflare-challenge")
        let url = URL(string: "https://www.nodeseek.com/")!
        let htmlClient = URLCapturingHTMLClient(response: HTMLResponse(
            statusCode: 403,
            headers: [:],
            finalURL: url,
            html: html
        ))
        let service = NodeSeekService(
            baseURL: url,
            htmlClient: htmlClient,
            parser: KannaNodeSeekParser(baseURL: url)
        )
        let sessionStore = NodeSeekSessionStore()
        let presenter = SpyPostDetailInteractorOutput()
        let post = PostSummary(
            id: "703863",
            title: "标题",
            url: URL(string: "https://www.nodeseek.com/post-703863-1")!,
            authorName: "mist",
            nodeName: "日常",
            replyCount: 0,
            lastActivityText: "刚刚"
        )
        let interactor = PostDetailInteractor(
            post: post,
            service: service,
            sessionStore: sessionStore
        )
        interactor.presenter = presenter

        interactor.loadPostDetail()
        await waitForInteractorCallbacks()

        let requestedURLs = await htmlClient.requestedURLs()
        let state = await sessionStore.currentState()

        #expect(requestedURLs.count == 1)
        #expect(presenter.loadedResponse == nil)
        #expect(presenter.errorMessage == "站点当前需要 Cloudflare 验证，请稍后重试。")
        guard case .challengeRequired(.cloudflare, _) = state else {
            Issue.record("详情命中 challenge 后应写入统一 session 状态")
            return
        }
    }

    @Test func reportsLoginRequiredInlineInsteadOfFailingDetailLoad() async throws {
        let html = try FixtureLoader.html(named: "post-login-required")
        let url = URL(string: "https://www.nodeseek.com/")!
        let htmlClient = URLCapturingHTMLClient(response: HTMLResponse(
            statusCode: 404,
            headers: [:],
            finalURL: URL(string: "https://www.nodeseek.com/post-704286-1")!,
            html: html
        ))
        let service = NodeSeekService(
            baseURL: url,
            htmlClient: htmlClient,
            parser: KannaNodeSeekParser(baseURL: url)
        )
        let sessionStore = NodeSeekSessionStore()
        let presenter = SpyPostDetailInteractorOutput()
        let post = PostSummary(
            id: "704286",
            title: "受限帖子",
            url: URL(string: "https://www.nodeseek.com/post-704286-1")!,
            authorName: "mist",
            nodeName: "日常",
            replyCount: 0,
            lastActivityText: "刚刚"
        )
        let interactor = PostDetailInteractor(
            post: post,
            service: service,
            sessionStore: sessionStore
        )
        interactor.presenter = presenter

        interactor.loadPostDetail()
        await waitForInteractorCallbacks()

        #expect(presenter.loadedResponse == nil)
        #expect(presenter.errorMessage == nil)
        #expect(presenter.loginRequiredMessage == "本帖需要注册用户才能查看😭")
    }

    @Test func loadPostDetailPreheatsOnlyFirstSuccessfulPage() async throws {
        let baseURL = URL(string: "https://www.nodeseek.com/")!
        let post = Self.makePost()
        let htmlClient = URLCapturingHTMLClient(response: HTMLResponse(
            statusCode: 200,
            headers: [:],
            finalURL: post.url,
            html: try FixtureLoader.html(named: "post-703863-1")
        ))
        let service = NodeSeekService(
            baseURL: baseURL,
            htmlClient: htmlClient,
            parser: KannaNodeSeekParser(baseURL: baseURL)
        )
        let actionPagePreparer = SpyPostDetailActionPagePreparer()
        let presenter = SpyPostDetailInteractorOutput()
        let interactor = PostDetailInteractor(
            post: post,
            service: service,
            actionPagePreparer: actionPagePreparer,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.loadPostDetail()
        await waitForInteractorCallbacks()

        #expect(presenter.loadedResponse?.detail.id == post.id)
        #expect(actionPagePreparer.preparedURLs == [post.url])

        interactor.loadPostDetail(page: 2)
        await waitForInteractorCallbacks()

        #expect(actionPagePreparer.preparedURLs == [post.url])
    }

    @Test func commentActionsUseFirstPostPageAfterLoadingNonFirstPage() async throws {
        let baseURL = URL(string: "https://www.nodeseek.com/")!
        let post = Self.makePost(url: URL(string: "https://www.nodeseek.com/post-703863-9")!)
        let pageURL = URL(string: "https://www.nodeseek.com/post-703863-4")!
        let htmlClient = URLCapturingHTMLClient(response: HTMLResponse(
            statusCode: 200,
            headers: [:],
            finalURL: pageURL,
            html: try FixtureLoader.html(named: "post-703863-1")
        ))
        let service = NodeSeekService(
            baseURL: baseURL,
            htmlClient: htmlClient,
            parser: KannaNodeSeekParser(baseURL: baseURL)
        )
        let actionPagePreparer = SpyPostDetailActionPagePreparer()
        let upvoteSubmitter = SpyCommentUpvoteSubmitting(response: CommentUpvoteResponse(message: "added", current: 1))
        let presenter = SpyPostDetailInteractorOutput()
        let interactor = PostDetailInteractor(
            post: post,
            service: service,
            commentUpvoteSubmitter: upvoteSubmitter,
            actionPagePreparer: actionPagePreparer,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.loadPostDetail(page: 4)
        await waitForInteractorCallbacks()
        interactor.addCommentLike(commentID: "9835758")
        await waitForInteractorCallbacks()

        #expect(actionPagePreparer.preparedURLs == [pageURL])
        #expect(upvoteSubmitter.submittedReferer?.absoluteString == "https://www.nodeseek.com/post-703863-1")
    }

    @Test func submitReplyUsesCommentSubmitterAndReportsSuccess() async throws {
        let automation = SpyCommentSubmissionAutomation(response: CommentAutomationResponse(
            ok: true,
            statusCode: 200,
            message: "已发布",
            reason: "submitted"
        ))
        let presenter = SpyPostDetailInteractorOutput()
        let post = Self.makePost()
        let interactor = PostDetailInteractor(
            post: post,
            service: Self.makeUnusedService(),
            commentSubmitter: NodeSeekCommentSubmitter(automation: automation),
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.submitReply(content: "  测试评论  ")
        await waitForInteractorCallbacks()

        #expect(automation.submittedPostID == 703863)
        #expect(automation.submittedContent == "测试评论")
        #expect(automation.submittedReferer == post.url)
        #expect(presenter.didSubmitReplyCount == 1)
        #expect(presenter.submitReplyResponse == PostDetailSubmitReplyResponse(message: "已发布"))
        #expect(presenter.submitReplyErrorMessage == nil)
    }

    @Test func submitReplyReportsMissingPost() async throws {
        let presenter = SpyPostDetailInteractorOutput()
        let interactor = PostDetailInteractor(
            post: nil,
            service: Self.makeUnusedService(),
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.submitReply(content: "测试评论")

        #expect(presenter.didSubmitReplyCount == 0)
        #expect(presenter.submitReplyErrorMessage == "缺少帖子信息，无法发表评论。")
    }

    @Test func submitReplyReportsSubmitterFailureMessage() async throws {
        let automation = SpyCommentSubmissionAutomation(response: CommentAutomationResponse(
            ok: false,
            statusCode: 400,
            message: "评论内容太短",
            reason: "server_error"
        ))
        let presenter = SpyPostDetailInteractorOutput()
        let interactor = PostDetailInteractor(
            post: Self.makePost(),
            service: Self.makeUnusedService(),
            commentSubmitter: NodeSeekCommentSubmitter(automation: automation),
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.submitReply(content: "短")
        await waitForInteractorCallbacks()

        #expect(presenter.didSubmitReplyCount == 0)
        #expect(presenter.submitReplyErrorMessage == "评论内容太短")
    }

    @Test func addFavoriteUsesCollectionSubmitterAndReportsSuccess() async throws {
        let collectionSubmitter = SpyPostCollectionSubmitting(response: PostCollectionResponse(message: "已收藏"))
        let presenter = SpyPostDetailInteractorOutput()
        let post = Self.makePost()
        let interactor = PostDetailInteractor(
            post: post,
            service: Self.makeUnusedService(),
            collectionSubmitter: collectionSubmitter,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addFavorite()
        await waitForInteractorCallbacks()

        #expect(collectionSubmitter.submittedPostID == post.id)
        #expect(collectionSubmitter.submittedReferer == post.url)
        #expect(presenter.addFavoriteResponse == PostCollectionResponse(message: "已收藏"))
        #expect(presenter.addFavoriteErrorMessage == nil)
    }

    @Test func removeFavoriteUsesCollectionSubmitterAndReportsSuccess() async throws {
        let collectionSubmitter = SpyPostCollectionSubmitting(response: PostCollectionResponse(message: "已取消收藏"))
        let presenter = SpyPostDetailInteractorOutput()
        let post = Self.makePost()
        let interactor = PostDetailInteractor(
            post: post,
            service: Self.makeUnusedService(),
            collectionSubmitter: collectionSubmitter,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.removeFavorite()
        await waitForInteractorCallbacks()

        #expect(collectionSubmitter.removedPostID == post.id)
        #expect(collectionSubmitter.removedReferer == post.url)
        #expect(presenter.removeFavoriteResponse == PostCollectionResponse(message: "已取消收藏"))
        #expect(presenter.removeFavoriteErrorMessage == nil)
    }

    @Test func removeFavoriteReportsMissingPost() {
        let presenter = SpyPostDetailInteractorOutput()
        let interactor = PostDetailInteractor(
            post: nil,
            service: Self.makeUnusedService(),
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.removeFavorite()

        #expect(presenter.removeFavoriteResponse == nil)
        #expect(presenter.removeFavoriteErrorMessage == "缺少帖子信息，无法收藏。")
    }

    @Test func addFavoriteReportsMissingPost() {
        let presenter = SpyPostDetailInteractorOutput()
        let interactor = PostDetailInteractor(
            post: nil,
            service: Self.makeUnusedService(),
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addFavorite()

        #expect(presenter.addFavoriteResponse == nil)
        #expect(presenter.addFavoriteErrorMessage == "缺少帖子信息，无法收藏。")
    }

    @Test func addCommentLikeUsesUpvoteSubmitterAndReportsSuccess() async throws {
        let upvoteSubmitter = SpyCommentUpvoteSubmitting(response: CommentUpvoteResponse(message: "added", current: 1))
        let presenter = SpyPostDetailInteractorOutput()
        let post = Self.makePost()
        let interactor = PostDetailInteractor(
            post: post,
            service: Self.makeUnusedService(),
            commentUpvoteSubmitter: upvoteSubmitter,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addCommentLike(commentID: "9835758")
        await waitForInteractorCallbacks()

        #expect(upvoteSubmitter.submittedCommentID == "9835758")
        #expect(upvoteSubmitter.submittedReferer == post.url)
        #expect(presenter.commentLikeResponse == CommentUpvoteResponse(message: "added", current: 1))
        #expect(presenter.commentLikeErrorMessage == nil)
    }

    @Test func addCommentLikeReportsMissingPost() {
        let presenter = SpyPostDetailInteractorOutput()
        let interactor = PostDetailInteractor(
            post: nil,
            service: Self.makeUnusedService(),
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addCommentLike(commentID: "9835758")

        #expect(presenter.commentLikeResponse == nil)
        #expect(presenter.commentLikeErrorMessage == "缺少帖子信息，无法点赞。")
    }

    @Test func addPostLikeUsesUpvoteSubmitterAndReportsSuccess() async throws {
        let upvoteSubmitter = SpyPostUpvoteSubmitting(response: PostUpvoteResponse(message: "added", current: 1))
        let presenter = SpyPostDetailInteractorOutput()
        let post = Self.makePost()
        let interactor = PostDetailInteractor(
            post: post,
            service: Self.makeUnusedService(),
            postUpvoteSubmitter: upvoteSubmitter,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addPostLike()
        await waitForInteractorCallbacks()

        #expect(upvoteSubmitter.submittedPostID == post.id)
        #expect(upvoteSubmitter.submittedReferer == post.url)
        #expect(presenter.postLikeResponse == PostUpvoteResponse(message: "added", current: 1))
        #expect(presenter.postLikeErrorMessage == nil)
    }

    @Test func addPostLikeReportsMissingPost() {
        let presenter = SpyPostDetailInteractorOutput()
        let interactor = PostDetailInteractor(
            post: nil,
            service: Self.makeUnusedService(),
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addPostLike()

        #expect(presenter.postLikeResponse == nil)
        #expect(presenter.postLikeErrorMessage == "缺少帖子信息，无法点赞。")
    }

    @Test func addCommentChickenLegUsesSubmitterAndReportsSuccess() async throws {
        let submitter = SpyCommentChickenLegSubmitting(response: CommentChickenLegResponse(message: "added", current: 2))
        let presenter = SpyPostDetailInteractorOutput()
        let post = Self.makePost()
        let interactor = PostDetailInteractor(
            post: post,
            service: Self.makeUnusedService(),
            commentChickenLegSubmitter: submitter,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addCommentChickenLeg(commentID: "9835758")
        await waitForInteractorCallbacks()

        #expect(submitter.submittedCommentID == "9835758")
        #expect(submitter.submittedReferer == post.url)
        #expect(presenter.commentChickenLegResponse == CommentChickenLegResponse(message: "added", current: 2))
        #expect(presenter.commentChickenLegErrorMessage == nil)
    }

    @Test func addPostChickenLegUsesSubmitterAndReportsSuccess() async throws {
        let submitter = SpyPostChickenLegSubmitting(response: PostChickenLegResponse(message: "added", current: 3))
        let presenter = SpyPostDetailInteractorOutput()
        let post = Self.makePost()
        let interactor = PostDetailInteractor(
            post: post,
            service: Self.makeUnusedService(),
            postChickenLegSubmitter: submitter,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addPostChickenLeg()
        await waitForInteractorCallbacks()

        #expect(submitter.submittedPostID == post.id)
        #expect(submitter.submittedReferer == post.url)
        #expect(presenter.postChickenLegResponse == PostChickenLegResponse(message: "added", current: 3))
        #expect(presenter.postChickenLegErrorMessage == nil)
    }

    @Test func addCommentOpposeUsesDislikeSubmitterAndReportsSuccess() async throws {
        let dislikeSubmitter = SpyCommentDislikeSubmitting(response: CommentDislikeResponse(message: "added", current: 1))
        let presenter = SpyPostDetailInteractorOutput()
        let post = Self.makePost()
        let interactor = PostDetailInteractor(
            post: post,
            service: Self.makeUnusedService(),
            commentDislikeSubmitter: dislikeSubmitter,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addCommentOppose(commentID: "9835758")
        await waitForInteractorCallbacks()

        #expect(dislikeSubmitter.submittedCommentID == "9835758")
        #expect(dislikeSubmitter.submittedReferer == post.url)
        #expect(presenter.commentOpposeResponse == CommentDislikeResponse(message: "added", current: 1))
        #expect(presenter.commentOpposeErrorMessage == nil)
    }

    @Test func addPostOpposeUsesDislikeSubmitterAndReportsSuccess() async throws {
        let dislikeSubmitter = SpyPostDislikeSubmitting(response: PostDislikeResponse(message: "added", current: 1))
        let presenter = SpyPostDetailInteractorOutput()
        let post = Self.makePost()
        let interactor = PostDetailInteractor(
            post: post,
            service: Self.makeUnusedService(),
            postDislikeSubmitter: dislikeSubmitter,
            sessionStore: NodeSeekSessionStore()
        )
        interactor.presenter = presenter

        interactor.addPostOppose()
        await waitForInteractorCallbacks()

        #expect(dislikeSubmitter.submittedPostID == post.id)
        #expect(dislikeSubmitter.submittedReferer == post.url)
        #expect(presenter.postOpposeResponse == PostDislikeResponse(message: "added", current: 1))
        #expect(presenter.postOpposeErrorMessage == nil)
    }

    private static func makePost(url: URL = URL(string: "https://www.nodeseek.com/post-703863-1")!) -> PostSummary {
        PostSummary(
            id: "703863",
            title: "标题",
            url: url,
            authorName: "mist",
            nodeName: "日常",
            replyCount: 0,
            lastActivityText: "刚刚"
        )
    }

    private static func makeUnusedService() -> NodeSeekService {
        let url = URL(string: "https://www.nodeseek.com/")!
        return NodeSeekService(
            baseURL: url,
            htmlClient: URLCapturingHTMLClient(response: HTMLResponse(
                statusCode: 200,
                headers: [:],
                finalURL: url,
                html: ""
            )),
            parser: KannaNodeSeekParser(baseURL: url)
        )
    }
}

@MainActor
private final class SpyPostDetailInteractorOutput: PostDetailInteractorOutput {
    var loadedResponse: PostDetailResponse?
    var authorRiskWarningEvents: [(postID: String, isVisible: Bool)] = []
    var loginRequiredMessage: String?
    var errorMessage: String?
    var didSubmitReplyCount = 0
    var submitReplyResponse: PostDetailSubmitReplyResponse?
    var submitReplyErrorMessage: String?
    var addFavoriteResponse: PostCollectionResponse?
    var addFavoriteErrorMessage: String?
    var removeFavoriteResponse: PostCollectionResponse?
    var removeFavoriteErrorMessage: String?
    var postLikeResponse: PostUpvoteResponse?
    var postLikeErrorMessage: String?
    var commentLikeResponse: CommentUpvoteResponse?
    var commentLikeErrorMessage: String?
    var postChickenLegResponse: PostChickenLegResponse?
    var postChickenLegErrorMessage: String?
    var commentChickenLegResponse: CommentChickenLegResponse?
    var commentChickenLegErrorMessage: String?
    var postOpposeResponse: PostDislikeResponse?
    var postOpposeErrorMessage: String?
    var commentOpposeResponse: CommentDislikeResponse?
    var commentOpposeErrorMessage: String?

    func didLoadAuthorRiskWarning(postID: String, isVisible: Bool) {
        authorRiskWarningEvents.append((postID, isVisible))
    }

    func didLoadPostDetail(_ response: PostDetailResponse) {
        loadedResponse = response
    }

    func didRequireLogin(message: String) {
        loginRequiredMessage = message
    }

    func didFailLoadPostDetail(error: String) {
        errorMessage = error
    }

    func didCancelLoadPostDetail() {
        errorMessage = "cancelled"
    }

    func didSubmitReply(_ response: PostDetailSubmitReplyResponse) {
        didSubmitReplyCount += 1
        submitReplyResponse = response
    }

    func didFailSubmitReply(error: String) {
        submitReplyErrorMessage = error
    }

    func didAddFavorite(_ response: PostCollectionResponse) {
        addFavoriteResponse = response
    }

    func didFailAddFavorite(error: String) {
        addFavoriteErrorMessage = error
    }

    func didRemoveFavorite(_ response: PostCollectionResponse) {
        removeFavoriteResponse = response
    }

    func didFailRemoveFavorite(error: String) {
        removeFavoriteErrorMessage = error
    }

    func didAddPostLike(_ response: PostUpvoteResponse) {
        postLikeResponse = response
    }

    func didFailAddPostLike(error: String) {
        postLikeErrorMessage = error
    }

    func didAddCommentLike(commentID: String, response: CommentUpvoteResponse) {
        commentLikeResponse = response
    }

    func didFailAddCommentLike(commentID: String, error: String) {
        commentLikeErrorMessage = error
    }

    func didAddPostChickenLeg(_ response: PostChickenLegResponse) {
        postChickenLegResponse = response
    }

    func didFailAddPostChickenLeg(error: String) {
        postChickenLegErrorMessage = error
    }

    func didAddCommentChickenLeg(commentID: String, response: CommentChickenLegResponse) {
        commentChickenLegResponse = response
    }

    func didFailAddCommentChickenLeg(commentID: String, error: String) {
        commentChickenLegErrorMessage = error
    }

    func didAddPostOppose(_ response: PostDislikeResponse) {
        postOpposeResponse = response
    }

    func didFailAddPostOppose(error: String) {
        postOpposeErrorMessage = error
    }

    func didAddCommentOppose(commentID: String, response: CommentDislikeResponse) {
        commentOpposeResponse = response
    }

    func didFailAddCommentOppose(commentID: String, error: String) {
        commentOpposeErrorMessage = error
    }
}

@MainActor
private func waitForInteractorCallbacks() async {
    for _ in 0..<50 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

private actor URLCapturingHTMLClient: HTMLClient {
    private var urls: [URL] = []
    private let response: HTMLResponse

    init(response: HTMLResponse) {
        self.response = response
    }

    func get(_ url: URL) async throws -> HTMLResponse {
        urls.append(url)
        return response
    }

    func post(_ url: URL, formFields: [String: String]) async throws -> HTMLResponse {
        urls.append(url)
        return response
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

@MainActor
private final class SpyPostDetailActionPagePreparer: PostDetailActionPagePreparing {
    private(set) var preparedURLs: [URL] = []

    func prepareActionPage(pageURL: URL) {
        preparedURLs.append(pageURL)
    }
}

@MainActor
private final class SpyCommentSubmissionAutomation: CommentSubmissionAutomating {
    private let response: CommentAutomationResponse
    private(set) var submittedPostID: Int?
    private(set) var submittedContent: String?
    private(set) var submittedReferer: URL?

    init(response: CommentAutomationResponse) {
        self.response = response
    }

    func submitComment(postID: Int, content: String, referer: URL) async throws -> CommentAutomationResponse {
        submittedPostID = postID
        submittedContent = content
        submittedReferer = referer
        return response
    }
}

@MainActor
private final class SpyPostCollectionSubmitting: PostCollectionSubmitting {
    private let response: PostCollectionResponse
    private(set) var submittedPostID: String?
    private(set) var submittedReferer: URL?
    private(set) var removedPostID: String?
    private(set) var removedReferer: URL?

    init(response: PostCollectionResponse) {
        self.response = response
    }

    func addFavorite(postID: String, referer: URL) async throws -> PostCollectionResponse {
        submittedPostID = postID
        submittedReferer = referer
        return response
    }

    func removeFavorite(postID: String, referer: URL) async throws -> PostCollectionResponse {
        removedPostID = postID
        removedReferer = referer
        return response
    }
}

@MainActor
private final class SpyCommentUpvoteSubmitting: CommentUpvoteSubmitting {
    private let response: CommentUpvoteResponse
    private(set) var submittedCommentID: String?
    private(set) var submittedReferer: URL?

    init(response: CommentUpvoteResponse) {
        self.response = response
    }

    func addUpvote(commentID: String, referer: URL) async throws -> CommentUpvoteResponse {
        submittedCommentID = commentID
        submittedReferer = referer
        return response
    }
}

@MainActor
private final class SpyPostUpvoteSubmitting: PostUpvoteSubmitting {
    private let response: PostUpvoteResponse
    private(set) var submittedPostID: String?
    private(set) var submittedReferer: URL?

    init(response: PostUpvoteResponse) {
        self.response = response
    }

    func addUpvote(postID: String, referer: URL) async throws -> PostUpvoteResponse {
        submittedPostID = postID
        submittedReferer = referer
        return response
    }
}

@MainActor
private final class SpyCommentChickenLegSubmitting: CommentChickenLegSubmitting {
    private let response: CommentChickenLegResponse
    private(set) var submittedCommentID: String?
    private(set) var submittedReferer: URL?

    init(response: CommentChickenLegResponse) {
        self.response = response
    }

    func addChickenLeg(commentID: String, referer: URL) async throws -> CommentChickenLegResponse {
        submittedCommentID = commentID
        submittedReferer = referer
        return response
    }
}

@MainActor
private final class SpyPostChickenLegSubmitting: PostChickenLegSubmitting {
    private let response: PostChickenLegResponse
    private(set) var submittedPostID: String?
    private(set) var submittedReferer: URL?

    init(response: PostChickenLegResponse) {
        self.response = response
    }

    func addChickenLeg(postID: String, referer: URL) async throws -> PostChickenLegResponse {
        submittedPostID = postID
        submittedReferer = referer
        return response
    }
}

@MainActor
private final class SpyCommentDislikeSubmitting: CommentDislikeSubmitting {
    private let response: CommentDislikeResponse
    private(set) var submittedCommentID: String?
    private(set) var submittedReferer: URL?

    init(response: CommentDislikeResponse) {
        self.response = response
    }

    func addDislike(commentID: String, referer: URL) async throws -> CommentDislikeResponse {
        submittedCommentID = commentID
        submittedReferer = referer
        return response
    }
}

@MainActor
private final class SpyPostDislikeSubmitting: PostDislikeSubmitting {
    private let response: PostDislikeResponse
    private(set) var submittedPostID: String?
    private(set) var submittedReferer: URL?

    init(response: PostDislikeResponse) {
        self.response = response
    }

    func addDislike(postID: String, referer: URL) async throws -> PostDislikeResponse {
        submittedPostID = postID
        submittedReferer = referer
        return response
    }
}

@MainActor
private final class StubPostAuthorRankLoader: PostAuthorRankLoading {
    let rank: Int?
    let fails: Bool
    let waitsForCompletion: Bool
    private var continuation: CheckedContinuation<Int?, Error>?
    private(set) var requestedAuthorIDs: [Int] = []

    init(rank: Int?, fails: Bool = false, waitsForCompletion: Bool = false) {
        self.rank = rank
        self.fails = fails
        self.waitsForCompletion = waitsForCompletion
    }

    func loadRank(authorID: Int, referer: URL) async throws -> Int? {
        requestedAuthorIDs.append(authorID)
        if waitsForCompletion {
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }
        if fails { throw URLError(.timedOut) }
        return rank
    }

    func completeRankLookup() {
        continuation?.resume(returning: rank)
        continuation = nil
    }
}
