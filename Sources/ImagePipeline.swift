// The MIT License (MIT)
//
// Copyright (c) 2015-2018 Alexander Grebenyuk (github.com/kean).

import Foundation

// MARK: - ImageTask

/// - important: Make sure that you access Task properties only from the
/// delegate queue.
public /* final */ class ImageTask: Hashable {
    public let taskId: Int
    private(set) public var request: ImageRequest

    public var completedUnitCount: Int64 = 0
    public var totalUnitCount: Int64 = 0

    public var progressHandler: ProgressHandler?
    public var progressiveImageHandler: ProgressiveImageHandler?

    public typealias Completion = (_ result: Result<Image>) -> Void
    public typealias ProgressHandler = (_ completed: Int64, _ total: Int64) -> Void
    public typealias ProgressiveImageHandler = (_ image: Image) -> Void

    fileprivate(set) public var metrics: Metrics

    fileprivate weak private(set) var pipeline: ImagePipeline?
    fileprivate weak var session: ImagePipeline.Session?
    fileprivate var isExecuting = false
    fileprivate var isCancelled = false

    public init(taskId: Int, request: ImageRequest, pipeline: ImagePipeline) {
        self.taskId = taskId
        self.request = request
        self.pipeline = pipeline
        self.metrics = Metrics(taskId: taskId, timeStarted: _now())
    }

    public func cancel() {
        pipeline?._imageTaskCancelled(self)
    }

    public func setPriority(_ priority: ImageRequest.Priority) {
        request.priority = priority
        pipeline?._imageTask(self, didUpdatePriority: priority)
    }

    public static func ==(lhs: ImageTask, rhs: ImageTask) -> Bool {
        return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
    }

    public var hashValue: Int {
        return ObjectIdentifier(self).hashValue
    }
}

// MARK: - ImagePipeline

