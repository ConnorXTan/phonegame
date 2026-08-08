# Echo

iPhone laser tag over Ultra Wideband. Aim your phone like a camera, fire, and the other player's phone buzzes, flashes red, and loses HP. No server, no venue Wi-Fi — the phones talk directly to each other.

Built from [iphone-laser-tag-plan.md](iphone-laser-tag-plan.md):

- **Aiming** — Nearby Interaction (the UWB chip behind AirTag precision finding) streams distance + 3D direction between iPhones at ~55 Hz. A shot hits when the target is inside the aim cone and weapon range; the most-centered target wins.
- **Networking** — MultipeerConnectivity peer-to-peer mesh (Wi-Fi/Bluetooth, zero backend).
- **Feedback** — Core Haptics: fire tick, shooter hit-marker, heavy ×3 damage burst, death rumble, target-lock tick.
- **Match flow** — the host picks a match length; a live K/D readout and countdown sit in the HUD, and time expiring drops everyone into a match summary.
- **Ammo** — 10 rounds to a magazine, shown as segments in the ring around FIRE. Emptying it auto-reloads (3 s), or reload early with the button beside FIRE.

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
2. One player taps **Host Game** and picks a mode and **match length** (2 / 5 / 10 / 15 min); everyone else taps **Join Game**. Nearby phones auto-mesh — the lobby fills in as they find each other.
3. Host taps **Start**. Phones exchange UWB tokens and ranging begins.
4. **Hold the phone in portrait like you're photographing your target** — the UWB antenna cone points out the *back* of the phone. The crosshair locks (with a tick) when someone is in your sights.
5. **FIRE.** Hit: their phone buzzes heavy ×3, flashes red, HP drops. At 0 HP: death screen, 5 s respawn.
   The ring around FIRE is your **magazine** — 10 segments, one per round, turning red on the last two. Run dry and it reloads itself in 3 s (you can't fire during it), so top up with the reload button before you push. Respawning hands you a fresh mag.
6. Bodies block UWB — **human shields are canon**.
7. Your **kills and deaths** run live in the HUD next to the match clock (which turns red for the last 30 s); the ⅓-list button opens the full scoreboard mid-match.
8. When the clock hits zero everyone gets the **match summary** — winner, your K/D, and the final standings. **Back to Lobby** keeps the mesh up so the host can run another round.

| Mode | Range | Aim cone | Damage |
|---|---|---|---|
| Indoor | 8 m | 15° | 25 (4-shot kill) |
| Outdoor | 20 m | 10° | 34 (3-shot kill) |

Tuning lives in `GameSettings` presets (`Echo/Models/GameModels.swift`) — adjust cone/range/damage, plus `magazineSize` and `reloadDuration`, in playtesting.

## Architecture

```
SwiftUI views      MenuView · LobbyView · GameHUDView · CameraFeedView · DeathView ·
                   RadarView · DebugRangingView · ScoreboardView · MatchSummaryView
GameEngine         player state · HP · hit resolution · cooldowns · respawns ·
                   match clock · end-of-match standings
RangingManager     one NISession per peer · token exchange · 0.3 s reading buffer
NetworkManager     MultipeerConnectivity full mesh · Codable GameMessage protocol
HapticsManager     Core Haptics patterns + placeholder system sounds
```

Hit resolution runs on the **shooter's** phone (it has the ranging data); the victim applies damage on receipt and broadcasts its own health/death/respawn. Host is source of truth for start + settings. Hackathon scale: trust the network.

Every phone counts the match clock down locally off a wall-clock deadline, but only the **host calls time** — it broadcasts `.endMatch` with its own tallies, so two phones can never crown different winners. If the host goes dark, each phone ends on its own tallies after a 5 s grace period. Late joiners get a `.matchClock` message so their clock doesn't start a full match length from scratch.

The **UWB Ranging debug sheet** (magnifying-glass button in the HUD) shows live distance / direction / angle-off-boresight per peer plus the **radar** (top-down blips) — use it to verify ranging before playing, and on a projector for the demo.

## Troubleshooting

- **Crosshair never locks** — aim like a photo (back of phone toward target), target within range and the FoV cone; `direction` is nil outside the cone by design. Check the debug sheet.
- **Sessions drop in crowds** — bodies block UWB. Invalidated sessions auto-restart with a fresh token exchange; if a peer stays dark, both players toggle out to the lobby and back.
- **Nobody appears in the lobby** — all phones need Local Network permission granted and Wi-Fi/Bluetooth on (they don't need to join the same network).
- **Battery** — UWB + screen-always-on is heavy drain. Chargers between rounds.

## Not built yet (stretch, in demo-value order)

AR crosshair mode → teams → weapon classes (shotgun/sniper) → Watch companion → spectator web scoreboard. Sounds are placeholder system clicks — swap in real pew/hit assets in `HapticsManager`.
