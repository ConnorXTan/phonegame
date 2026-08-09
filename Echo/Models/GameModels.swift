import Foundation

/// A player's loadout, picked per-player in the lobby. Balanced as a triangle:
/// head-on, Heavy beats Reg beats Light — Light pays for it with full-auto
/// spray (much easier to land hits inside the tight 5° cone), the deepest
/// magazine, and a fast reload.
///
/// Shots to kill (victim HP ÷ shooter damage):
///              vs Light   vs Regular   vs Heavy
///   Light         4           6           9
///   Regular       3           4           6
///   Heavy         2           3           4
///
/// Note the 0.5 s hit-invulnerability window means a single victim can absorb
/// at most 2 hits/s no matter the fire rate — Light's 0.25 s cadence is for
/// tracking and spray coverage, not double DPS on one target.
enum PlayerRole: String, Codable, CaseIterable, Identifiable {
    case light, regular, heavy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light"
        case .regular: return "Regular"
        case .heavy: return "Heavy"
        }
    }

    /// SF Symbol shown wherever the role is named.
    var symbol: String {
        switch self {
        case .light: return "hare.fill"
        case .regular: return "person.fill"
        case .heavy: return "shield.fill"
        }
    }

    /// One-line pitch for the lobby picker.
    var blurb: String {
        switch self {
        case .light: return "Hold FIRE for full auto"
        case .regular: return "Balanced loadout"
        case .heavy: return "Slow, crushing shots"
        }
    }

    var maxHP: Int {
        switch self {
        case .light: return 70
        case .regular: return 100
        case .heavy: return 150
        }
    }

    var damage: Int {
        switch self {
        case .light: return 18
        case .regular: return 25
        case .heavy: return 40
        }
    }

    var fireCooldown: TimeInterval {
        switch self {
        case .light: return 0.25
        case .regular: return 0.5
        case .heavy: return 1.0
        }
    }

    var magazineSize: Int {
        switch self {
        case .light: return 16
        case .regular: return 10
        case .heavy: return 5
        }
    }

    var reloadDuration: TimeInterval {
        switch self {
        case .light: return 3
        case .regular: return 3
        case .heavy: return 4.5
        }
    }

    /// Automatic roles keep firing while the FIRE button is held.
    var isAutomatic: Bool { self == .light }
}

/// The two sides in team play. Named, not colored — every screen renders a
/// team relative to the viewer (yours reads ally, the other reads enemy), so
/// a color name would lie to half the lobby.
enum Team: String, Codable, CaseIterable, Identifiable {
    case alpha, bravo
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    /// One-letter form for the HUD score readout ("A 4 · B 2").
    var initial: String { displayName.prefix(1).uppercased() }
    var other: Team { self == .alpha ? .bravo : .alpha }
}

struct GameSettings: Codable, Equatable {
    var weaponRange: Float        // meters
    var aimConeDegrees: Float     // half-angle off boresight
    var respawnDelay: TimeInterval
    var hitInvulnerability: TimeInterval   // i-frames after taking a hit
    var spawnProtection: TimeInterval      // i-frames after respawning
    var matchDuration: TimeInterval   // seconds; host picks, ends the match
    var maxPlayers: Int               // lobby capacity; spectators don't count
    var teamPlay: Bool = false        // two teams, no friendly fire, team kill totals win

    var aimConeRadians: Float { aimConeDegrees * .pi / 180 }

    static let standard = GameSettings(
        weaponRange: 15, aimConeDegrees: 5,
        respawnDelay: 5, hitInvulnerability: 0.5, spawnProtection: 1,
        matchDuration: 300, maxPlayers: 6)

    /// Match lengths the host can pick in the lobby.
    static let durationChoices: [TimeInterval] = [120, 300, 600, 900]

