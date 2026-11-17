import Foundation

/// Owns a unique temporary directory. Never removes downloaded files from other jobs.
final class AppUpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private let lock = NSLock()
    private var cancelled = false
    private var progress: (@Sendable (Double) -> Void)?
    private var expectedBytes: Int64 = 0
    private var destination: URL?

    func download(_ asset: AppReleaseAsset, to destination: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let url = asset.browser_download_url
        self.destination = destination
        self.expectedBytes = Int64(asset.size)
        self.progress = progress
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                task.resume()
                lock.unlock()
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let session = session
        lock.unlock()
        session?.invalidateAndCancel()
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let saved = continuation
        continuation = nil
        let session = session
        self.session = nil
        lock.unlock()
        saved?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expectedBytes || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite != expectedBytes) {
            finish(.failure(UpdateFailure.invalid("下载大小与发布信息不一致。")))
            session.invalidateAndCancel()
            return
        }
        progress?(min(1, Double(totalBytesWritten) / Double(max(1, expectedBytes))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let destination, (try location.resourceValues(forKeys: [.fileSizeKey])).fileSize == Int(expectedBytes) else {
                throw UpdateFailure.invalid("下载安装包失败或文件大小不正确。")
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
