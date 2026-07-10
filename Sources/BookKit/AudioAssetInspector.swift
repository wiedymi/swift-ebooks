import Foundation

struct AudioAssetInspection: Sendable {
    struct Chapter: Sendable {
        var title: String?
        var start: Double
        var end: Double
    }

    var title: String?
    var artist: String?
    var duration: Double?
    var chapters: [Chapter]
    var artwork: Data?
}

enum AudioAssetInspector {
    static func inspect(
        data: Data,
        fileName: String,
        tempDirectory: URL?
    ) async throws -> AudioAssetInspection {
        try AudioProtectionProbe.validate(data, resource: fileName)
        #if canImport(AVFoundation)
        return try await inspectWithAVFoundation(
            data: data,
            fileName: fileName,
            tempDirectory: tempDirectory
        )
        #else
        return AudioAssetInspection(chapters: [])
        #endif
    }
}

#if canImport(AVFoundation)
import AVFoundation

private extension AudioAssetInspector {
    static func inspectWithAVFoundation(
        data: Data,
        fileName: String,
        tempDirectory: URL?
    ) async throws -> AudioAssetInspection {
        let root = tempDirectory ?? FileManager.default.temporaryDirectory
        let directory = root.appendingPathComponent("BookKitInspection", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((fileName as NSString).pathExtension)
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        #if !os(visionOS)
        let protected = try await asset.load(.hasProtectedContent)
        guard !protected else {
            throw BookError.protectedContent(
                ContentProtection(
                    kind: .audioDRM,
                    scheme: "AVFoundation protected content",
                    resource: fileName
                )
            )
        }
        #endif

        let playable = try await asset.load(.isPlayable)
        guard playable else {
            throw BookError.invalidContainer("Standalone audio resource is not playable")
        }
        let durationTime = try await asset.load(.duration)
        let rawDuration = CMTimeGetSeconds(durationTime)
        let duration = rawDuration.isFinite && rawDuration >= 0 ? rawDuration : nil
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        let title = await stringValue(
            from: AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .commonIdentifierTitle
            ).first
        )
        let artist = await stringValue(
            from: AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .commonIdentifierArtist
            ).first
        )
        let artwork = await dataValue(
            from: AVMetadataItem.metadataItems(
                from: metadata,
                filteredByIdentifier: .commonIdentifierArtwork
            ).first
        )

        var chapters: [AudioAssetInspection.Chapter] = []
        #if !os(visionOS)
        let groups = (try? await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: Locale.preferredLanguages
        )) ?? []
        for (index, group) in groups.enumerated() {
            let start = CMTimeGetSeconds(group.timeRange.start)
            let groupDuration = CMTimeGetSeconds(group.timeRange.duration)
            guard start.isFinite, groupDuration.isFinite, groupDuration > 0 else { continue }
            let chapterTitle = await stringValue(
                from: AVMetadataItem.metadataItems(
                    from: group.items,
                    filteredByIdentifier: .commonIdentifierTitle
                ).first
            ) ?? "Chapter \(index + 1)"
            chapters.append(
                AudioAssetInspection.Chapter(
                    title: chapterTitle,
                    start: max(start, 0),
                    end: max(start + groupDuration, start)
                )
            )
        }
        #endif

        return AudioAssetInspection(
            title: title,
            artist: artist,
            duration: duration,
            chapters: chapters,
            artwork: artwork
        )
    }

    static func stringValue(from item: AVMetadataItem?) async -> String? {
        guard let item else { return nil }
        return try? await item.load(.stringValue)
    }

    static func dataValue(from item: AVMetadataItem?) async -> Data? {
        guard let item else { return nil }
        return try? await item.load(.dataValue)
    }
}
#endif