    /// Lobby sizes the host can pick.
    static let maxPlayerChoices: [Int] = [2, 3, 4, 6, 8]
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
    case hello(playerName: String, role: PlayerRole)
    case roleSelect(player: String, role: PlayerRole)   // lobby-only loadout change
    case discoveryToken(Data)          // archived NIDiscoveryToken (per-session, per-peer)
    case settingsUpdate(settings: GameSettings)   // host edited lobby settings; joiners mirror (mode, teams, length)
    case teamChange(player: String, team: Team)   // sender picked a side (team play)
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
    case hostEnded                              // host closed the game; everyone back to the menu
    case lobbyRoster(players: [String], spectators: [String])   // host-authoritative membership; drives mesh + UI
    case joinDenied(reason: String)             // host turned the sender's join down (e.g. lobby full)
    case overlayState(SpectatorOverlayState)    // streamer → spectator: HUD elements to redraw over the feed
}

/// What the spectated player sees, reduced to the two things worth mirroring:
/// their crosshair state and the enemy tags floating in their viewfinder.
/// Tag positions are normalized (0–1) in the full portrait camera frame, so
/// the spectator pins them straight onto the streamed image — the projection
/// math stays on the phone, which has the AR camera to do it with.
struct SpectatorOverlayState: Codable, Equatable {
    struct Tag: Codable, Equatable {
        let name: String     // display call sign, pre-stripped
        let x: Double
        let y: Double
        let hp: Double       // 0–1 fraction
    }
    let tags: [Tag]
    let lockedTarget: String?   // display call sign under the crosshair, if locked
}

struct Player: Identifiable {
    let name: String
    var role: PlayerRole
    var hp: Int
    var isAlive: Bool = true
    var kills: Int = 0
    var deaths: Int = 0
    var isConnected: Bool = true
    var team: Team? = nil   // nil in solo play, or before this player has picked
    var id: String { name }

    init(name: String, role: PlayerRole = .regular) {
        self.name = name
        self.role = role
        self.hp = role.maxHP
    }
}

struct PlayerState: Codable {
    let name: String
    let role: PlayerRole
    let hp: Int
    let isAlive: Bool
    let kills: Int
    let deaths: Int
    let team: Team?

    init(_ player: Player) {
        name = player.name
        role = player.role
        hp = player.hp
        isAlive = player.isAlive
        kills = player.kills
        deaths = player.deaths
        team = player.team
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

/// Drives the HUD hit marker. `count` increments per confirmed hit so rapid
/// hits retrigger the animation; `isKill` swaps it to the kill styling.
struct HitMarker: Equatable {
    var count: Int
    var isKill: Bool
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
    let teamPlay: Bool

    init(players: [Player], duration: TimeInterval, myName: String, teamPlay: Bool = false) {
        standings = players.sorted { a, b in
            if a.kills != b.kills { return a.kills > b.kills }
            if a.deaths != b.deaths { return a.deaths < b.deaths }
            return a.name < b.name
        }
        self.duration = duration
        self.myName = myName
        self.teamPlay = teamPlay
    }

    var me: Player? { standings.first { $0.name == myName } }
    var myTeam: Team? { me?.team }
    var myPlacement: Int? { standings.firstIndex { $0.name == myName }.map { $0 + 1 } }

    /// Nil when the top two are tied on kills — a draw has no winner to crown.
    /// Solo only; team play crowns a team, not a player.
    var winner: Player? {
        guard !teamPlay else { return nil }
        guard let top = standings.first, top.kills > 0 || standings.count == 1 else { return nil }
        if standings.count > 1, standings[1].kills == top.kills { return nil }
        return top
    }

    func kills(for team: Team) -> Int {
        standings.filter { $0.team == team }.reduce(0) { $0 + $1.kills }
    }

    /// Team play: most combined kills wins; nil on a tie.
    var winningTeam: Team? {
        guard teamPlay else { return nil }
        let alpha = kills(for: .alpha), bravo = kills(for: .bravo)
        guard alpha != bravo else { return nil }
        return alpha > bravo ? .alpha : .bravo
    }

    var isDraw: Bool { teamPlay ? winningTeam == nil : winner == nil }
    var didIWin: Bool {
        teamPlay ? (winningTeam != nil && winningTeam == myTeam) : winner?.name == myName
    }
}

extension Player {
    /// Kills per death, counting a deathless run as its own kill total.
    var kdRatio: Double { deaths == 0 ? Double(kills) : Double(kills) / Double(deaths) }
    var kdString: String { String(format: "%.2f", kdRatio) }
}
