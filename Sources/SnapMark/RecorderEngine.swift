import AppKit
import AVFoundation
import Combine
import ScreenCaptureKit

/// Screen/region video recorder built on ScreenCaptureKit + AVAssetWriter.
final class RecorderEngine: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let shared = RecorderEngine()

    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var outputURL: URL?
    private var timer: Timer?
    private var startDate: Date?
    private var stopping = false
    private let sampleQueue = DispatchQueue(label: "snapmark.recorder.samples")

    var onFinish: ((URL?) -> Void)?

    // MARK: - Start

    @MainActor
    func start(screen: NSScreen, localRect: CGRect?) async {
        guard !isRecording else { return }
        let settings = Settings.shared

        if settings.captureMicrophone {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { NSLog("SnapMark: microphone access denied") }
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let displayID = ScreenMath.displayID(of: screen)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw CaptureError.displayNotFound
            }
            let ourApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: ourApp, exceptingWindows: [])

            let scale = screen.backingScaleFactor
            let config = SCStreamConfiguration()
            var pixelW: Int
            var pixelH: Int
            if let rect = localRect {
                config.sourceRect = rect
                pixelW = Int(rect.width * scale)
                pixelH = Int(rect.height * scale)
            } else {
                pixelW = Int(CGFloat(display.width) * scale)
                pixelH = Int(CGFloat(display.height) * scale)
            }
            // Encoders want even dimensions.
            pixelW -= pixelW % 2
            pixelH -= pixelH % 2
            config.width = pixelW
            config.height = pixelH
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(5, settings.frameRate)))
            config.showsCursor = settings.showCursorInRecording
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB
            config.queueDepth = 8
            if settings.captureSystemAudio {
                config.capturesAudio = true
                config.sampleRate = 48000
                config.channelCount = 2
            }
            if #available(macOS 15.0, *), settings.captureMicrophone {
                config.captureMicrophone = true
            }

            let url = settings.nextFileURL(ext: settings.videoFormat.rawValue)
            try setUpWriter(url: url, width: pixelW, height: pixelH, settings: settings)

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            if settings.captureSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
            }
            if #available(macOS 15.0, *), settings.captureMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
            }
            try await stream.startCapture()

            self.stream = stream
            self.outputURL = url
            self.stopping = false
            self.isRecording = true
            self.elapsed = 0
            self.startDate = Date()
            self.timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
            RunLoop.main.add(self.timer!, forMode: .common)
        } catch {
            NSLog("SnapMark: failed to start recording: \(error)")
            cleanupWriter()
            AppCoordinator.shared.showPermissionAlertIfNeeded()
            Toast.show(icon: "exclamationmark.triangle.fill", text: L("toast.record_failed"))
        }
    }

    private func setUpWriter(url: URL, width: Int, height: Int, settings: Settings) throws {
        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = settings.videoFormat == .mp4 ? .mp4 : .mov
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        let codec: AVVideoCodecType = settings.videoCodec == .hevc ? .hevc : .h264
        let bitsPerPixel: Double = settings.videoCodec == .hevc ? 0.07 : 0.11
        let bitrate = max(2_000_000, Int(Double(width * height * settings.frameRate) * bitsPerPixel))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: settings.frameRate,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000,
        ]
        if settings.captureSystemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            systemAudioInput = input
        }
        if #available(macOS 15.0, *), settings.captureMicrophone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            micInput = input
        }

        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.failed
        }
        self.writer = writer
        self.videoInput = videoInput
        self.sessionStarted = false
    }

    // MARK: - Stop

    @MainActor
    func stop(discard: Bool = false) {
        guard isRecording, !stopping else { return }
        stopping = true
        timer?.invalidate()
        timer = nil
        let stream = self.stream
        Task {
            try? await stream?.stopCapture()
            self.sampleQueue.async {
                self.finishWriting(discard: discard)
            }
        }
    }

    private func finishWriting(discard: Bool) {
        let url = outputURL
        videoInput?.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        let writer = self.writer
        let finish = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cleanupWriter()
                self.isRecording = false
                if discard {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    self.onFinish?(nil)
                } else {
                    Sounds.playDone()
                    self.onFinish?(url)
                }
            }
        }
        if let writer, writer.status == .writing, sessionStarted {
            writer.finishWriting(completionHandler: finish)
        } else {
            writer?.cancelWriting()
            if let url { try? FileManager.default.removeItem(at: url) }
            DispatchQueue.main.async {
                self.cleanupWriter()
                self.isRecording = false
                self.onFinish?(nil)
            }
        }
    }

    private func cleanupWriter() {
        stream = nil
        writer = nil
        videoInput = nil
        systemAudioInput = nil
        micInput = nil
        sessionStarted = false
        startDate = nil
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, writer.status == .writing, !stopping || sessionStarted else { return }

        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  statusRaw == SCFrameStatus.complete.rawValue
            else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if !sessionStarted {
                writer.startSession(atSourceTime: pts)
                sessionStarted = true
            }
            if videoInput?.isReadyForMoreMediaData == true {
                videoInput?.append(sampleBuffer)
            }
        case .audio:
            guard sessionStarted, systemAudioInput?.isReadyForMoreMediaData == true else { return }
            systemAudioInput?.append(sampleBuffer)
        default:
            if #available(macOS 15.0, *), type == .microphone {
                guard sessionStarted, micInput?.isReadyForMoreMediaData == true else { return }
                micInput?.append(sampleBuffer)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            if self.isRecording && !self.stopping {
                NSLog("SnapMark: stream stopped with error: \(error)")
                self.stop()
            }
        }
    }
}
