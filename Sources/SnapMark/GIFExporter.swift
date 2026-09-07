import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// Converts a recorded video into an animated GIF (capped at 60 s).
enum GIFExporter {
    static func export(videoURL: URL, to gifURL: URL, fps: Int, maxWidth: CGFloat,
                       progress: @escaping @Sendable (Double) -> Void,
                       completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        Task.detached(priority: .userInitiated) {
            do {
                let url = try await exportAsync(videoURL: videoURL, to: gifURL, fps: fps,
                                                maxWidth: maxWidth, progress: progress)
                completion(.success(url))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func exportAsync(videoURL: URL, to gifURL: URL, fps: Int, maxWidth: CGFloat,
                                    progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration > 0 else { throw CaptureError.failed }
        let clipped = min(duration, 60)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)

        let frameCount = max(1, Int(clipped * Double(fps)))
        let delay = 1.0 / Double(fps)

        try? FileManager.default.removeItem(at: gifURL)
        guard let dest = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString,
                                                         frameCount, nil) else {
            throw CaptureError.failed
        }
        let fileProps: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ]

        for i in 0..<frameCount {
            let t = CMTime(seconds: Double(i) * delay, preferredTimescale: 600)
            if let frame = try? await generator.image(at: t) {
                CGImageDestinationAddImage(dest, frame.image, frameProps as CFDictionary)
            }
            progress(Double(i + 1) / Double(frameCount))
        }

        guard CGImageDestinationFinalize(dest) else { throw CaptureError.failed }
        return gifURL
    }
}
