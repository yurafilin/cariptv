import Foundation

/// The local copy `HLSPackager` reads from: a local file as it is, or a web file that keeps growing
/// on disk while it downloads. Readers wait on `waitForChange()` for more bytes.
final class SourceFile: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private var received: Int64 = 0
    private var expected: Int64?
    private var complete = false
    private var failure: Error?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var handle: FileHandle?
    private var session: URLSession?
    private var lastReported = -1

    /// Whole percents of the download, from the download's queue.
    var onProgress: (@Sendable (Double) -> Void)?

    /// A file that is already all here.
    init(local url: URL) {
        self.url = url
        complete = true
    }

    /// An empty file at `url` that grows through `append(_:)`; `finish()` marks the end.
    init(growing url: URL, expectedLength: Int64? = nil) throws {
        self.url = url
        expected = expectedLength
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        handle = try FileHandle(forWritingTo: url)
    }

    /// Downloads `request` into `url`, growing as the bytes arrive.
    static func download(_ request: URLRequest, to url: URL) throws -> SourceFile {
        let file = try SourceFile(growing: url)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .default, delegate: file, delegateQueue: queue)
        file.lock.withLock { file.session = session }
        session.dataTask(with: request).resume()
        return file
    }

    var isComplete: Bool { lock.withLock { complete } }
    var error: Error? { lock.withLock { failure } }
    var receivedBytes: Int64 { lock.withLock { received } }

    /// Share of the file on disk, 0…1; 0 while the length is unknown.
    var fraction: Double {
        lock.withLock {
            if complete { return 1 }
            guard let expected, expected > 0 else { return 0 }
            return min(Double(received) / Double(expected), 1)
        }
    }

    /// Returns when more bytes arrive, or at once if the file is complete or failed.
    func waitForChange() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            defer { lock.unlock() }
            if complete || failure != nil {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func append(_ data: Data) throws {
        try lock.withLock {
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
        }
        report()
        wake()
    }

    func finish(with error: Error? = nil) {
        lock.withLock {
            try? handle?.close()
            handle = nil
            if let error {
                failure = failure ?? error
            } else {
                complete = true
            }
        }
        report()
        wake()
    }

    func cancel() {
        let session = lock.withLock { self.session }
        session?.invalidateAndCancel()
        finish(with: CancellationError())
    }

    private func wake() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    private func report() {
        let fraction = fraction
        let percent = Int(fraction * 100)
        let changed = lock.withLock { () -> Bool in
            defer { lastReported = percent }
            return percent != lastReported
        }
        if changed { onProgress?(fraction) }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            completionHandler(.cancel)
            finish(with: HLSPackager.PackagerError.downloadFailed)
            return
        }
        let length = response.expectedContentLength
        lock.withLock { expected = length > 0 ? length : nil }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try append(data)
        } catch {
            dataTask.cancel()
            finish(with: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finish(with: error)
        session.finishTasksAndInvalidate()
    }
}
