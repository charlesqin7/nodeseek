import Foundation
import Kingfisher
import UIKit

/// Kingfisher 仍负责位图处理、内存/磁盘缓存；SVG 在交付 processor 前异步准备。
@MainActor
final class AvatarImageDataProvider: ImageDataProvider {
    nonisolated let cacheKey: String
    nonisolated let contentURL: URL?
    private let id = UUID()
    private let url: URL
    private let pixelSize: CGSize
    private let pipeline: AvatarDataPipeline
    private weak var imageView: UIImageView?
    private var isCancelled = false

    init(url: URL, size: CGSize, scale: CGFloat, imageView: UIImageView,
         pipeline: AvatarDataPipeline = .shared) {
        self.url = url
        self.contentURL = url
        self.pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        self.cacheKey = "avatar-bitmap-v3|\(url.absoluteString)|\(size.width)x\(size.height)|\(scale)"
        self.imageView = imageView
        self.pipeline = pipeline
    }

    nonisolated func data(handler: @escaping @Sendable (Result<Data, any Error>) -> Void) {
        Task { @MainActor in
            guard !self.isCancelled else {
                handler(.failure(URLError(.cancelled)))
                return
            }
            self.pipeline.load(id: self.id, key: self.cacheKey, url: self.url, pixelSize: self.pixelSize,
                visible: { [weak self] in
                    guard let view = self?.imageView, let window = view.window else { return false }
                    return window.bounds.intersects(view.convert(view.bounds, to: window))
                }, completion: handler)
        }
    }

    func cancel() {
        isCancelled = true
        pipeline.cancel(id: id, key: cacheKey)
    }
}

@MainActor
final class AvatarDataPipeline {
    typealias Completion = @Sendable (Result<Data, any Error>) -> Void
    static let shared = AvatarDataPipeline()
    private struct Consumer {
        let visible: () -> Bool
        let completion: Completion
    }
    private final class Request {
        let generation = UUID()
        var task: URLSessionDataTask?
        var consumers: [UUID: Consumer] = [:]
    }
    private let session: URLSession
    private let scheduler: AvatarRenderScheduler
    private let rasterize: (Data, CGSize) -> Data?
    private let preparedCache = NSCache<NSString, NSData>()
    private var requests: [String: Request] = [:]

    init(session: URLSession? = nil, scheduler: AvatarRenderScheduler = .shared,
         rasterize: @escaping (Data, CGSize) -> Data? = {
             SVGImageRenderer.image(from: $0, size: $1)?.pngData()
         }) {
        let configuration = ImageRequestFactory.makeSessionConfiguration()
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: configuration)
        self.scheduler = scheduler
        self.rasterize = rasterize
        preparedCache.countLimit = 128
        preparedCache.totalCostLimit = 4 * 1024 * 1024
    }

    func load(id: UUID, key: String, url: URL, pixelSize: CGSize,
              visible: @escaping () -> Bool, completion: @escaping Completion) {
        if let data = preparedCache.object(forKey: key as NSString) {
            completion(.success(data as Data))
            return
        }
        let consumer = Consumer(visible: visible, completion: completion)
        if let existing = requests[key] {
            existing.consumers[id] = consumer
            return
        }
        let request = Request()
        request.consumers[id] = consumer
        requests[key] = request
        let generation = request.generation
        var urlRequest = ImageRequestFactory.makeRequest(url: url)
        // HTML challenge 响应不能污染重试；处理后的图片由 Kingfisher 缓存。
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        request.task = session.dataTask(with: urlRequest) { [weak self] data, response, error in
            Task { @MainActor in
                guard let self, self.requests[key]?.generation == generation else { return }
                let isSVG = data.map { SVGContentInspector.looksLikeSVG($0) } ?? false
                if let error {
                    self.finish(key: key, generation: generation, result: .failure(error))
                } else if let data, HTMLPayloadInspector.looksLikeHTMLPayload(data) {
                    // 原样交给 processor，保留既有 Cookie 同步并重试一次的逻辑。
                    self.finish(key: key, generation: generation, result: .success(data))
                } else if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                    self.finish(key: key, generation: generation, result: .failure(URLError(.badServerResponse)))
                } else if let data, isSVG {
                    self.scheduler.enqueue(id: generation, visible: { [weak self] in
                        self?.requests[key]?.consumers.values.contains { $0.visible() } ?? false
                    }, work: { [weak self] in
                        guard let self, self.requests[key]?.generation == generation else { return }
                        if let bitmap = self.rasterize(data, pixelSize) {
                            self.preparedCache.setObject(bitmap as NSData, forKey: key as NSString, cost: bitmap.count)
                            self.finish(key: key, generation: generation, result: .success(bitmap))
                        } else {
                            self.finish(key: key, generation: generation, result: .failure(URLError(.cannotDecodeContentData)))
                        }
                    })
                } else if let data {
                    self.finish(key: key, generation: generation, result: .success(data))
                } else {
                    self.finish(key: key, generation: generation, result: .failure(URLError(.zeroByteResource)))
                }
            }
        }
        request.task?.resume()
    }

    func cancel(id: UUID, key: String) {
        guard let request = requests[key], let consumer = request.consumers.removeValue(forKey: id) else { return }
        if request.consumers.isEmpty {
            requests.removeValue(forKey: key)
            request.task?.cancel()
            scheduler.cancel(id: request.generation)
        }
        consumer.completion(.failure(URLError(.cancelled)))
    }

    private func finish(key: String, generation: UUID, result: Result<Data, any Error>) {
        guard let request = requests[key], request.generation == generation else { return }
        requests.removeValue(forKey: key)
        for consumer in request.consumers.values { consumer.completion(result) }
    }
}
