import SwiftUI

/// Named references for the hand-drawn brand art in `Assets.xcassets`.
///
/// These raster marks are a deliberate exception to the SF-Symbols-only rule in
/// the design guide: they carry Echo's identity (the reticle logo, the marker
/// hit crosses, the eliminated skull) and can't be expressed as a system glyph.
/// Everything else in the interface still comes from SF Symbols. Referencing the
/// art through this enum keeps the raw asset strings out of the views — the same
/// reason colors and spacing live behind tokens.
enum Art: String {
    case logo = "logo-main"
    case hitMarker = "hit-marker"
    case hitMarkerKill = "hit-marker-kill"
    case eliminated = "eliminated"
    case reload = "reload"
    case leaderboard = "leaderboard"
    case exitGame = "exit-game"
    case killSkull = "kill-skull"
    case heartFull = "heart-full"
    case heartEmpty = "heart-empty"
    case spectate = "spectate"

    // Lobby: the two entry actions and the match-setting glyphs.
    case hostLobby = "host-lobby"
    case joinLobby = "join-lobby"
    case lobbyHearts = "lobby-hearts"
    case lobbyDamage = "lobby-damage"
    case lobbyAmmo = "lobby-ammo"
    case lobbyLength = "lobby-length"
}

extension Image {
    /// `Image(art: .logo)` — resolves a brand asset by its typed name.
    init(art: Art) {
        self.init(art.rawValue)
    }
}
