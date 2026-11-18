import AVFoundation

/// Keeps Signet running in the background during an install by playing silence.
///
/// iOS downloads the IPA from Signet's server after the user confirms the install prompt, usually with Signet in
/// the background. A background task only buys about 30 seconds, which a large app can outlast; an app playing
/// audio keeps running. The session mixes with other audio, so music the user is playing isn't interrupted.
@MainActor
final class KeepAlive {
    static let shared = KeepAlive()
    static let settingKey = "keepAliveDuringInstalls"

    /// On unless the user turned it off in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: settingKey) as? Bool ?? true
    }

    private var engine: AVAudioEngine?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start() {
        guard Self.isEnabled, engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            // One second of zeroed samples, looped.
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return }
            silence.frameLength = silence.frameCapacity
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
            self.engine = engine
        } catch {
            stop()
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
