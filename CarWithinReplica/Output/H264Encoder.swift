import Foundation
import VideoToolbox
import CoreVideo

/// VideoToolbox H.264 编码，输出 Annex-B。仅供仪表输出链路使用。
final class H264Encoder {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    var onFrame: ((Data, Bool) -> Void)?

    init?(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = Int32(width)
        self.height = Int32(height)

        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
        ]

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: self.width,
            height: self.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created)

        guard status == noErr, let session = created else { return nil }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: fps * 2))
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ buffer: CVPixelBuffer, ptsMS: Int64) {
        guard let session else { return }
        var flags: VTEncodeInfoFlags = []
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: buffer,
            presentationTimeStamp: CMTime(value: ptsMS, timescale: 1000),
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: &flags
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.handle(sample)
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    // MARK: - 私有

    private func handle(_ sample: CMSampleBuffer) {
        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first {
            keyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return }
        var total = 0
        var pointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &total, dataPointerOut: &pointer)
        guard status == kCMBlockBufferNoErr, let pointer, total > 0 else { return }

        var output = Data()
        if keyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            output.append(parameterSets(format))
        }

        var raw = Data(bytes: pointer, count: total)
        while raw.count >= 4 {
            let size = Int(raw.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian })
            raw.removeFirst(4)
            guard size > 0, raw.count >= size else { break }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(raw.prefix(size))
            raw.removeFirst(size)
        }
        if !output.isEmpty {
            onFrame?(output, keyframe)
        }
    }

    private func parameterSets(_ format: CMFormatDescription) -> Data {
        var output = Data()
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)

        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if status == noErr, let pointer, size > 0 {
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(pointer, count: size)
            }
        }
        return output
    }
}

/// 生成 1024×600 的 YUV 测试画面：整幅渐变 + 一条横扫亮条，静止/活动一眼可辨。
enum TestPattern {
    static func makeBuffer(width: Int, height: Int, frame: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let plane = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                let level = UInt8(16 + (row * 219) / max(1, height))
                memset(plane + row * stride, Int32(level), width)
            }
            let barWidth = max(24, width / 21)
            let origin = (frame * 7) % max(1, width - barWidth)
            for row in 0..<height {
                memset(plane + row * stride + origin, 235, barWidth)
            }
        }

        if let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let plane = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<(height / 2) {
                memset(plane + row * stride, 128, width)
            }
        }

        return pixelBuffer
    }
}
