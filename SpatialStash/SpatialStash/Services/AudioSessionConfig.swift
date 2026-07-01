/*
 Spatial Stash - Audio Session Configuration

 Central audio-session setup. The app uses a mixable playback category so its
 videos never steal audio focus from other apps (music, other players) on
 visionOS — videos start muted, and even when unmuted they mix rather than
 interrupt.

 Without this, AVPlayer-backed players (native Metal, fake-3D) inherit the
 default `.soloAmbient` category, which interrupts other audio the moment a
 clip with an audio track begins — even while muted. WebKit manages its own
 mixable session, which is why only the native path exhibited the interruption.
 */

import AVFoundation
import os

enum AudioSessionConfig {
    /// Configure a mixable playback session. Idempotent; safe to call repeatedly.
    static func configureMixedPlayback() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        } catch {
            AppLogger.appModel.error("Failed to set mixable audio session: \(error.localizedDescription, privacy: .public)")
        }
    }
}
