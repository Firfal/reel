import Foundation

public enum Privacy: String, Codable, Sendable, CaseIterable {
    case publicLink, unlisted, password
}

/// A video in the library. Stored as `item.json` next to `video.mp4` in its own folder.
public struct VideoItem: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: Double
    public var folder: String?
    public var isArchived: Bool
    public var privacy: Privacy
    /// Public link once the video is shared.
    public var shareURL: URL?

    public init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = .now,
        duration: Double,
        folder: String? = nil,
        isArchived: Bool = false,
        privacy: Privacy = .unlisted,
        shareURL: URL? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.folder = folder
        self.isArchived = isArchived
        self.privacy = privacy
        self.shareURL = shareURL
    }

    /// Default title from the recording date, e.g. « Vidéo du 24 oct. à 23:41 ».
    public static func defaultTitle(for date: Date, locale: Locale = Locale(identifier: "fr_FR")) -> String {
        let day = date.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(locale))
        return "Vidéo du \(day) à \(time)"
    }
}

/// The on-disk library, by default in ~/Movies/Reel.
public struct Library: Sendable {
    public let root: URL

    public init(root: URL = Library.defaultRoot) {
        self.root = root
    }

    /// `REEL_LIBRARY` points the app at another folder, for testing without touching the real library.
    public static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["REEL_LIBRARY"] { return URL(filePath: path, directoryHint: .isDirectory) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Reel", isDirectory: true)
    }

    public func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func videoURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("video.mp4") }
    public func workingDirectory(for id: UUID) -> URL { folder(for: id).appendingPathComponent("segments", isDirectory: true) }
    private func metadataURL(for id: UUID) -> URL { folder(for: id).appendingPathComponent("item.json") }

    public func save(_ item: VideoItem) throws {
        try FileManager.default.createDirectory(at: folder(for: item.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(item).write(to: metadataURL(for: item.id), options: .atomic)
    }

    /// Every readable item, newest first. Unreadable folders are skipped.
    public func items() -> [VideoItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? Data(contentsOf: $0.appendingPathComponent("item.json")) }
            .compactMap { try? decoder.decode(VideoItem.self, from: $0) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Removes the segment files once the final video exists.
    public func discardSegments(for id: UUID) {
        try? FileManager.default.removeItem(at: workingDirectory(for: id))
    }
}
