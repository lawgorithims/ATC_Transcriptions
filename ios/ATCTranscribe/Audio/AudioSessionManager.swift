import Foundation
import AVFoundation

/// Owns the shared `AVAudioSession`. An audio session must stay **active** for the app to keep
/// running once it's backgrounded (the `audio` UIBackgroundMode is declared in Info.plist) — so
/// transcription continues when the user leaves the app, the way audio playback keeps going.
///
/// Activated for every live source from `AppModel.start()` and torn down in `stop()`:
///  - **mic / USB** → `.playAndRecord`: capture continues reliably in the background.
///  - **internet feed / replay** → `.playback`: holds a session (and avoids a needless mic
///    prompt for feed-only users). Background continuation here is best-effort across long
///    suspensions — verify on a device.
enum AudioSessionManager {
    /// Configure + activate the session for the given source. `recording` selects the capture
    /// category; `preferUSB` routes to a USB interface when present.
    static func activate(recording: Bool, preferUSB: Bool = false) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if recording {
            try? session.setCategory(.playAndRecord, mode: .measurement,
                                     options: [.allowBluetooth, .defaultToSpeaker])
        } else {
            try? session.setCategory(.playback, mode: .default)
        }
        try? session.setActive(true)
        guard recording else { return }
        if preferUSB, let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
            try? session.setPreferredInput(usb)
        } else if !preferUSB, let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(mic)
        }
        #endif
    }

    /// Release the session when capture stops, letting other apps' audio resume.
    static func deactivate() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        #endif
    }
}