/// `ImagePipeline` implements an image loading pipeline. It loads image data using
/// data loader (`DataLoading`), then creates an image using `DataDecoding`
/// object, and transforms the image using processors (`Processing`) provided
/// in the `Request`.
///
/// Pipeline combines the requests with the same `loadKey` into a single request.
/// The request only gets cancelled when all the registered handlers are.
///
/// `ImagePipeline` limits the number of concurrent requests (the default maximum limit
/// is 5). It also rate limits the requests to prevent `Loader` from trashing
/// underlying systems (e.g. `URLSession`). The rate limiter only comes into play
/// when the requests are started and cancelled at a high rate (e.g. fast
/// scrolling through a collection view).
///
/// `ImagePipeline` features can be configured using `Loader.Options`.
///
/// `ImagePipeline` is thread-safe.
public /* final */ class ImagePipeline {
    public let configuration: Configuration

    // Synchornized access to sessions.
    private let queue = DispatchQueue(label: "com.github.kean.Nuke.ImagePipeline")

    private let decodingQueue = DispatchQueue(label: "com.github.kean.Nuke.ImagePipeline.DecodingQueue")

    // Image loading sessions. One or more tasks can be handled by the same session.
    private var sessions = [AnyHashable: Session]()

    private var nextTaskId: Int32 = 0
    private var nextSessionId: Int32 = 0

    private let rateLimiter: RateLimiter

    /// Shared image pipeline.
    public static var shared = ImagePipeline()

    public struct Configuration {
        /// Data loader using by the pipeline.
        public var dataLoader: DataLoading

        public var dataLoadingQueue = OperationQueue()

        /// Default implementation uses shared `ImageDecoderRegistry` to create
        /// a decoder that matches the context.
        public var imageDecoder: (ImageDecodingContext) -> ImageDecoding = {
            return ImageDecoderRegistry.shared.decoder(for: $0)
        }

        /// Image cache used by the pipeline.
        public var imageCache: ImageCaching?

        /// Returns a processor for the context. By default simply returns
        /// `request.processor`. Please keep in mind that you can override the
        /// processor from the request using this option but you're not going
        /// to override the processor used as a cache key.
        public var imageProcessor: (ImageProcessingContext) -> AnyImageProcessor? = {
            return $0.request.processor
        }

        public var imageProcessingQueue = OperationQueue()

        /// `true` by default. If `true` loader combines the requests with the
        /// same `loadKey` into a single request. The request only gets cancelled
        /// when all the registered requests are.
        public var isDeduplicationEnabled = true

        /// `true` by default. It `true` loader rate limits the requests to
        /// prevent `Loader` from trashing underlying systems (e.g. `URLSession`).
        /// The rate limiter only comes into play when the requests are started
        /// and cancelled at a high rate (e.g. scrolling through a collection view).
        public var isRateLimiterEnabled = true

        /// `false` by default.
        public var isProgressiveDecodingEnabled = false

        /// Creates default configuration.
        /// - parameter dataLoader: `DataLoader()` by default.
        /// - parameter imageCache: `Cache.shared` by default.
        /// - parameter options: Options which can be used to customize loader.
        public init(dataLoader: DataLoading = DataLoader(), imageCache: ImageCaching? = ImageCache.shared) {
            self.dataLoader = dataLoader
            self.imageCache = imageCache

            self.dataLoadingQueue.maxConcurrentOperationCount = 6
            self.imageProcessingQueue.maxConcurrentOperationCount = 2
        }
    }

    /// Initializes `Loader` instance with the given loader, decoder.
    /// - parameter configuration: `Configuration()` by default.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.rateLimiter = RateLimiter(queue: queue)
    }

    public convenience init(_ configure: (inout ImagePipeline.Configuration) -> Void) {
        var configuration = ImagePipeline.Configuration()
        configure(&configuration)
        self.init(configuration: configuration)
    }

    // MARK: Loading Images

    /// Loads an image with the given url.
    @discardableResult public func loadImage(with url: URL, completion: @escaping ImageTask.Completion) -> ImageTask {
        return loadImage(with: ImageRequest(url: url), completion: completion)
    }

    /// Loads an image for the given request using image loading pipeline.
    @discardableResult public func loadImage(with request: ImageRequest, completion: @escaping ImageTask.Completion) -> ImageTask {
        let task = ImageTask(taskId: Int(OSAtomicIncrement32(&nextTaskId)), request: request, pipeline: self)
        queue.async {
            guard !task.isCancelled else { return } // Fast preflight check
            self._startLoadingImage(for: task, completion: completion)
        }
        return task
    }

    private func _startLoadingImage(for task: ImageTask, completion: @escaping ImageTask.Completion) {
        if let image = _cachedImage(for: task.request) {
            task.metrics.isMemoryCacheHit = true
            DispatchQueue.main.async { completion(.success(image)) }
            return
        }

        let session = _createSession(with: task.request)
        task.session = session

        task.metrics.session = session.metrics
        task.metrics.wasSubscibedToExistingTask = !session.tasks.isEmpty

        // Register handler with a session.
        session.tasks[task] = Session.ImageTaskContext(completion: completion)

        // Update data operation priority (in case it was already started).
        session.dataOperation?.queuePriority = session.priority.queuePriority
    }

    fileprivate func _imageTask(_ task: ImageTask, didUpdatePriority: ImageRequest.Priority) {
        queue.async {
            guard let session = task.session else { return }
            session.dataOperation?.queuePriority = session.priority.queuePriority
        }
    }

    // Cancel the session in case all handlers were removed.
    fileprivate func _imageTaskCancelled(_ task: ImageTask) {
        queue.async {
            guard !task.isCancelled else { return }
            task.isCancelled = true

            task.metrics.wasCancelled = true
            task.metrics.timeCompleted = _now()

            guard let session = task.session else { return } // exeuting == true
            session.tasks[task] = nil
            // Cancel the session when there are no remaining tasks.
            if session.tasks.isEmpty {
                session.cts.cancel()
                self._removeSession(session)
            }
        }
    }

    // MARK: Managing Sessions

    private func _createSession(with request: ImageRequest) -> Session {
        // Check if session for the given key already exists.
        //
        // This part is more clever than I would like. The reason why we need a
        // key even when deduplication is disabled is to have a way to retain
        // a session by storing it in `sessions` dictionary.
        let key = configuration.isDeduplicationEnabled ? request.loadKey : UUID()
        if let session = sessions[key] {
            return session
        }
        let session = Session(sessionId: Int(OSAtomicIncrement32(&nextSessionId)), request: request, key: key)
        sessions[key] = session
        _loadImage(for: session) // Start the pipeline
        return session
    }

    private func _removeSession(_ session: Session) {
        // Check in case we already started a new session for the same loading key.
        if sessions[session.key] === session {
            // By removing a session we get rid of all the stuff that is no longer
            // needed after completing associated tasks. This includes completion
            // and progress closures, individual requests, etc. The user may still
            // hold a reference to `ImageTask` at this point, but it doesn't
            // store almost anythng.
            sessions[session.key] = nil
        }
    }

    // MARK: Image Pipeline
    //
    // This is where the images actually get loaded.

    private func _loadImage(for session: Session) {
        // Use rate limiter to prevent trashing of the underlying systems
        if configuration.isRateLimiterEnabled {
            // Rate limiter is synchronized on pipeline's queue. Delayed work is
            // executed asynchronously also on this same queue.
            rateLimiter.execute(token: session.cts.token) { [weak self, weak session] in
                guard let session = session else { return }
                self?._loadData(for: session)
            }
        } else { // Start loading immediately.
            _loadData(for: session)
        }
    }

    private func _loadData(for session: Session) {
        let token = session.cts.token
        let request = session.request.urlRequest

        guard !token.isCancelling else { return } // Preflight check

        // Wrap data request in an operation to limit maximum number of
        // concurrent data tasks.
        let operation = Operation(starter: { [weak self, weak session] finish in
            let task = self?.configuration.dataLoader.loadData(
                with: request,
                didReceiveData: { (data, response) in
                    self?.queue.async {
                        guard let session = session else { return }
                        self?._session(session, didReceiveData: data, response: response)
                    }
                },
                completion: { (error) in
                    finish() // Important! Mark Operation as finished.
                    self?.queue.async {
                        guard let session = session else { return }
                        self?._session(session, didFinishLoadingDataWithError: error)
                    }
            })
            token.register {
                task?.cancel()
                finish() // Make sure we always finish the operation.
            }
        })

        operation.queuePriority = session.priority.queuePriority
        self.configuration.dataLoadingQueue.addOperation(operation)
        token.register { [weak operation] in operation?.cancel() }

        // FIXME: This is not an accurate metric
        session.metrics.timeDataLoadingStarted = _now()
        session.dataOperation = operation
    }

    private func _session(_ session: Session, didReceiveData data: Data, response: URLResponse) {
        let downloadedDataCount = session.downloadedDataCount + data.count
        session.downloadedDataCount = downloadedDataCount

        // Save boring metrics
        session.metrics.downloadedDataCount = downloadedDataCount
        session.metrics.urlResponse = response

        // Update tasks' progress and call progress closures if any
        let (completed, total) = (Int64(downloadedDataCount), response.expectedContentLength)
        let tasks = session.tasks
        DispatchQueue.main.async {
            for task in tasks.keys { // We access tasks only on main thread
                (task.completedUnitCount, task.totalUnitCount) = (completed, total)
                task.progressHandler?(completed, total)
            }
        }

        let isProgerssive = configuration.isProgressiveDecodingEnabled

        // Create a decoding session (if none) which consists of a data buffer
        // and an image decoder. We access both exclusively on `decodingQueue`.
        if session.decoding == nil {
            let context = ImageDecodingContext(request: session.request, urlResponse: response, data: data)
            session.decoding = (configuration.imageDecoder(context), DataBuffer(isProgressive: isProgerssive))
        }
        let (decoder, buffer) = session.decoding!

        decodingQueue.async { [weak self, weak session] in
            guard let session = session else { return }

            // Append data (we always do it)
            buffer.append(data)

            // Check if progressive decoding is enabled (disabled by default)
            guard isProgerssive else { return }

            // Check if we haven't loaded an entire image yet. We give decoder
            // an opportunity to decide whether to decode this chunk or not.
            // In case `expectedContentLength` is undetermined (e.g. 0) we
            // don't allow progressive decoding.
            guard data.count < response.expectedContentLength else { return }

            // Produce partial image
            guard let image = decoder.decode(data: buffer.data, isFinal: false) else { return }
            let scanNumber: Int? = (decoder as? ImageDecoder)?.numberOfScans // Need a public way to implement this.
            self?.queue.async {
                self?._session(session, didDecodePartialImage: image, scanNumber: scanNumber)
            }
        }
    }

    private func _session(_ session: Session, didFinishLoadingDataWithError error: Swift.Error?) {
        session.metrics.timeDataLoadingFinished = _now()

        guard error == nil, session.downloadedDataCount > 0, let (decoder, buffer) = session.decoding else {
            _session(session, completedWith: .failure(error ?? Error.decodingFailed))
            return
        }

        decodingQueue.async { [weak self, weak session] in
            guard let session = session else { return }
            // Produce final image
            let image = autoreleasepool { decoder.decode(data: buffer.data, isFinal: true) }
            self?.queue.async {
                self?._session(session, didDecodeImage: image)
            }
        }
    }

    private func _session(_ session: Session, didDecodePartialImage image: Image, scanNumber: Int?) {
        // Producing faster than able to consume, skip this partial.
        // As an alternative we could store partial in a buffer for later, but
        // this is an option which is simpler to implement.
        guard session.processingPartialOperation == nil else { return }

        let context = ImageProcessingContext(image: image, request: session.request, isFinal: false, scanNumber: scanNumber)
        guard let processor = configuration.imageProcessor(context) else {
            _session(session, didProducePartialImage: image)
            return
        }

        let operation = BlockOperation { [weak self, weak session] in
            guard let session = session else { return }
            let image = autoreleasepool { processor.process(image) }
            self?.queue.async {
                session.processingPartialOperation = nil
                if let image = image {
                    self?._session(session, didProducePartialImage: image)
                }
            }
        }
        session.processingPartialOperation = operation
        configuration.imageProcessingQueue.addOperation(operation)
    }

    private func _session(_ session: Session, didDecodeImage image: Image?) {
        session.decoding = nil // Decoding session completed, free resources
        session.metrics.timeDecodingFinished = _now()

        guard let image = image else {
            _session(session, completedWith: .failure(Error.decodingFailed))
            return
        }

        // Check if processing is required, complete immediatelly if not.
        let context = ImageProcessingContext(image: image, request: session.request, isFinal: true, scanNumber: nil)
        guard let processor = configuration.imageProcessor(context) else {
            _session(session, completedWith: .success(image))
            return
        }

        let operation = BlockOperation { [weak self, weak session] in
            guard let session = session else { return }
            let image = autoreleasepool { processor.process(image) }
            let result = image.map(Result.success) ?? .failure(Error.processingFailed)
            self?.queue.async {
                session.metrics.timeProcessingFinished = _now()
                self?._session(session, completedWith: result)
            }
        }
        session.cts.token.register { [weak operation] in operation?.cancel() }
        configuration.imageProcessingQueue.addOperation(operation)
    }

    private func _session(_ session: Session, didProducePartialImage image: Image) {
        // Check if we haven't completed the session yet by producing a final image.
        guard !session.isCompleted else { return }
        let tasks = session.tasks.keys
        DispatchQueue.main.async {
            for task in tasks {
                task.progressiveImageHandler?(image)
            }
        }
    }

    private func _session(_ session: Session, completedWith result: Result<Image>) {
        if let image = result.value {
            _store(image: image, for: session.request)
        }
        session.isCompleted = true

        // Cancel any outstanding parital processing.
        session.processingPartialOperation?.cancel()

        let tasks = session.tasks
        tasks.keys.forEach { $0.metrics.timeCompleted = _now() }
        DispatchQueue.main.async {
            for (_, context) in tasks {
                context.completion(result)
            }
        }
        _removeSession(session)
    }

    // MARK: Memory Cache Helpers

    private func _cachedImage(for request: ImageRequest) -> Image? {
        guard request.memoryCacheOptions.readAllowed else { return nil }
        return configuration.imageCache?[request]
    }

    private func _store(image: Image, for request: ImageRequest) {
        guard request.memoryCacheOptions.writeAllowed else { return }
        configuration.imageCache?[request] = image
    }

    // MARK: Session

    /// A image loading session. During a lifetime of a session handlers can
    /// subscribe to and unsubscribe from it.
    fileprivate final class Session {
        let sessionId: Int
        var isCompleted: Bool = false

        /// The original request with which the session was created.
        let request: ImageRequest
        let key: AnyHashable // loading key
        let cts = CancellationTokenSource()

        // Associate context with a task but without a direct strong reference
        // between the two
        var tasks: [ImageTask: ImageTaskContext] = [:]

        weak var dataOperation: Foundation.Operation?
        var downloadedDataCount: Int = 0

        var decoding: (ImageDecoding, DataBuffer)?

        var processingPartialOperation: Foundation.Operation?

        // Metrics that we collect during the lifetime of a session.
        let metrics: ImageTask.Metrics.SessionMetrics

        struct ImageTaskContext {
            let completion: ImageTask.Completion
        }

        init(sessionId: Int, request: ImageRequest, key: AnyHashable) {
            self.sessionId = sessionId
            self.request = request
            self.key = key
            self.metrics = ImageTask.Metrics.SessionMetrics(sessionId: sessionId)
        }

        var priority: ImageRequest.Priority {
            return tasks.keys.map { $0.request.priority }.max() ?? .normal
        }
    }

    // MARK: Errors

    /// Error returns by `Loader` class itself. `Loader` might also return
    /// errors from underlying `DataLoading` object.
    public enum Error: Swift.Error, CustomDebugStringConvertible {
        case decodingFailed
        case processingFailed

        public var debugDescription: String {
            switch self {
            case .decodingFailed: return "Failed to create an image from the image data"
            case .processingFailed: return "Failed to process the image"
            }
        }
    }
}

