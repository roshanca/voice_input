import Foundation
import AVFoundation
import CoreAudio

struct AudioInputDevice: Equatable, Identifiable {
    let uid: String
    let name: String
    let audioDeviceID: AudioDeviceID

    var id: String { uid }
}

enum AudioDeviceManager {
    /// All available audio input devices. "System Default" is represented by a nil UID
    /// at the call site, not by an entry here.
    static func inputDevices() -> [AudioInputDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.compactMap { device in
            guard let deviceID = audioDeviceID(forUID: device.uniqueID) else { return nil }
            return AudioInputDevice(uid: device.uniqueID, name: device.localizedName, audioDeviceID: deviceID)
        }
    }

    static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var uidCF = uid as CFString
        let status = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}
