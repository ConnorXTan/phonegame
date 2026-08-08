import AVFoundation

/// Plays the synthesized game sounds (Sounds/*.wav). Small player pools so
/// rapid fire doesn't cut itself off.
final class SoundManager {
    static let shared = SoundManager()

    private var pools: [String: [AVAudioPlayer]] = [:]
    private var nextIndex: [String: Int] = [:]

    private init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        preload("pew", copies: 3)
        preload("hit", copies: 2)
        preload("death", copies: 1)
        preload("hitmarker", copies: 4)   // deepest pool: hits land fastest
    }

    /// Force the lazy singleton up before the match starts. Building the
    /// player pools takes long enough to blow the ranging freshness window if
    /// it happens on the first trigger pull.
    func prepare() {}

    /// `rate` repitches — the kill confirm is the hitmarker played sharper.
    func play(_ name: String, volume: Float = 1.0, rate: Float = 1.0) {
        guard let pool = pools[name], !pool.isEmpty else { return }
        let i = (nextIndex[name] ?? 0) % pool.count
        nextIndex[name] = i + 1
        let player = pool[i]
        player.volume = volume
        player.rate = rate
        player.currentTime = 0
        player.play()
    }

    private func preload(_ name: String, copies: Int) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            print("[Sound] missing asset \(name).wav")
            return
        }
        pools[name] = (0..<copies).compactMap { _ in
            let player = try? AVAudioPlayer(contentsOf: url)
            player?.enableRate = true   // must be set before prepareToPlay()
            player?.prepareToPlay()
            return player
        }
    }
}
