# LTN — Laser Tag Now

iPhone laser tag over Ultra-Wideband. Aim your phone like a camera, fire, and the other player's phone buzzes, flashes red, and loses hearts. No server, no venue Wi-Fi — the phones talk directly to each other.

## What's in it

- **Aiming** — Nearby Interaction streams distance and direction to every peer. A shot lands on the most-centered target inside a 9° half-angle cone off the *back* of the phone; distance never gates it. The ARKit viewfinder behind the HUD doubles as NI's camera assistance — on U2 phones (15/16) that camera-assisted angle is often the only bearing you get.
- **Networking** — Bonjour plus direct TCP over peer-to-peer Wi-Fi (`Network.framework`), no backend. Lobbies are scoped, not blindly meshed: a joiner dials the one host it picked, and lobby-mates dial each other only once the host's roster names them.
- **Roles** — Light / Regular / Heavy, picked in the lobby, trading hearts against fire rate, damage, magazine and reload. Light is full-auto.
- **Teams** — optional Alpha / Bravo: no friendly fire, scored on team kill totals.
- **Power-ups** — Medpack (4 hearts, instant), Overdrive (halves cooldown and reload, 10 s), Cloak (5 s), Reflector (5 s), with countdown rings on the drop and on your active effects.
- **Ammo** — the ring around FIRE is your magazine. Empty auto-reloads; the button beside it reloads early.
- **Training Range** — solo drill, no lobby and no UWB: shoot a console orb to pick a difficulty, then clear 30 pop-up drones from a frontal arc, three up at a time. Pure ARKit, so any phone runs it.
- **Spectating** — a Mac or spare phone joins as game master for standings, kill feed and any player's live viewfinder.
- **Killcam** — shooters keep a rolling ~4 s of viewfinder at 30 fps and snapshot it on a confirmed kill. Clips move to spectators after the match, to review and publish — HUD baked in, sounds remixed, H.264 — to the [killcam-web](killcam-web) gallery.

| Role | Hearts | Damage | Fire | Magazine | Reload |
|---|---|---|---|---|---|
| Light | 6 | 1 | 0.1 s, full auto | 16 | 3 s |
| Regular | 8 | 2 | 0.5 s | 10 | 3 s |
| Heavy | 10 | 3 | 1.0 s | 5 | 4.5 s |

Hearts are discrete and nothing grants i-frames mid-fight, so fire rate, magazine and reload are the only throttles on damage. Match-wide: 9° cone, 5 s respawn, 1 s spawn protection, 2–8 players, 2/5/10/15 min matches — all in `Echo/Models/GameModels.swift`.

## Build & run

**iPhone 11 or later, not SE** (every player needs the U1/U2 chip), iOS 17+, Xcode 16+. **Real devices only** — Nearby Interaction doesn't work in the Simulator, which has no camera either, so it only covers menus and static HUD layout.

`open Echo.xcodeproj` → target **Echo** → Signing & Capabilities → pick your team. The project, target and source folder are all still named `Echo`; the app ships as LTN. On first launch allow **Local Network**, **Nearby Interaction** and **Camera**.

## How to play

1. Enter a call sign. A hidden `#xxxx` suffix keeps duplicates distinct on the wire, but unique names keep the kill feed readable.
2. One player taps **Host a Lobby** and picks role, mode and match length; everyone else taps **Find Lobbies**. **Training Range** needs neither. Host taps **Start** and phones exchange UWB tokens.
3. **Hold the phone in portrait like you're photographing your target** — the antenna cone points out the back. The reticle closes and ticks on a lock.
4. **FIRE.** Hits buzz their phone, flash it red and drop hearts; at zero, a death screen and a 5 s respawn. Bodies block UWB — **human shields are canon.**
5. K/D sits beside the match clock, which goes red for the last 30 s. Time up sends everyone to the summary; **Back to Lobby** keeps the mesh up for another round.

## Architecture

```
LTNApp            RootView switches on GameEngine.phase — menu · browsing ·
                  lobby · playing · summary · training
Managers/
  GameEngine      the hub: player table · hit resolution · cooldowns ·
                  respawns · match clock · consumables · clip capture
  NetworkManager  Network.framework mesh · Codable GameMessage protocol
  RangingManager  one NISession per peer · token exchange · reading buffer
  AimCameraMgr    the single shared ARSession — viewfinder, NI camera
                  assistance, spectator frame tap, killcam ring buffer
  TrainingRange   solo drill state: console orbs, drone arc, local aim test
  ClipEncoder     frames + HUD + sounds → MP4 · ReplayPublisher uploads it
  HapticsManager  Core Haptics patterns · SoundManager plays Echo/Sounds/
Models/           roles · settings · wire protocol · match results
Design/           Theme (color, spacing, opacity tokens) · Typography
Views/            one screen per phase, plus the HUD layers — reticle,
                  minimap, enemy tags, drop markers, training overlay
```

Three invariants to know before changing anything:

- **Hit resolution runs on the shooter's phone** — it holds the ranging data. The victim applies damage on receipt and broadcasts its own health, death and respawn. Hackathon scale: trust the network.
- **Only the host calls time.** Every phone counts down locally off a wall-clock deadline, but the host's `.endMatch` tallies are what everyone shows, so two phones can't crown different winners. If the host goes dark, each phone ends on its own after 5 s.
- **There is no shared world frame.** Each phone knows its peers only through its own pairwise UWB readings, so a power-up drop travels as an affine combination of player positions and every phone resolves the same physical spot in its own AR frame.

`Echo/Design/Theme.swift` is the source of truth for color and spacing; `CLAUDE.md` carries the UI rules that go with it.

## Troubleshooting

- **Reticle never locks** — aim like a photo, back of the phone toward the target. `direction` is nil outside the UWB field of view by design, and camera assistance needs a lit, textured scene to converge.
- **Sessions drop in crowds** — bodies block UWB. Dead NI sessions auto-restart with fresh tokens; if a peer stays dark, both players bounce to the lobby and back.
- **Nobody in the lobby** — every phone needs Local Network permission and Wi-Fi/Bluetooth on, though not the same network.
- **Battery** — UWB, an always-on screen and a live ARSession together are heavy drain.

Sounds in `Echo/Sounds/` are synthesized originals, not sampled from any game. [iphone-laser-tag-plan.md](iphone-laser-tag-plan.md) is the original design doc — historical, and stale on networking in particular.
