import AppKit

/// Tracks recent captures for the status-bar "Recent" submenu.
final class HistoryManager {
    static let shared = HistoryManager()

    enum Kind: String, Codable { case image, video }

    struct Entry: Codable {
        let path: String
        let kind: Kind
        let date: Date
        var url: URL { URL(fileURLWithPath: path) }
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 12
    private let storeURL: URL

    var onChange: (() -> Void)?

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapMark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storeURL = dir.appendingPathComponent("history.json")
        load()
    }

    func add(fileURL: URL, kind: Kind) {
        entries.removeAll { $0.path == fileURL.path }
        entries.insert(Entry(path: fileURL.path, kind: kind, date: Date()), at: 0)
        if entries.count > maxEntries { entries.removeLast(entries.count - maxEntries) }
        save()
        DispatchQueue.main.async { self.onChange?() }
    }

    /// Entries whose files still exist on disk.
    func validEntries() -> [Entry] {
        entries.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func thumbnail(for entry: Entry, height: CGFloat = 36) -> NSImage? {
        guard entry.kind == .image, let img = NSImage(contentsOf: entry.url) else { return nil }
        let ratio = img.size.height > 0 ? img.size.width / img.size.height : 1.6
        let size = CGSize(width: height * ratio, height: height)
        let thumb = NSImage(size: size)
        thumb.lockFocus()
        img.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: storeURL)
        }
    }
}
