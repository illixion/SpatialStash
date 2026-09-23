/*
 Hypnos - how long rendered audio takes to reach the ears

 The picture is scheduled this much after the instant the audio renders a
 frame, so the two arrive together. Only the platform's figure for the
 output route is known here; what RealityKit adds on top is not reported
 anywhere, which is what `FilmPlayer.avOffsetMs` is for.
 */

import AVFoundation
#if os(macOS)
import CoreAudio
#endif

public enum AudioOutputLatency {
    /// Seconds from render to output on the current route.
    public static func current() -> Double {
        #if os(macOS)
        return defaultOutputDeviceLatency()
        #else
        let session = AVAudioSession.sharedInstance()
        return session.outputLatency + session.ioBufferDuration
        #endif
    }

    #if os(macOS)
    /// The default output device's latency, safety offset and buffer, plus
    /// its first output stream's latency.
    private static func defaultOutputDeviceLatency() -> Double {
        var device = AudioDeviceID(0)
        guard property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                       scope: kAudioObjectPropertyScopeGlobal, into: &device) else { return 0 }
        var rate = Float64(0)
        guard property(device, kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal, into: &rate),
              rate > 0 else { return 0 }
        var latency = UInt32(0), safety = UInt32(0), buffer = UInt32(0)
        _ = property(device, kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput, into: &latency)
        _ = property(device, kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput, into: &safety)
        _ = property(device, kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal, into: &buffer)

        var streamLatency = UInt32(0)
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let first = streams.first {
                _ = property(first, kAudioStreamPropertyLatency, scope: kAudioObjectPropertyScopeGlobal, into: &streamLatency)
            }
        }
        return Double(latency + safety + buffer + streamLatency) / rate
    }

    private static func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope, into value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }
    #endif
}
