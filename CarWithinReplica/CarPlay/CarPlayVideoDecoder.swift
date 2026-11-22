import Foundation
import VideoToolbox
import CoreVideo
import CoreMedia
import CoreImage
import UIKit

/// CarPlay 视频解码：把 iPhone 送来的 H.265/H.264 访问单元解码成图像。
/// 支持 Annex-B（00 00 01 起始码）与 4 字节长度前缀两种封装。
final class CarPlayVideoDecoder {
    var onFrame: ((Data) -> Void)?          // JPEG
    var onAccessUnit: ((Data, Bool) -> Void)? // 原始访问单元 + 是否关键帧
    var onLog: ((String) -> Void)?

    private var pending = Data()
    private var session: VTDecompressionSession?
    private var formatDescription: CMFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?
    private var frameIndex: Int64 = 0
    private let isHEVC: Bool
    private let ciContext = CIContext()

    init(codec: String) {
        isHEVC = codec.contains("265") || codec.contains("HEVC")
    }

    func feed(_ bytes: Data) {
        pending.append(bytes)
        drain()
    }

    func reset() {
        pending.removeAll()
        session.map { VTDecompressionSessionInvalidate($0) }
        session = nil
        formatDescription = nil
        sps = nil; pps = nil; vps = nil
    }

    // MARK: - 拆包

    private func drain() {
        guard pending.count >= 5 else { return }
        let bytes = [UInt8](pending)
        var starts: [(offset: Int, length: Int)] = []
        var i = 0
        while i + 3 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    starts.append((i, 3))
                    i += 3
                    continue
                }
                if i + 3 < bytes.count, bytes[i + 2] == 0, bytes[i + 3] == 1 {
                    starts.append((i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        if starts.count >= 2 {
            for index in 0..<(starts.count - 1) {
                let current = starts[index]
                let next = starts[index + 1]
                let from = current.offset + current.length
                var to = next.offset
                while to > from, bytes[to - 1] == 0 { to -= 1 }
                if to > from {
                    processNAL(Data(bytes[from..<to]))
                }
            }
            let last = starts.last!
            pending = Data(bytes[(last.offset)...])
        } else if starts.count == 1 {
            let start = starts[0]
            if start.offset > 0 {
                pending = Data(bytes[start.offset...])
            }
            if pending.count > 4_000_000 { pending.removeAll() }
        } else {
            drainLengthPrefixed()
        }
    }

    private func drainLengthPrefixed() {
        var consumed = 0
        let bytes = [UInt8](pending)
        while consumed + 4 <= bytes.count {
            let length = (Int(bytes[consumed]) << 24) | (Int(bytes[consumed + 1]) << 16)
                | (Int(bytes[consumed + 2]) << 8) | Int(bytes[consumed + 3])
            guard length > 0, length < 4_000_000, consumed + 4 + length <= bytes.count else { break }
            processNAL(Data(bytes[(consumed + 4)..<(consumed + 4 + length)]))
            consumed += 4 + length
        }
        if consumed > 0 { pending = Data(bytes[consumed...]) }
    }

    // MARK: - NAL 分类与解码

    private func processNAL(_ nal: Data) {
        guard nal.count >= 2 else { return }
        let first = nal[nal.startIndex]

        if isHEVC {
            let type = Int((first >> 1) & 0x3F)
            switch type {
            case 32: vps = nal
            case 33: sps = nal
            case 34: pps = nal
            default:
                onAccessUnit?(nal, type <= 21)
                if session == nil { configureHEVC() }
                decode(nal)
            }
        } else {
            let type = Int(first & 0x1F)
            switch type {
            case 7: sps = nal
            case 8: pps = nal
            default:
                onAccessUnit?(nal, type == 5)
                if session == nil { configureH264() }
                decode(nal)
            }
        }
    }

    private func configureHEVC() {
        guard let vps, let sps, let pps, formatDescription == nil else { return }
        var format: CMFormatDescription?
        let status = vps.withUnsafeBytes { vpsPtr in
            sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    var pointers: [UnsafePointer<UInt8>] = [
                        vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    var sizes = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format)
                }
            }
        }
        guard status == noErr, let format else {
            onLog?("HEVC 格式描述创建失败：\(status)")
            return
        }
        formatDescription = format
        createSession(format)
        onLog?("H.265 解码器已就绪")
    }

    private func configureH264() {
        guard let sps, let pps, formatDescription == nil else { return }
        var format: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                var pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                var sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else {
            onLog?("H.264 格式描述创建失败：\(status)")
            return
        }
        formatDescription = format
        createSession(format)
        onLog?("H.264 解码器已就绪")
    }

    private func createSession(_ format: CMFormatDescription) {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: carPlayDecodeCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque())
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &created)
        guard status == noErr, let created else {
            onLog?("解码会话创建失败：\(status)")
            return
        }
        session = created
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    }

    private func decode(_ nal: Data) {
        guard let session, let formatDescription else { return }
        var length = UInt32(nal.count).bigEndian
        var payload = withUnsafeBytes(of: &length) { Data($0) }
        payload.append(nal)

        let memory = UnsafeMutableRawPointer.allocate(byteCount: payload.count, alignment: 1)
        payload.withUnsafeBytes { raw in
            memory.copyMemory(from: raw.baseAddress!, byteCount: payload.count)
        }
        var blockBuffer: CMBlockBuffer?
        var blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: memory,
            blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            dataLength: payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard blockStatus == noErr, let blockBuffer else {
            memory.deallocate()
            return
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 60),
            decodeTimeStamp: .invalid)
        frameIndex += 1
        var sampleSize = payload.count
        var sampleBuffer: CMSampleBuffer?
        blockStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            offsetToData: 0,
            sampleBufferOut: &sampleBuffer)
        guard blockStatus == noErr, let sampleBuffer else { return }

        var flags = VTDecodeFrameFlags()
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: flags,
            frameRefcon: nil,
            infoFlagsOut: nil)
    }

    fileprivate func emit(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        let uiImage = UIImage(cgImage: cgImage)
        guard let jpeg = uiImage.jpegData(compressionQuality: 0.7) else { return }
        onFrame?(jpeg)
    }
}

private func carPlayDecodeCallback(
    _ refcon: UnsafeMutableRawPointer?,
    _ sourceFrameRefCon: UnsafeMutableRawPointer?,
    _ status: OSStatus,
    _ flags: VTDecodeInfoFlags,
    _ imageBuffer: CVImageBuffer?,
    _ presentationTimeStamp: CMTime,
    _ presentationDuration: CMTime) {
    guard status == noErr, let imageBuffer, let refcon else { return }
    let decoder = Unmanaged<CarPlayVideoDecoder>.fromOpaque(refcon).takeUnretainedValue()
    decoder.emit(imageBuffer)
}
