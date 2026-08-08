import Foundation

enum GameMode: String, Codable, CaseIterable, Identifiable {
    case indoor, outdoor
    var id: String { rawValue }
}

struct GameSettings: Codable, Equatable {
    var mode: GameMode
    var weaponRange: Float        // meters
    var aimConeDegrees: Float     // half-angle off boresight
    var damage: Int
    var maxHP: Int
    var fireCooldown: TimeInterval
    var respawnDelay: TimeInterval
    var hitInvulnerability: TimeInterval   // i-frames after taking a hit
    var spawnProtection: TimeInterval      // i-frames after respawning
    var matchDuration: TimeInterval   // seconds; host picks, ends the match
    var magazineSize: Int             // rounds before a reload
    var reloadDuration: TimeInterval

    var aimConeRadians: Float { aimConeDegrees * .pi / 180 }

    static let indoor = GameSettings(
        mode: .indoor, weaponRange: 8, aimConeDegrees: 15,
        damage: 25, maxHP: 100, fireCooldown: 0.5, respawnDelay: 5,
        hitInvulnerability: 0.5, spawnProtection: 1,
        matchDuration: 300, magazineSize: 10, reloadDuration: 3)

    static let outdoor = GameSettings(
        mode: .outdoor, weaponRange: 20, aimConeDegrees: 10,
        damage: 34, maxHP: 100, fireCooldown: 0.5, respawnDelay: 5,
        hitInvulnerability: 0.5, spawnProtection: 1,
        matchDuration: 300, magazineSize: 10, reloadDuration: 3)

    /// Match lengths the host can pick in the lobby.
    static let durationChoices: [TimeInterval] = [120, 300, 600, 900]

    static func preset(for mode: GameMode) -> GameSettings {
        mode == .indoor ? .indoor : .outdoor
    }
}

extension TimeInterval {
    /// "M:SS" for the HUD clock and summary.
    var clockString: String {
        let total = Int(max(0, self).rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "5 min" / "1:30" for the lobby picker.
    var durationLabel: String {
        let total = Int(self)
        return total % 60 == 0 ? "\(total / 60) min" : clockString
    }
}

/// Wire protocol between phones. Player identity is the Multipeer display
/// name, which carries a random "#xxxx" suffix so two players typing the same
/// call sign stay distinct — strip it with `.displayCallSign` when rendering.
enum GameMessage: Codable {
    case hello(playerName: String)
    case discoveryToken(Data)          // archived NIDiscoveryToken (per-session, per-peer)
    case startGame(settings: GameSettings)
    case stateSnapshot([PlayerState])  // late-join / reconnect sync
    case shotFired(by: String)         // for sound/muzzle-flash on others
    case hit(target: String, by: String, damage: Int)
    case healthUpdate(player: String, hp: Int)
    case death(player: String, killedBy: String)
    case respawn(player: String)
    case endMatch(finalStates: [PlayerState])   // host calls time; its tallies win
    case matchClock(remaining: TimeInterval)    // host re-syncs a late joiner's clock
    case spectatorHello                         // sender is a spectator (laptop), not a player
    case cameraRequest(active: Bool)            // spectator → player: stream me your viewfinder
}

struct Player: Identifiable {
    let name: String
    var hp: Int
    var isAlive: Bool = true
    var kills: Int = 0
    var deaths: Int = 0
    var isConnected: Bool = true
    var id: String { name }
}

struct PlayerState: Codable {
    let name: String
    let hp: Int
    let isAlive: Bool
    let kills: Int
    let deaths: Int

    init(_ player: Player) {
        name = player.name
        hp = player.hp
        isAlive = player.isAlive
        kills = player.kills
        deaths = player.deaths
    }
}

extension String {
    /// Player name without the "#xxxx" wire-uniqueness suffix.
    var displayCallSign: String {
        guard let hash = lastIndex(of: "#"),
              distance(from: hash, to: endIndex) == 5,
              self[index(after: hash)...].allSatisfy({ $0.isHexDigit })
        else { return self }
        return String(self[..<hash])
    }
}

struct KillEvent: Identifiable {
    let id = UUID()
    let killer: String
    let victim: String
    let timestamp = Date()
}

/// Frozen end-of-match tallies. Snapshotting keeps the summary stable while
/// late network chatter (a death message in flight) still trickles in.
struct MatchResult {
    let standings: [Player]      // ranked: kills desc, then fewest deaths, then name
    let duration: TimeInterval
    let myName: String

    init(players: [Player], duration: TimeInterval, myName: String) {
        standings = players.sorted { a, b in
            if a.kills != b.kills { return a.kills > b.kills }
            if a.deaths != b.deaths { return a.deaths < b.deaths }
            return a.name < b.name
        }
        self.duration = duration
        self.myName = myName
    }

    var me: Player? { standings.first { $0.name == myName } }
    var myPlacement: Int? { standings.firstIndex { $0.name == myName }.map { $0 + 1 } }

    /// Nil when the top two are tied on kills — a draw has no winner to crown.
    var winner: Player? {
        guard let top = standings.first, top.kills > 0 || standings.count == 1 else { return nil }
        if standings.count > 1, standings[1].kills == top.kills { return nil }
        return top
    }

    var isDraw: Bool { winner == nil }
    var didIWin: Bool { winner?.name == myName }
}

extension Player {
    /// Kills per death, counting a deathless run as its own kill total.
    var kdRatio: Double { deaths == 0 ? Double(kills) : Double(kills) / Double(deaths) }
    var kdString: String { String(format: "%.2f", kdRatio) }
}