// MARK - Metrics

extension ImageTask {
    public struct Metrics {

        // Timings

        public let taskId: Int
        public let timeStarted: TimeInterval
        public fileprivate(set) var timeCompleted: TimeInterval? // failed or completed

        // Download session metrics. One more more tasks can share the same
        // session metrics.
        public final class SessionMetrics {
            /// - important: Data loading might start prior to `timeResumed` if the task gets
            /// coalesced with another task.
            public let sessionId: Int
            public fileprivate(set) var timeDataLoadingStarted: TimeInterval?
            public fileprivate(set) var timeDataLoadingFinished: TimeInterval?
            public fileprivate(set) var timeDecodingFinished: TimeInterval?
            public fileprivate(set) var timeProcessingFinished: TimeInterval?
            public fileprivate(set) var urlResponse: URLResponse?
            public fileprivate(set) var downloadedDataCount: Int?

            init(sessionId: Int) { self.sessionId = sessionId }
        }

        public fileprivate(set) var session: SessionMetrics?

        public var totalDuration: TimeInterval? {
            guard let timeCompleted = timeCompleted else { return nil }
            return timeCompleted - timeStarted
        }

        init(taskId: Int, timeStarted: TimeInterval) {
            self.taskId = taskId; self.timeStarted = timeStarted
        }

        // Properties

        /// Returns `true` is the task wasn't the one that initiated image loading.
        public fileprivate(set) var wasSubscibedToExistingTask: Bool = false
        public fileprivate(set) var isMemoryCacheHit: Bool = false
        public fileprivate(set) var wasCancelled: Bool = false
    }
}

// MARK: - Contexts

/// Image decoding context used when selecting which decoder to use.
public struct ImageDecodingContext {
    public let request: ImageRequest
    public let urlResponse: URLResponse
    public let data: Data
}

/// Image processing context used when selecting which processor to use.
public struct ImageProcessingContext {
    public let image: Image
    public let request: ImageRequest
    public let isFinal: Bool
    public let scanNumber: Int? // need a more general purpose way to implement this
}
