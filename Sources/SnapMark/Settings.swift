import AppKit
import Combine
import ServiceManagement

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var displayName: String { self == .png ? "PNG" : "JPEG" }
}

enum VideoFormat: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var displayName: String { rawValue.uppercased() }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var displayName: String { self == .h264 ? "H.264" : "HEVC (H.265)" }
}

enum AfterCaptureAction: String, CaseIterable, Identifiable {
    case openEditor, copyOnly, pin
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openEditor: return L("settings.after.editor")
        case .copyOnly: return L("settings.after.copy_only")
        case .pin: return L("settings.after.pin")
        }
    }
}

/// App-wide user preferences, persisted to UserDefaults.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    // MARK: General
    @Published var afterCapture: AfterCaptureAction { didSet { d.set(afterCapture.rawValue, forKey: "afterCapture") } }
    @Published var autoCopyToClipboard: Bool { didSet { d.set(autoCopyToClipboard, forKey: "autoCopy") } }
    @Published var autoSaveToDisk: Bool { didSet { d.set(autoSaveToDisk, forKey: "autoSave") } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: "playSound") } }
    @Published var showFloatingThumbnail: Bool { didSet { d.set(showFloatingThumbnail, forKey: "floatThumb") } }
    @Published var imageFormat: ImageFormat { didSet { d.set(imageFormat.rawValue, forKey: "imageFormat") } }
    @Published var jpegQuality: Double { didSet { d.set(jpegQuality, forKey: "jpegQuality") } }
    @Published var saveDirectoryPath: String { didSet { d.set(saveDirectoryPath, forKey: "saveDir") } }
    @Published var filenameTemplate: String { didSet { d.set(filenameTemplate, forKey: "filenameTemplate") } }
    @Published var showCursorInScreenshot: Bool { didSet { d.set(showCursorInScreenshot, forKey: "cursorShot") } }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            NSLog("SnapMark: launchAtLogin changed to \(launchAtLogin)")
            d.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
    }

    // MARK: Recording
    @Published var videoFormat: VideoFormat { didSet { d.set(videoFormat.rawValue, forKey: "videoFormat") } }
    @Published var videoCodec: VideoCodec { didSet { d.set(videoCodec.rawValue, forKey: "videoCodec") } }
    @Published var frameRate: Int { didSet { d.set(frameRate, forKey: "frameRate") } }
    @Published var captureSystemAudio: Bool { didSet { d.set(captureSystemAudio, forKey: "sysAudio") } }
    @Published var captureMicrophone: Bool { didSet { d.set(captureMicrophone, forKey: "micAudio") } }
    @Published var showCursorInRecording: Bool { didSet { d.set(showCursorInRecording, forKey: "cursorRec") } }
    @Published var countdownSeconds: Int { didSet { d.set(countdownSeconds, forKey: "countdown") } }

    private init() {
        afterCapture = AfterCaptureAction(rawValue: d.string(forKey: "afterCapture") ?? "") ?? .openEditor
        autoCopyToClipboard = d.object(forKey: "autoCopy") == nil ? true : d.bool(forKey: "autoCopy")
        autoSaveToDisk = d.object(forKey: "autoSave") == nil ? true : d.bool(forKey: "autoSave")
        playSound = d.object(forKey: "playSound") == nil ? true : d.bool(forKey: "playSound")
        showFloatingThumbnail = d.object(forKey: "floatThumb") == nil ? true : d.bool(forKey: "floatThumb")
        imageFormat = ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png
        jpegQuality = d.object(forKey: "jpegQuality") == nil ? 0.9 : d.double(forKey: "jpegQuality")
        saveDirectoryPath = d.string(forKey: "saveDir") ?? Settings.defaultSaveDirectory().path
        filenameTemplate = d.string(forKey: "filenameTemplate") ?? "SnapMark {date} at {time}"
        showCursorInScreenshot = d.bool(forKey: "cursorShot")
        launchAtLogin = d.bool(forKey: "launchAtLogin")
        videoFormat = VideoFormat(rawValue: d.string(forKey: "videoFormat") ?? "") ?? .mp4
        videoCodec = VideoCodec(rawValue: d.string(forKey: "videoCodec") ?? "") ?? .h264
        frameRate = d.object(forKey: "frameRate") == nil ? 30 : d.integer(forKey: "frameRate")
        captureSystemAudio = d.object(forKey: "sysAudio") == nil ? true : d.bool(forKey: "sysAudio")
        captureMicrophone = d.bool(forKey: "micAudio")
        showCursorInRecording = d.object(forKey: "cursorRec") == nil ? true : d.bool(forKey: "cursorRec")
        countdownSeconds = d.object(forKey: "countdown") == nil ? 3 : d.integer(forKey: "countdown")
    }

    static func defaultSaveDirectory() -> URL {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures")
        return pics.appendingPathComponent("SnapMark", isDirectory: true)
    }

    var saveDirectory: URL {
        let url = URL(fileURLWithPath: (saveDirectoryPath as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a capture file URL from the filename template.
    /// Tokens: {date} {time} {seq}
    func nextFileURL(ext: String) -> URL {
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let tf = DateFormatter()
        tf.dateFormat = "HH.mm.ss"
        let seq = d.integer(forKey: "fileSeq") + 1
        d.set(seq, forKey: "fileSeq")
        var name = filenameTemplate
            .replacingOccurrences(of: "{date}", with: df.string(from: now))
            .replacingOccurrences(of: "{time}", with: tf.string(from: now))
            .replacingOccurrences(of: "{seq}", with: String(format: "%04d", seq))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        if name.isEmpty { name = "SnapMark" }
        var url = saveDirectory.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = saveDirectory.appendingPathComponent("\(name) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    private func applyLaunchAtLogin() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("SnapMark: launch-at-login toggle failed: \(error)")
        }
    }
}
