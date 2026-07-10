import Foundation

#if canImport(ImageIO)
import ImageIO
#endif

public actor ImagePageStore {
    private struct ThumbnailKey: Hashable {
        var pageIndex: Int
        var maxPixelSize: Int
    }

    private let adapter: FixedPageAdapter
    private let maxThumbnailCacheBytes: Int
    private var thumbnails: [ThumbnailKey: Data] = [:]
    private var thumbnailAccessOrder: [ThumbnailKey] = []
    private var thumbnailCacheBytes = 0

    public init(book: Book, maxThumbnailCacheBytes: Int = 32 * 1024 * 1024) {
        adapter = FixedPageAdapter(book: book)
        self.maxThumbnailCacheBytes = max(maxThumbnailCacheBytes, 1)
    }

    public var pageCount: Int {
        adapter.pageCount
    }

    public func data(forPageIndex pageIndex: Int) throws -> Data {
        guard let data = adapter.asset(forPageIndex: pageIndex)?.data else {
            throw BookError.missingAsset("No image payload for page \(pageIndex + 1)")
        }
        return data
    }

    public func thumbnail(forPageIndex pageIndex: Int, maxPixelSize: Int = 320) async throws -> Data {
        let size = max(maxPixelSize, 1)
        let key = ThumbnailKey(pageIndex: pageIndex, maxPixelSize: size)
        if let cached = thumbnails[key] {
            touch(key)
            return cached
        }
        let source = try data(forPageIndex: pageIndex)
        let rendered = try await Self.renderThumbnail(source, maxPixelSize: size)
        insert(rendered, for: key)
        return rendered
    }

    public func prefetch(
        aroundPageIndex pageIndex: Int,
        distance: Int = 2,
        thumbnailPixelSize: Int = 320
    ) async {
        let radius = min(max(distance, 0), 8)
        guard radius > 0 else { return }
        let lower = max(pageIndex - radius, 0)
        let upper = min(pageIndex + radius, adapter.pageCount - 1)
        let size = max(thumbnailPixelSize, 1)
        var work: [(ThumbnailKey, Data)] = []

        for index in lower...upper {
            let key = ThumbnailKey(pageIndex: index, maxPixelSize: size)
            guard thumbnails[key] == nil, let data = try? data(forPageIndex: index) else { continue }
            work.append((key, data))
        }

        let rendered = await withTaskGroup(
            of: (ThumbnailKey, Data)?.self,
            returning: [(ThumbnailKey, Data)].self
        ) { group in
            for (key, source) in work {
                group.addTask {
                    guard !Task.isCancelled,
                          let thumbnail = try? await Self.renderThumbnail(source, maxPixelSize: size)
                    else {
                        return nil
                    }
                    return (key, thumbnail)
                }
            }
            var values: [(ThumbnailKey, Data)] = []
            for await value in group {
                if let value { values.append(value) }
            }
            return values
        }

        guard !Task.isCancelled else { return }
        for (key, data) in rendered where thumbnails[key] == nil {
            insert(data, for: key)
        }
    }

    public func removeAllThumbnails() {
        thumbnails.removeAll(keepingCapacity: false)
        thumbnailAccessOrder.removeAll(keepingCapacity: false)
        thumbnailCacheBytes = 0
    }

    public func cachedThumbnailCount() -> Int {
        thumbnails.count
    }

    private func touch(_ key: ThumbnailKey) {
        thumbnailAccessOrder.removeAll { $0 == key }
        thumbnailAccessOrder.append(key)
    }

    private func insert(_ data: Data, for key: ThumbnailKey) {
        if let previous = thumbnails.updateValue(data, forKey: key) {
            thumbnailCacheBytes -= previous.count
        }
        thumbnailCacheBytes += data.count
        touch(key)

        while thumbnailCacheBytes > maxThumbnailCacheBytes,
              let oldest = thumbnailAccessOrder.first
        {
            thumbnailAccessOrder.removeFirst()
            if let removed = thumbnails.removeValue(forKey: oldest) {
                thumbnailCacheBytes -= removed.count
            }
        }
    }

    private nonisolated static func renderThumbnail(
        _ data: Data,
        maxPixelSize: Int
    ) async throws -> Data {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ] as CFDictionary
              )
        else {
            throw BookError.renderingFailed("Unable to decode image page")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw BookError.renderingFailed("Unable to create image thumbnail")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BookError.renderingFailed("Unable to encode image thumbnail")
        }
        return output as Data
        #else
        throw BookError.renderingFailed("ImageIO is unavailable on this platform")
        #endif
    }
}
