import AVFoundation

enum ChapterReader {
    static func read(_ asset: AVAsset, track: Int) async throws -> [BookChapter] {
        let locales = try await asset.load(.availableChapterLocales)
        guard let locale = locales.first else { return [] }
        // Titles are included by default; extra common keys only support artwork.
        let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])
        return await parse(groups, track: track)
    }
    static func parse(_ groups: [AVTimedMetadataGroup], track: Int) async -> [BookChapter] {
        var chapters: [BookChapter] = []
        for (index, group) in groups.enumerated() {
            let start = group.timeRange.start.seconds
            let end = CMTimeRangeGetEnd(group.timeRange).seconds
            guard start.isFinite, end.isFinite, start >= 0, end > start else { continue }
            let item = group.items.first { $0.commonKey == .commonKeyTitle }
            let title = try? await item?.load(.stringValue)
            chapters.append(BookChapter(id: "\(track):\(start)", title: title ?? "Chapter \(index + 1)", trackIndex: track, start: start, end: end))
        }
        return chapters.sorted { $0.start < $1.start }
    }
}
