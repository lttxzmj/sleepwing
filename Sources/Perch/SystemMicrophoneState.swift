import CoreAudio
import Foundation

/// Whether any process is currently capturing from the default input
/// device. Spoken announcements during a live call are the worst kind of
/// interruption this product can make (the whole meeting hears the pet),
/// so voice yields whenever a call is plausibly in progress. Queried at
/// announcement time only — no polling, no state.
enum SystemMicrophoneState {
    static func inputRunningSomewhere() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        var runningSize = UInt32(MemoryLayout<UInt32>.size)
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            deviceID, &runningAddress, 0, nil, &runningSize, &running
        ) == noErr else { return false }
        return running != 0
    }
}
