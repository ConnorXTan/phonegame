# LTN — iPhone Laser Tag Hackathon Plan

**Verdict: Feasible.** Native iOS app (SwiftUI) using UWB (Nearby Interaction) for aiming, MultipeerConnectivity for networking (no backend server needed), Core Haptics for hit feedback. 3–6 players, works indoors and outdoors.

---

## 1. Why this architecture

| Requirement | Solution | Why not alternatives |
|---|---|---|
| "Is phone A pointing at phone B?" | **Nearby Interaction (UWB)** — streams distance (meters) + 3D direction vector between iPhones at ~55 Hz, inch-level distance accuracy | GPS+compass: ±3–10 m position error, ±10–20° heading error — unusable indoors. Camera/CV person detection: can't tell *which* player, hackathon-hard |
| Haptic feedback on hit | **Core Haptics / UIFeedbackGenerator** (native) | iOS Safari has no Vibration API; the checkbox-switch hack was patched in iOS 26.5. Web = no haptics |
| Create/join game + real-time events | **MultipeerConnectivity** — local Wi-Fi/Bluetooth mesh, zero backend | A server adds deploy time, latency, and Wi-Fi dependency at the venue |
| Health display, fire button, UI | **SwiftUI** | Fast to build, easy for AI-assisted coding |

**Hardware requirement:** every player needs an **iPhone 11 or later (not SE)** — these have the U1/U2 UWB chip. Nearby Interaction does NOT work in the simulator; test on real devices from day one. Free Apple Developer accounts are sufficient (7-day provisioning, re-sign as needed).

---

## 2. Key UWB facts to design around

