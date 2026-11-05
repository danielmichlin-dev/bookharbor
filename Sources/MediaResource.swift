import AVFoundation
import UniformTypeIdentifiers

// AVPlayer sees only a private scheme. The loader owns every authenticated HTTPS
// range request, so AVFoundation cannot forward credentials to a redirect target.
final class MediaResource: NSObject, AVAssetResourceLoaderDelegate {
    let asset: AVURLAsset
    private let request: URLRequest
    private let bytes: Int64
    private let ext: String
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(request: URLRequest, bytes: Int64, ext: String) {
        self.request = request; self.bytes = bytes; self.ext = ext
        asset = AVURLAsset(url: URL(string: "bookharbor-media://original/audio." + ext)!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }
    func cancel() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loading: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(loading)
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil }
            do {
                if let info = loading.contentInformationRequest {
                    info.contentLength = self.bytes
                    info.isByteRangeAccessSupported = true
                    info.contentType = UTType(filenameExtension: self.ext)?.identifier ?? UTType.audio.identifier
                }
                if let dataRequest = loading.dataRequest {
                    var offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
                    let end = dataRequest.requestsAllDataToEndOfResource ? self.bytes : min(self.bytes, dataRequest.requestedOffset + Int64(dataRequest.requestedLength))
                    while offset < end {
                        try Task.checkCancellation()
                        let last = min(end - 1, offset + 1024 * 1024 - 1)
                        var request = self.request
                        request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
                        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        let (data, response) = try await PlexTransport.shared.data(request)
                        // Refuse servers that ignore Range instead of buffering an entire book.
                        guard response.statusCode == 206,
                              response.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(last)/\(self.bytes)",
                              data.count == Int(last - offset + 1) else { throw PlexError.incomplete }
                        try Task.checkCancellation()
                        guard !loading.isCancelled else { return }
                        dataRequest.respond(with: data)
                        offset += Int64(data.count)
                    }
                }
                guard !loading.isCancelled else { return }
                loading.finishLoading()
            } catch {
                guard !loading.isCancelled else { return }
                loading.finishLoading(with: PlexError.unavailable)
            }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }
}
