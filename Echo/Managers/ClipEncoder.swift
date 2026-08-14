import AVFoundation
import CoreVideo
import SwiftUI
import UIKit

/// JPEG frame sequence → H.264 MP4 with the shooter's HUD baked in and the
/// app sounds reconstructed as a real audio track — what the public gallery
/// plays. The HUD chrome is `ClipOverlayView` — the same SwiftUI view the
/// spectator feed and in-app review draw — rasterized per frame, so the
/// gallery can't drift from what the app shows. Runs off-main apart from
/// those rasterizations; hardware-encoded, so a 40-frame clip takes about a
/// second on Apple Silicon / A-series.
enum ClipEncoder {
    static let framesPerSecond = Int32(AimCameraManager.clipFramesPerSecond)   // matches the capture cadence by construction

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
            // 3 Mbps is generous for 720×1280 at this cadence — the source
            // JPEGs are the quality ceiling, and 7 s still lands ~2.7 MB,
            // inside the upload proxy's 4.5 MB body limit.
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 3_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: Int(framesPerSecond) * 2,   // a keyframe every 2 s
            ],
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

        let pixelSize = CGSize(width: firstImage.width, height: firstImage.height)
        for (index, jpeg) in frames.enumerated() {
            let overlay = overlays.indices.contains(index) ? overlays[index] : nil
            let clipTime = Double(index) / Double(framesPerSecond)
            let hasLiveMarker = markers.contains {
                clipTime - $0.offset >= 0 && clipTime - $0.offset < ClipMarkerEvent.duration
            }
            // ImageRenderer is main-actor-only; hop over per frame so at most
            // one rasterized overlay is ever in flight (a whole clip's worth
            // up front would be hundreds of MB of BGRA).
            var chrome: CGImage?
            if overlay != nil || hasLiveMarker {
                DispatchQueue.main.sync {
                    chrome = MainActor.assumeIsolated {
                        renderChrome(overlay: overlay, markers: markers,
                                     clipTime: clipTime, pixelSize: pixelSize)
                    }
                }
            }
            guard let cgImage = composited(jpeg, chrome: chrome),
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

    // MARK: - Overlay compositing (the replay's SwiftUI chrome, rasterized)

    /// Reference width, in points, the chrome is laid out at before scaling up
    /// to the frame's pixels — phone-screen scale, so hearts, crosshair, and
    /// markers keep the proportions the live HUD and in-app replay show.
    private static let chromeLogicalWidth: CGFloat = 360

    /// One frame's HUD chrome — the same `ClipOverlayView` the spectator feed
    /// and in-app review draw — rendered transparent at the camera frame's
    /// pixel size, ready to composite.
    @MainActor
    private static func renderChrome(overlay: SpectatorOverlayState?, markers: [ClipMarkerEvent],
                                     clipTime: TimeInterval, pixelSize: CGSize) -> CGImage? {
        guard pixelSize.width > 0 else { return nil }
        let scale = pixelSize.width / chromeLogicalWidth
        let logical = CGSize(width: chromeLogicalWidth, height: pixelSize.height / scale)
        let renderer = ImageRenderer(content:
            ClipOverlayView(overlay: overlay, markers: markers, clipTime: clipTime,
                            fit: CGRect(origin: .zero, size: logical))
                .frame(width: logical.width, height: logical.height))
        renderer.scale = scale
        return renderer.cgImage
    }

    private static func composited(_ jpeg: Data, chrome: CGImage?) -> CGImage? {
        guard let base = UIImage(data: jpeg) else { return nil }
        guard let chrome else { return base.cgImage }   // nothing to draw — skip the re-render
        let size = base.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: size))
            UIImage(cgImage: chrome).draw(in: CGRect(origin: .zero, size: size))
        }
        return image.cgImage
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

        // AAC straight from the mixer: both tracks arrive at the mux already
        // mp4-ready, so it can copy samples instead of re-encoding.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("killcam-audio-\(UUID().uuidString).m4a")
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(totalSamples))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(totalSamples)
        mix.withUnsafeBufferPointer { source in
            buffer.floatChannelData!.pointee.update(from: source.baseAddress!, count: totalSamples)
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
        return url
    }

    /// Video + audio → one browser-playable MP4. Both tracks arrive mp4-ready
    /// (H.264 from the writer, AAC from the mixer), so passthrough muxing
    /// copies samples and the budgeted video bitrate survives untouched — no
    /// second generation loss. Falls back to a re-encoding preset on the rare
    /// combination passthrough can't copy. Cleans up both inputs.
    private static func mux(video: URL, audio: URL,
                            completion: @escaping (Result<URL, Error>) -> Void) {
        exportMux(video: video, audio: audio, preset: AVAssetExportPresetPassthrough) { first in
            switch first {
            case .success:
                try? FileManager.default.removeItem(at: video)
                try? FileManager.default.removeItem(at: audio)
                completion(first)
            case .failure:
                exportMux(video: video, audio: audio,
                          preset: AVAssetExportPresetHighestQuality) { second in
                    try? FileManager.default.removeItem(at: video)
                    try? FileManager.default.removeItem(at: audio)
                    completion(second)
                }
            }
        }
    }

    private static func exportMux(video: URL, audio: URL, preset: String,
                                  completion: @escaping (Result<URL, Error>) -> Void) {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        Task {
            do {
                guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                      let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
                      let compVideo = composition.addMutableTrack(withMediaType: .video,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid),
                      let compAudio = composition.addMutableTrack(withMediaType: .audio,
                                                                  preferredTrackID: kCMPersistentTrackID_Invalid)
                else { return completion(.failure(EncodeError.writerFailed)) }
                let videoDuration = try await videoAsset.load(.duration)
                try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration),
                                              of: videoTrack, at: .zero)
                let audioDuration = min(try await audioAsset.load(.duration), videoDuration)
                try compAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration),
                                              of: audioTrack, at: .zero)
            } catch { return completion(.failure(error)) }

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("killcam-final-\(UUID().uuidString).mp4")
            guard let export = AVAssetExportSession(asset: composition, presetName: preset)
            else { return completion(.failure(EncodeError.writerFailed)) }
            export.outputURL = out
            export.outputFileType = .mp4
            // AVAssetExportSession predates Sendable and its iOS 17 API reads
            // status/error inside the completion handler by design. The session
            // is owned solely by this closure after the call, so the capture is
            // race-free; the Sendable-clean replacement (export(to:as:)) is iOS 18+.
            nonisolated(unsafe) let session = export
            session.exportAsynchronously {
                if session.status == .completed {
                    completion(.success(out))
                } else {
                    completion(.failure(session.error ?? EncodeError.writerFailed))
                }
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
