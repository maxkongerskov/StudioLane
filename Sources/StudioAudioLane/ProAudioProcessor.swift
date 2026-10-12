import AudioToolbox
import Foundation
import MediaToolbox

private final class ProAudioTapContext {
    let pan: Float
    let limiterEnabled: Bool
    var format = AudioStreamBasicDescription()

    init(pan: Float, limiterEnabled: Bool) {
        self.pan = min(max(pan, -1), 1)
        self.limiterEnabled = limiterEnabled
    }
}

enum ProAudioProcessor {
    static func makeTap(pan: Float, limiterEnabled: Bool) -> MTAudioProcessingTap? {
        let context = ProAudioTapContext(pan: pan, limiterEnabled: limiterEnabled)
        let retainedContext = Unmanaged.passRetained(context)
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retainedContext.toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                let pointer = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<ProAudioTapContext>.fromOpaque(pointer).release()
            },
            prepare: { tap, _, processingFormat in
                let pointer = MTAudioProcessingTapGetStorage(tap)
                Unmanaged<ProAudioTapContext>.fromOpaque(pointer)
                    .takeUnretainedValue()
                    .format = processingFormat.pointee
            },
            unprepare: { _ in },
            process: { tap, frameCount, flags, bufferList, framesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap,
                    frameCount,
                    bufferList,
                    flagsOut,
                    nil,
                    framesOut
                )
                guard status == noErr else {
                    framesOut.pointee = 0
                    return
                }
                let pointer = MTAudioProcessingTapGetStorage(tap)
                let context = Unmanaged<ProAudioTapContext>.fromOpaque(pointer).takeUnretainedValue()
                ProAudioProcessor.process(
                    bufferList: bufferList,
                    frameCount: framesOut.pointee,
                    format: context.format,
                    pan: context.pan,
                    limiterEnabled: context.limiterEnabled
                )
                _ = flags
            }
        )
        var unmanagedTap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &unmanagedTap
        )
        guard status == noErr, let unmanagedTap else {
            retainedContext.release()
            return nil
        }
        return unmanagedTap.takeRetainedValue()
    }

    private static func process(
        bufferList: UnsafeMutablePointer<AudioBufferList>,
        frameCount: CMItemCount,
        format: AudioStreamBasicDescription,
        pan: Float,
        limiterEnabled: Bool
    ) {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return }
        let gains = ProFeatureMath.equalPowerPan(pan)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        for (bufferIndex, buffer) in buffers.enumerated() {
            guard let data = buffer.mData else { continue }
            let sampleCount = min(
                Int(buffer.mDataByteSize) / MemoryLayout<Float>.size,
                Int(frameCount) * max(1, Int(buffer.mNumberChannels))
            )
            let samples = data.assumingMemoryBound(to: Float.self)
            for sampleIndex in 0..<sampleCount {
                let channel: Int
                if nonInterleaved {
                    channel = bufferIndex
                } else {
                    channel = sampleIndex % max(1, Int(buffer.mNumberChannels))
                }
                let channelGain: Float = channel == 0 ? gains.left : gains.right
                samples[sampleIndex] = ProFeatureMath.limitedSample(
                    samples[sampleIndex] * channelGain,
                    enabled: limiterEnabled
                )
            }
        }
    }
}
