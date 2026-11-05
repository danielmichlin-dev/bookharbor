import AVFoundation
import UniformTypeIdentifiers

// AVFoundation sees only this private scheme. Authenticated HTTPS and redirects
// remain under our transport's control; no token is given to AVPlayer.
final class MediaResource: NSObject, AVAssetResourceLoaderDelegate {
    typealias Fetch = (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    let asset: AVURLAsset
    private let request: URLRequest
    private let bytes: Int64
    private let ext: String
    private let fetch: Fetch
    var event: ((PlaybackStage, PlaybackFact, Int?) -> Void)?
    var failure: ((PlexError) -> Void)?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var reportedResponse = false
    init(request: URLRequest, bytes: Int64, ext: String,
         fetch: @escaping Fetch = { try await PlexTransport.shared.data($0, limit: $1) }) {
        self.request = request; self.bytes = bytes; self.ext = ext; self.fetch = fetch
        asset = AVURLAsset(url: URL(string: "bookharbor-media://original/audio." + ext)!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: .main)
    }
    func cancel() { tasks.values.forEach { $0.cancel() }; tasks.removeAll() }
    @MainActor private func range(offset: Int64, last: Int64) async throws -> (Data, Int64) {
        var request = self.request
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("bytes=\(offset)-\(last)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (data, response) = try await fetch(request, Int(last - offset + 1))
        if !reportedResponse { event?(.http, .response, response.statusCode); reportedResponse = true }
        let next = try MediaRange.validate(response, count: data.count, offset: offset, last: last, total: bytes)
        return (data, next)
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loading: AVAssetResourceLoadingRequest) -> Bool {
        let id = ObjectIdentifier(loading)
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil }
            do {
                if let info = loading.contentInformationRequest {
                    // Probe the actual original-media endpoint, including authentication
                    // and range support, before reporting content information.
                    _ = try await self.range(offset: 0, last: min(1, self.bytes - 1))
                    try Task.checkCancellation()
                    guard !loading.isCancelled else { return }
                    info.contentLength = self.bytes
                    info.isByteRangeAccessSupported = true
                    info.contentType = Self.contentType(self.ext)
                    self.event?(.range, .complete, nil)
                    // AVFoundation's content-info probe may also expose a two-byte
                    // dataRequest. It is not a media-data request: finish the probe.
                    loading.finishLoading()
                    return
                }
                if let dataRequest = loading.dataRequest {
                    var offset = max(dataRequest.requestedOffset, dataRequest.currentOffset)
                    let end = try MediaRange.end(offset: offset, length: dataRequest.requestedLength,
                                                 allToEnd: dataRequest.requestsAllDataToEndOfResource, total: self.bytes)
                    while offset < end {
                        try Task.checkCancellation()
                        let last = min(end - 1, offset + 512 * 1024 - 1)
                        let (data, next) = try await self.range(offset: offset, last: last)
                        try Task.checkCancellation()
                        guard !loading.isCancelled else { return }
                        dataRequest.respond(with: data)
                        offset = next
                    }
                }
                guard !loading.isCancelled else { return }
                loading.finishLoading()
            } catch {
                guard !loading.isCancelled, !Task.isCancelled else { return }
                let problem = (error as? PlexError) ?? .unavailable
                if case .http(let code) = problem { self.event?(.http, .rejected, code) }
                else if case .network(let code) = problem { self.event?(.connection, .failed, code) }
                else { self.event?(.range, .failed, nil) }
                self.failure?(problem)
                loading.finishLoading(with: problem)
            }
        }
        return true
    }
    static func contentType(_ ext: String) -> String {
        if ["m4a", "m4b", "mp4"].contains(ext) { return UTType.mpeg4Audio.identifier }
        return UTType(filenameExtension: ext)?.identifier ?? UTType.audio.identifier
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }
}
