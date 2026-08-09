import AVFoundation
import CoreVideo
import UIKit

/// JPEG frame sequence → H.264 MP4 with the shooter's HUD baked in and the
/// app sounds reconstructed as a real audio track — what the public gallery
/// plays. Runs off-main; hardware-encoded, so a 40-frame clip takes about a
/// second on Apple Silicon / A-series.
enum ClipEncoder {
    static let framesPerSecond: Int32 = 8   // matches the capture cadence

    enum EncodeError: Error {
        case noFrames, badFrame, writerFailed
    }

    /// Composites overlays into the frames, encodes video, mixes the sound
    /// events into an audio track, and muxes both. Completion hops to main
    /// with the temp-file URL of the finished MP4.
    static func encodeMP4(frames: [Data], overlays: [SpectatorOverlayState],
                          sounds: [ClipSoundEvent], markers: [ClipMarkerEvent],
                          completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let video = try encodeVideoSync(frames: frames, overlays: overlays, markers: markers)
                let duration = Double(frames.count) / Double(framesPerSecond)
                if let audio = try mixAudioWAV(sounds: sounds, duration: duration) {
                    mux(video: video, audio: audio) { result in
                        DispatchQueue.main.async { completion(result) }
                    }
                } else {
                    DispatchQueue.main.async { completion(.success(video)) }
                }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Video

    private static func encodeVideoSync(frames: [Data], overlays: [SpectatorOverlayState],
                                        markers: [ClipMarkerEvent]) throws -> URL {
        guard let first = frames.first, let firstImage = UIImage(data: first)?.cgImage else {
            throw EncodeError.noFrames
        }
        // H.264 wants even dimensions.
        let width = firstImage.width - firstImage.width % 2
        let height = firstImage.height - firstImage.height % 2

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("killcam-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else { throw EncodeError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        for (index, jpeg) in frames.enumerated() {
            let overlay = overlays.indices.contains(index) ? overlays[index] : nil
            let clipTime = Double(index) / Double(framesPerSecond)
            let liveMarkers = markers.filter {
                clipTime - $0.offset >= 0 && clipTime - $0.offset < ClipMarkerEvent.duration
            }
            guard let cgImage = composited(jpeg, overlay: overlay, markers: liveMarkers, at: clipTime),
                  let buffer = pixelBuffer(from: cgImage, width: width, height: height,
                                           pool: adaptor.pixelBufferPool) else {
                continue   // one bad frame shouldn't sink the clip
            }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            let time = CMTime(value: CMTimeValue(index), timescale: framesPerSecond)
            adaptor.append(buffer, withPresentationTime: time)
        }
        input.markAsFinished()

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? EncodeError.writerFailed }
        return url
    }

    // MARK: - Overlay compositing (mirrors the live HUD's look)

