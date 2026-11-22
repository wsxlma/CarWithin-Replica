import Foundation
import AudioToolbox
import AVFoundation

/// CarPlay 音频通路：接收 AAC-LC/Opus 字节流，解码成 PCM 播放。
/// 目前实现 AAC-LC（ADTS 帧）；Opus 需要额外解码库，先记录跳过。
final class AudioSink {
    static let shared = AudioSink()

    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "carwithin.audio")
    private var pending = Data()
    private var converter: AudioConverterRef?
    private var sourceFormat = AudioStreamBasicDescription()
    private var destinationFormat = AudioStreamBasicDescription()
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            engine.attach(player)
            let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.prepare()
            try engine.start()
            player.play()
            onLog?("音频输出已启动（44100 Hz / 2 声道）")
        } catch {
            onLog?("音频启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        engine.stop()
        player.stop()
        converter.map { AudioConverterDispose($0) }
        converter = nil
        started = false
    }

    func feed(_ data: Data) {
        queue.async { [weak self] in self?.consume(data) }
    }

    // MARK: - ADTS 帧

    private func consume(_ data: Data) {
        pending.append(data)
        while let frame = nextADTSFrame() {
            decodeAAC(frame)
        }
        if pending.count > 4_000_000 { pending.removeAll() }
    }

    private func nextADTSFrame() -> Data? {
        let bytes = [UInt8](pending)
        var index = 0
        while index + 7 < bytes.count {
            if bytes[index] == 0xFF, (bytes[index + 1] & 0xF0) == 0xF0 {
                let length = (Int(bytes[index + 3] & 0x03) << 11)
                    | (Int(bytes[index + 4]) << 3)
                    | (Int(bytes[index + 5] & 0xE0) >> 5)
                guard length > 7, index + length <= bytes.count else {
                    if length <= 7 { index += 1; continue }
                    return nil
                }
                let frame = Data(bytes[index..<(index + length)])
                pending = Data(bytes[(index + length)...])
                return frame
            }
            index += 1
        }
        if index > 0 { pending = Data(bytes[index...]) }
        return nil
    }

    // MARK: - AAC 解码

    private func decodeAAC(_ adts: Data) {
        if converter == nil { setupConverter(adts) }
        guard let converter else {
            onLog?("AAC 解码器未就绪，跳过 \(adts.count)B")
            return
        }

        let state = InputState(data: adts)
        let statePointer = Unmanaged.passUnretained(state).toOpaque()

        let bufferSize = 16384
        var output = [UInt8](repeating: 0, count: bufferSize)
        let status = output.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            var outputList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(bufferSize),
                    mData: buffer.baseAddress))
            var outputSize = UInt32(bufferSize)
            return AudioConverterFillComplexBuffer(
                converter,
                audioConverterInput,
                statePointer,
                &outputSize,
                &outputList,
                nil)
        }
        guard status == noErr else {
            onLog?("AAC 解码失败：\(status)")
            return
        }
        play(buffer: output, size: Int(bufferSize))
    }

    private func setupConverter(_ adts: Data) {
        let bytes = [UInt8](adts)
        guard bytes.count > 7 else { return }
        let sampleRateIndex = (bytes[2] >> 2) & 0x0F
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                     16000, 12000, 11025, 8000, 7350, 0, 0, 0]
        let sampleRate = Double(rates[Int(sampleRateIndex)])
        let channelConfig = ((bytes[2] & 0x01) << 2) | ((bytes[3] >> 6) & 0x03)

        var input = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(Int(channelConfig), 1)),
            mBitsPerChannel: 0,
            mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: UInt32(max(Int(channelConfig), 1)),
            mBitsPerChannel: 32,
            mReserved: 0)
        sourceFormat = input
        destinationFormat = output

        var created: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &created)
        guard status == noErr, let created else {
            onLog?("AAC 转换器创建失败：\(status)")
            return
        }
        converter = created
        onLog?("AAC 解码器已就绪（\(Int(sampleRate)) Hz / \(channelConfig) 声道）")
    }

    private func play(buffer: [UInt8], size: Int) {
        guard started, let format = AVAudioFormat(standardFormatWithSampleRate: destinationFormat.mSampleRate,
                                                  channels: Int(destinationFormat.mChannelsPerFrame)) else { return }
        let capacity = AVAudioFrameCount(size / Int(destinationFormat.mBytesPerFrame))
        guard capacity > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        pcm.frameLength = capacity
        if let channel = pcm.floatChannelData {
            buffer.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: Float.self)
                let frames = Int(capacity)
                for channelIndex in 0..<Int(destinationFormat.mChannelsPerFrame) {
                    let target = channel[channelIndex]
                    for frame in 0..<frames {
                        target[frame] = source[frame * Int(destinationFormat.mChannelsPerFrame) + channelIndex]
                    }
                }
            }
        }
        player.scheduleBuffer(pcm, completionHandler: nil)
    }
}

/// AudioConverter 输入回调上下文。
private final class InputState {
    let data: Data
    var sent = false
    var packetDescription: AudioStreamPacketDescription

    init(data: Data) {
        self.data = data
        self.packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(data.count))
    }
}

private func audioConverterInput(
    _ converter: AudioConverterRef,
    _ packets: UnsafeMutablePointer<UInt32>,
    _ bufferList: UnsafeMutablePointer<AudioBufferList>,
    _ description: UnsafeMutablePointer<AudioStreamPacketDescription>?,
    _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData else { return -1 }
    let state = Unmanaged<InputState>.fromOpaque(userData).takeUnretainedValue()
    if state.sent {
        packets.pointee = 0
        return noErr
    }
    state.data.withUnsafeBytes { raw in
        bufferList.pointee.mNumberBuffers = 1
        bufferList.pointee.mBuffers.mNumberChannels = 2
        bufferList.pointee.mBuffers.mDataByteSize = UInt32(state.data.count)
        bufferList.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: raw.baseAddress!)
    }
    packets.pointee = 1
    description?.pointee = state.packetDescription
    state.sent = true
    return noErr
}
