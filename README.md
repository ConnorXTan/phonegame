# Echo

iPhone laser tag over Ultra Wideband. Aim your phone like a camera, fire, and the other player's phone buzzes, flashes red, and loses HP. No server, no venue Wi-Fi — the phones talk directly to each other.

Built from [iphone-laser-tag-plan.md](iphone-laser-tag-plan.md):

- **Aiming** — Nearby Interaction (the UWB chip behind AirTag precision finding) streams distance + 3D direction between iPhones at ~55 Hz. A shot hits when the target is inside the aim cone and weapon range; the most-centered target wins.
- **Networking** — MultipeerConnectivity peer-to-peer mesh (Wi-Fi/Bluetooth, zero backend).
- **Feedback** — Core Haptics: fire tick, shooter hit-marker, heavy ×3 damage burst, death rumble, target-lock tick.

## Requirements

- **iPhone 11 or later, not SE** — every player's phone needs the U1/U2 UWB chip
- iOS 17+, 2–6 players
- **Real devices only.** Nearby Interaction does not work in the simulator — test on hardware from day one.
- Xcode 16+. Free Apple Developer accounts work (7-day provisioning; re-deploy from Xcode takes minutes if it expires mid-event).

## Build & run

1. `open Echo.xcodeproj`
2. Target **Echo** → Signing & Capabilities → pick your team (automatic signing). Change the bundle ID if it collides.
3. Build to each player's phone. On first launch, allow **Local Network**, **Nearby Interaction**, and **Camera** (camera assistance makes UWB aiming noticeably more reliable).

## How to play

1. Everyone enters a call sign (a hidden random tag keeps identities distinct, so duplicates won't break anything — but unique names keep the kill feed readable).
2. One player taps **Host Game** and picks a mode; everyone else taps **Join Game**. Nearby phones auto-mesh — the lobby fills in as they find each other.
3. Host taps **Start**. Phones exchange UWB tokens and ranging begins.
4. **Hold the phone in portrait like you're photographing your target** — the UWB antenna cone points out the *back* of the phone. The crosshair locks (with a tick) when someone is in your sights.
5. **FIRE.** Hit: their phone buzzes heavy ×3, flashes red, HP drops. At 0 HP: death screen, 5 s respawn.
6. Bodies block UWB — **human shields are canon**.

| Mode | Range | Aim cone | Damage |
|---|---|---|---|
| Indoor | 8 m | 15° | 25 (4-shot kill) |
| Outdoor | 20 m | 10° | 34 (3-shot kill) |

Tuning lives in `GameSettings` presets (`Echo/Models/GameModels.swift`) — adjust cone/range/damage in playtesting.

## Architecture

```
SwiftUI views      MenuView · LobbyView · GameHUDView · RadarView ·
                   DeathView · DebugRangingView · ScoreboardView
GameEngine         player state · HP · hit resolution · cooldowns · respawns
RangingManager     one NISession per peer · token exchange · 0.3 s reading buffer
NetworkManager     MultipeerConnectivity full mesh · Codable GameMessage protocol
HapticsManager     Core Haptics patterns + placeholder system sounds
```

Hit resolution runs on the **shooter's** phone (it has the ranging data); the victim applies damage on receipt and broadcasts its own health/death/respawn. Host is source of truth for start + settings. Hackathon scale: trust the network.

The in-game **radar** (top-down blips) and the **UWB Ranging debug sheet** (live distance / direction / angle-off-boresight per peer, via the magnifying-glass button in the HUD) are the Phase 2 milestone tools — use the debug sheet to verify ranging before playing, and the radar on a projector for the demo.

## Troubleshooting

- **Crosshair never locks** — aim like a photo (back of phone toward target), target within range and the FoV cone; `direction` is nil outside the cone by design. Check the debug sheet.
- **Sessions drop in crowds** — bodies block UWB. Invalidated sessions auto-restart with a fresh token exchange; if a peer stays dark, both players toggle out to the lobby and back.
- **Nobody appears in the lobby** — all phones need Local Network permission granted and Wi-Fi/Bluetooth on (they don't need to join the same network).
- **Battery** — UWB + screen-always-on is heavy drain. Chargers between rounds.

## Not built yet (stretch, in demo-value order)

AR crosshair mode → teams → weapon classes (shotgun/sniper) → Watch companion → spectator web scoreboard. Sounds are placeholder system clicks — swap in real pew/hit assets in `HapticsManager`.
