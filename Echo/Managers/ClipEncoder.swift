import AVFoundation
import CoreVideo
import UIKit

/// JPEG frame sequence → H.264 MP4, for publishing killcams to the web
/// gallery. Runs off-main; hardware-encoded via AVAssetWriter, so a 40-frame
/// clip takes well under a second on Apple Silicon / A-series.
enum ClipEncoder {
    static let framesPerSecond: Int32 = 8   // matches the capture cadence

    enum EncodeError: Error {
        case noFrames, badFrame, writerFailed
    }

    /// Encodes on a utility queue; completion hops back to main with the
    /// temp-file URL of the finished MP4.
    static func encodeMP4(frames: [Data], completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try encodeSync(frames: frames) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func encodeSync(frames: [Data]) throws -> URL {
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
            guard let cgImage = UIImage(data: jpeg)?.cgImage,
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
