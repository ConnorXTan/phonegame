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

    var aimConeRadians: Float { aimConeDegrees * .pi / 180 }

    static let indoor = GameSettings(
        mode: .indoor, weaponRange: 8, aimConeDegrees: 15,
        damage: 25, maxHP: 100, fireCooldown: 0.5, respawnDelay: 5)

    static let outdoor = GameSettings(
        mode: .outdoor, weaponRange: 20, aimConeDegrees: 10,
        damage: 34, maxHP: 100, fireCooldown: 0.5, respawnDelay: 5)

    static func preset(for mode: GameMode) -> GameSettings {
        mode == .indoor ? .indoor : .outdoor
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
