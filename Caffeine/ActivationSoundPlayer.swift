import AVFAudio
import CaffeineLogging
import Foundation

/// Retained by the application runtime, independently of the menu bar card.
@MainActor
final class ActivationSoundPlayer {
    private var player: AVAudioPlayer?
    private let log: EventLog

    init(log: EventLog = .disabled) { self.log = log }

    func play() {
        if player == nil {
            guard let url = Bundle.main.url(forResource: "slurping", withExtension: "m4a") else {
                log.error(.audio, "The Keep awake activation sound is missing from the app bundle")
                return
            }
            do {
                player = try AVAudioPlayer(contentsOf: url)
            } catch {
                log.error(.audio, "The Keep awake activation sound could not be loaded: \(error.localizedDescription)")
                return
            }
        }
        // A rapid new session restarts the short cue instead of overlapping players.
        player?.currentTime = 0
        if player?.play() == false {
            log.error(.audio, "The Keep awake activation sound could not be played")
        }
    }
}