    private static func composited(_ jpeg: Data, overlay: SpectatorOverlayState?,
                                   markers: [ClipMarkerEvent], at clipTime: TimeInterval) -> CGImage? {
        guard let base = UIImage(data: jpeg) else { return nil }
        let size = base.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            base.draw(in: CGRect(origin: .zero, size: size))
            if let overlay {
                for tag in overlay.tags {
                    drawTag(name: tag.name, hp: CGFloat(tag.hp),
                            at: CGPoint(x: CGFloat(tag.x) * size.width,
                                        y: CGFloat(tag.y) * size.height - 40))
                }
                drawCrosshair(locked: overlay.lockedTarget, in: size, context: ctx.cgContext)
            }
            for marker in markers {
                drawMarker(marker, at: clipTime, in: size)
            }
        }
        return image.cgImage
    }

    /// The HUD's hit-marker art with its bloom-fade, sampled at this frame's
    /// point in the animation.
    private static func drawMarker(_ marker: ClipMarkerEvent, at clipTime: TimeInterval,
                                   in size: CGSize) {
        let artName = marker.isKill ? Art.hitMarkerKill.rawValue : Art.hitMarker.rawValue
        guard let art = UIImage(named: artName) else { return }
        let fade = min(1, max(0, (clipTime - marker.offset) / ClipMarkerEvent.duration))
        let baseSize: CGFloat = marker.isKill ? 22 : 16
        let drawSize = baseSize * (0.8 + 0.4 * fade)
        let tint: UIColor = marker.isKill
            ? UIColor(red: 0.94, green: 0.25, blue: 0.25, alpha: 1)
            : .white
        let rect = CGRect(x: size.width / 2 - drawSize / 2,
                          y: size.height / 2 - drawSize / 2,
                          width: drawSize, height: drawSize)
        art.withTintColor(tint, renderingMode: .alwaysOriginal)
            .draw(in: rect, blendMode: .normal, alpha: 1 - fade)
    }

    /// Approximations of the Theme tokens for offline drawing.
    private static let lockedColor = UIColor(red: 0.30, green: 0.90, blue: 0.22, alpha: 0.95)

    private static func healthColor(_ fraction: CGFloat) -> UIColor {
        fraction > 0.5 ? UIColor(red: 0.45, green: 0.96, blue: 0.66, alpha: 1)
        : fraction > 0.25 ? UIColor(red: 1.0, green: 0.8, blue: 0.2, alpha: 1)
        : UIColor(red: 0.94, green: 0.25, blue: 0.25, alpha: 1)
    }

    private static func drawTag(name: String, hp: CGFloat, at point: CGPoint) {
        let barWidth: CGFloat = 64
        let barHeight: CGFloat = 5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: UIColor.white.withAlphaComponent(0.9),
        ]
        let text = name.uppercased() as NSString
        let textSize = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: point.x - textSize.width / 2,
                              y: point.y - textSize.height - 3),
                  withAttributes: attributes)
        let barRect = CGRect(x: point.x - barWidth / 2, y: point.y,
                             width: barWidth, height: barHeight)
        UIColor.black.withAlphaComponent(0.4).setFill()
        UIBezierPath(roundedRect: barRect, cornerRadius: barHeight / 2).fill()
        let fillRect = CGRect(x: barRect.minX, y: barRect.minY,
                              width: barWidth * max(0, min(1, hp)), height: barHeight)
        healthColor(hp).setFill()
        UIBezierPath(roundedRect: fillRect, cornerRadius: barHeight / 2).fill()
    }

    private static func drawCrosshair(locked: String?, in size: CGSize, context: CGContext) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius: CGFloat = 26
        let color = locked != nil ? lockedColor : UIColor.white.withAlphaComponent(0.4)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(2)
        if locked != nil {
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2))
        }
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] as [(CGFloat, CGFloat)] {
            context.move(to: CGPoint(x: center.x + dx * 8, y: center.y + dy * 8))
            context.addLine(to: CGPoint(x: center.x + dx * (radius + 6),
                                        y: center.y + dy * (radius + 6)))
        }
        context.strokePath()
        if let locked {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .bold),
                .foregroundColor: color,
            ]
            let label = "LOCKED · \(locked.uppercased())" as NSString
            let labelSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: center.x - labelSize.width / 2, y: center.y + radius + 10),
                       withAttributes: attributes)
        }
    }

    // MARK: - Audio reconstruction

    /// Mixes the clip's sound events (bundled WAVs at their offsets, with
    /// volume and repitch applied) into one mono track; nil when silent.
    private static func mixAudioWAV(sounds: [ClipSoundEvent], duration: TimeInterval) throws -> URL? {
        guard !sounds.isEmpty else { return nil }
        let sampleRate: Double = 44100
        let totalSamples = Int((duration + 1.0) * sampleRate)   // 1 s tail for late sounds
        var mix = [Float](repeating: 0, count: totalSamples)
        var cache: [String: [Float]] = [:]

        for event in sounds {
            if cache[event.name] == nil {
                guard let url = SoundManager.shared.assetURL(event.name),
                      let file = try? AVAudioFile(forReading: url),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                    frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil,
                      let channel = buffer.floatChannelData
                else { continue }
                var samples = Array(UnsafeBufferPointer(start: channel[0],
                                                        count: Int(buffer.frameLength)))
                let fileRate = file.processingFormat.sampleRate
                if fileRate != sampleRate, fileRate > 0 {
                    let ratio = fileRate / sampleRate
                    samples = (0..<Int(Double(samples.count) / ratio)).map {
                        samples[min(samples.count - 1, Int(Double($0) * ratio))]
                    }
                }
                cache[event.name] = samples
            }
            guard let samples = cache[event.name], !samples.isEmpty else { continue }
            let start = Int(event.offset * sampleRate)
            let rate = Double(max(0.25, event.rate))
            let playedCount = Int(Double(samples.count) / rate)
            for i in 0..<playedCount {
                let target = start + i
                guard target >= 0, target < totalSamples else { break }
                let source = min(samples.count - 1, Int(Double(i) * rate))
                mix[target] += samples[source] * event.volume
            }
        }
        for i in 0..<totalSamples { mix[i] = max(-1, min(1, mix[i])) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("killcam-audio-\(UUID().uuidString).wav")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(totalSamples))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalSamples)
        mix.withUnsafeBufferPointer { source in
            buffer.floatChannelData!.pointee.update(from: source.baseAddress!, count: totalSamples)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    /// Video + audio → one browser-playable MP4 (AAC audio via the export
    /// session). Cleans up both inputs.
    private static func mux(video: URL, audio: URL,
                            completion: @escaping (Result<URL, Error>) -> Void) {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let videoTrack = videoAsset.tracks(withMediaType: .video).first,
              let audioTrack = audioAsset.tracks(withMediaType: .audio).first,
              let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid),
              let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return completion(.failure(EncodeError.writerFailed)) }
        do {
            try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoAsset.duration),
                                          of: videoTrack, at: .zero)
            let audioDuration = min(audioAsset.duration, videoAsset.duration)
            try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration),
                                          of: audioTrack, at: .zero)
        } catch { return completion(.failure(error)) }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("killcam-final-\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: composition,
                                                presetName: AVAssetExportPresetHighestQuality)
        else { return completion(.failure(EncodeError.writerFailed)) }
        export.outputURL = out
        export.outputFileType = .mp4
        export.exportAsynchronously {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: audio)
            if export.status == .completed {
                completion(.success(out))
            } else {
                completion(.failure(export.error ?? EncodeError.writerFailed))
            }
        }
    }

    private static func pixelBuffer(from image: CGImage, width: Int, height: Int,
                                    pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                                &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
