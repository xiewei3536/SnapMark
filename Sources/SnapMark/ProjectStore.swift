import AppKit
import CryptoKit
import ImageIO

/// Keeps annotated captures re-editable. Whenever SnapMark writes an image that has annotations, it
/// also stores the untouched base image and the annotation list, keyed by a hash of the file it
/// wrote. Opening that file in the editor again brings the annotations back as live objects that can
/// be moved, stretched, restyled, undone or removed — the original pixels are never lost.
///
/// Files edited by other apps no longer match their hash and simply open as plain images.
enum ProjectStore {
    struct Document: Codable {
        var version = 1
        var scale: CGFloat
        var badgeCounter: Int
        var annotations: [Annotation]
        var created = Date()
    }

    /// What an annotated save needs to stay editable.
    struct Source {
        let base: CGImage
        let scale: CGFloat
        let annotations: [Annotation]
        let badgeCounter: Int
    }

    private static let keepCount = 200

    /// The self-test keeps its projects out of the real store.
    static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapMark/Projects", isDirectory: true)
    }

    static func key(for fileData: Data) -> String {
        SHA256.hash(data: fileData).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Records `source` for the image file whose bytes are `fileData`.
    static func save(fileData: Data, source: Source) {
        guard !source.annotations.isEmpty, let png = source.base.pngData() else { return }
        let key = key(for: fileData)
        let dir = directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let doc = Document(scale: source.scale, badgeCounter: source.badgeCounter, annotations: source.annotations)
            try png.write(to: dir.appendingPathComponent("\(key).png"), options: .atomic)
            try JSONEncoder().encode(doc).write(to: dir.appendingPathComponent("\(key).json"), options: .atomic)
        } catch {
            NSLog("SnapMark: could not store editable annotations: \(error)")
            return
        }
        prune()
    }

    /// The base image and annotations behind an image file SnapMark wrote, if it has them.
    static func load(fileData: Data) -> (image: CapturedImage, document: Document)? {
        let key = key(for: fileData)
        let dir = directory
        guard let json = try? Data(contentsOf: dir.appendingPathComponent("\(key).json")),
              let doc = try? JSONDecoder().decode(Document.self, from: json),
              let src = CGImageSourceCreateWithURL(dir.appendingPathComponent("\(key).png") as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { return nil }
        return (CapturedImage(cgImage: base, scale: max(1, doc.scale)), doc)
    }

    /// Keeps the store bounded: only the most recent projects are kept.
    private static func prune() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let docs = files.filter { $0.pathExtension == "json" }
        guard docs.count > keepCount else { return }
        let sorted = docs.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for doc in sorted.dropFirst(keepCount) {
            try? fm.removeItem(at: doc)
            try? fm.removeItem(at: doc.deletingPathExtension().appendingPathExtension("png"))
        }
    }
}