- **Direction cone points out the BACK of the phone** (field of view ≈ the ultra-wide camera's). Aiming = holding the phone up like taking a photo of your target. Hold in **portrait** for best results.
- **`direction` is nullable.** If the peer is out of the FoV cone (or occluded), you get distance but `direction == nil`. Treat nil as "not in your sights."
- **Range:** ~5–10 m indoors with obstacles; 20–30 m+ outdoors line-of-sight. Set weapon range accordingly (see §5).
- **Bodies block UWB.** A person standing between two phones degrades or kills the signal. Announce this as a feature: "human shields work."
- **Sessions are pairwise.** Each phone runs one `NISession` per peer → 6 players = 5 sessions each. Fine at this scale.
- **Foreground only.** Screen must stay on; disable idle timer (`UIApplication.shared.isIdleTimerDisabled = true`).
- **Camera assistance** (`isCameraAssistanceEnabled = true`, iOS 16+): fuses ARKit to widen effective FoV and adds `horizontalAngle` / `verticalDirectionEstimate`. Use it — it makes aiming noticeably more reliable.

---

## 3. App architecture

```
┌─────────────────────────────────────────────┐
│                  SwiftUI Views              │
│  LobbyView · GameHUDView · RadarView ·      │
│  DeathView · DebugRangingView               │
├─────────────────────────────────────────────┤
│               GameEngine (ObservableObject) │
│  player state · HP · hit resolution ·       │
│  cooldowns · respawn timers                 │
├──────────────────────┬──────────────────────┤
│  RangingManager      │  NetworkManager      │
│  1 NISession/peer    │  MultipeerConnectivity│
│  latest distance/    │  lobby + token swap +│
│  direction per peer  │  game event messages │
└──────────────────────┴──────────────────────┘
```

### Message protocol (Codable enum over Multipeer)

```swift
enum GameMessage: Codable {
    case hello(playerName: String)
    case discoveryToken(Data)          // archived NIDiscoveryToken
    case startGame(settings: GameSettings)
    case shotFired(by: String)         // for sound/muzzle-flash on others
    case hit(target: String, by: String, damage: Int)
    case healthUpdate(player: String, hp: Int)
    case death(player: String, killedBy: String)
    case respawn(player: String)
}
```

Host phone = source of truth for game start/settings; hit resolution happens on the **shooter's** phone (it has the ranging data), victim applies damage on receipt. At hackathon scale, trust the network — no anti-cheat needed.

---

## 4. Hit detection (the core algorithm)

On fire-button press, on the shooter's phone:

```swift
func resolveShot() -> Peer? {
    let now = Date()
    return peers
        .compactMap { peer -> (Peer, Float, Float)? in
            // use a short buffer of recent readings (last ~0.3 s)
            // so a single nil frame doesn't eat the shot
            guard let r = peer.recentReadings.last(where: {
                now.timeIntervalSince($0.timestamp) < 0.3 && $0.direction != nil
            }) else { return nil }
            let d = r.direction!               // unit vector, phone coords
            // boresight = straight out the back of the phone = -Z
            let angleOff = acos(-d.z)          // radians from boresight
            return (peer, angleOff, r.distance)
        }
        .filter { $0.1 < aimCone && $0.2 < weaponRange }
        .min(by: { $0.1 < $1.1 })?.0           // most-centered target wins
}
```

Tuning starting points (adjust in playtesting):
- `aimCone` = 12–15° (≈0.21–0.26 rad). Wider = more forgiving/fun; narrower = more skill.
- Buffer window 0.3 s of readings per peer (at 55 Hz that's ~16 samples).
- Fire cooldown 0.5 s; hit = 25 damage; 100 HP; respawn after 5 s.

On the victim's phone when `.hit` arrives: heavy haptic burst (Core Haptics transient pattern or `UIImpactFeedbackGenerator(style: .heavy)` ×3), red screen flash, HP bar drop, damage sound.

---

## 5. Indoor vs. outdoor modes

Ship two weapon presets selected in the lobby:

| Setting | Indoor (venue demo) | Outdoor |
|---|---|---|
| Weapon range | 8 m | 20 m |
| Aim cone | 15° | 10° |
| Damage | 25 | 34 (3-shot kill) |
| Notes | Expect occlusion from crowds — generous cone compensates | Line-of-sight UWB is strong; tighter cone rewards aim |

---

## 6. Build phases & timeline (~16–20 h of work, parallelizable)

### Phase 0 — Setup (1 h)
- Xcode project (SwiftUI, iOS 17+ target), team signing with free accounts.
- Info.plist: `NSNearbyInteractionUsageDescription`, `NSLocalNetworkUsageDescription`, `NSBonjourServices` (e.g. `_lasertag._tcp`), camera usage description (for camera assistance).
- Inventory devices: confirm everyone's phone is iPhone 11+ non-SE. Check `NISession.isSupported` at launch.

### Phase 1 — Lobby & networking (3 h)
- MultipeerConnectivity: host advertises, players browse/join, name entry, player list.
- Send/receive `GameMessage`. **Milestone: two phones exchange hello messages.**

### Phase 2 — Ranging (3–4 h) ⚠️ riskiest — do early
- On game start: exchange archived `NIDiscoveryToken`s, create one `NISession` per peer with `isCameraAssistanceEnabled = true`.
- `DebugRangingView`: live table of peer → distance, direction, angle-off-boresight.
- **Milestone: walk around a room, watch numbers update; verify direction goes nil when peer leaves the cone.**

### Phase 3 — Game loop (4–5 h)
- GameEngine: HP, fire/cooldown, hit resolution (§4), death/respawn, `.hit`/`.healthUpdate`/`.death` messages.
- Victim feedback: haptics + red flash + sound. Shooter feedback: hit-marker haptic tick + crosshair pulse.
- **Milestone: full 1v1 round — shoot, take damage, die, respawn.**

### Phase 4 — HUD & polish (3–4 h)
- GameHUD: big fire button, HP bar, ammo/cooldown ring, kill feed.
- **RadarView**: plot peers as blips using distance + horizontal angle — demos brilliantly.
- Death screen with respawn countdown; scoreboard at match end; sounds (pew, hit, death).
- Keep screen awake; battery note: UWB + screen ≈ heavy drain, bring chargers.

### Phase 5 — Playtest & tune (2 h)
- 4+ player game in the actual demo space. Tune cone, range, damage. Fix session-drop handling (recreate NISession on invalidation with fresh token exchange).

### Stretch goals (in order of demo value)
1. **AR crosshair mode**: ARKit camera passthrough + crosshair overlay; you're already using camera assistance, so this is close.
2. Teams (red vs. blue) with friendly-fire off.
3. Weapon classes: shotgun (wide cone, short range) vs. sniper (narrow, long, high damage).
4. Apple Watch companion buzzing on hit.
5. Spectator scoreboard: host relays state to a laptop web page via local WebSocket.

---

## 7. Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| `direction == nil` at the moment of firing | High | 0.3 s reading buffer; generous cone; camera assistance; coach players to aim like a camera |
| Body occlusion drops sessions in crowds | Medium | Auto-restart invalidated sessions; treat as gameplay ("cover") |
| Multipeer flakiness on congested venue Wi-Fi | Medium | Multipeer uses peer-to-peer Wi-Fi/Bluetooth, not the venue AP — usually fine; keep messages tiny |
| A teammate's phone lacks UWB (SE/older) | Medium | Check day 1; borrow devices; that person runs the spectator board |
| 7-day free provisioning expires mid-event | Low | Re-deploy from Xcode takes minutes |
| Battery drain | High | Chargers between rounds; dim-screen option in lobby |

---

## 8. Demo script (2 min, judges love this)

1. Two teammates join a lobby on stage, third phone mirrors to the projector showing the radar view.
2. Show live distance/direction updating as they move — "the phones know where each other are, via the same UWB chip that powers AirTag precision finding."
3. One shoots the other: victim's phone buzzes and flashes red on camera.
4. Hide behind a person → shot misses → "human shields are canon."
5. Kill, death screen, scoreboard.
