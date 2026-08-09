import SwiftUI

/// Named references for the hand-drawn brand art in `Assets.xcassets`.
///
/// These raster marks are a deliberate exception to the SF-Symbols-only rule in
/// the design guide: they carry LTN's identity (the reticle logo, the marker
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

    // Consumable power-ups.
    case overdrive = "overdrive"
    case medpack = "medpack"
    case cloak = "cloak"
    case armor = "armor"
}

extension ConsumableKind {
    /// The hand-drawn mark for this power-up, shown on the drop marker, the
    /// active-effect badge, and the minimap blip.
    var art: Art {
        switch self {
        case .medpack: .medpack
        case .drink:   .overdrive
        case .cloak:   .cloak
        case .armor:   .armor
        }
    }

    /// Ring/countdown colour, matched to the mark's own hue so each power-up
    /// reads as one thing. Reuses existing tokens rather than new literals.
    var tint: Color {
        switch self {
        case .medpack: .ltnSecondary   // green
        case .drink:   .ltnDanger      // red
        case .cloak:   .ltnTeamAlly    // blue
        case .armor:   .ltnWarning     // yellow
        }
    }
}

extension Image {
    /// `Image(art: .logo)` — resolves a brand asset by its typed name.
    init(art: Art) {
        self.init(art.rawValue)
    }
}
