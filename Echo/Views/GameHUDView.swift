import SwiftUI

/// Full-bleed viewfinder: the camera *is* the screen. Everything else is a thin
/// overlay — a status strip, the reticle, and the fire button.
struct GameHUDView: View {
    @EnvironmentObject private var engine: GameEngine
    @Environment(\.scenePhase) private var scenePhase
    @State private var showScores = false
    @State private var showExitOptions = false
    @State private var clockPulse = false

    @ScaledMetric(relativeTo: .caption2) private var killSkullSize: CGFloat = 13
    /// Fixed-geometry heart gauge in the status strip.
    @ScaledMetric(relativeTo: .footnote) private var heartSize: CGFloat = 16
    /// Deliberately wider than the fire button — it's the situational-awareness
    /// display, so it should out-rank the control in the visual hierarchy.
    /// Width only: the map is a forward fan, so height follows its aspect.
    @ScaledMetric(relativeTo: .largeTitle) private var miniMapWidth: CGFloat = 150

    /// How long a kill toast lingers, and how many can stack before the oldest
    /// is dropped — a multi-kill flurry must not curtain off the viewfinder.
    private let killToastLifetime: TimeInterval = 10
    /// Tail of the lifetime spent fading, so it reaches zero exactly at 10 s.
    private let killToastFadeDuration: TimeInterval = 2.5
    private let maxKillToasts = 4

    var body: some View {
        ZStack {
            // What the back of the phone sees — the same ARSession UWB camera
            // assistance is running on, so aim and picture agree.
            CameraFeedView(camera: engine.camera)
            HUDScrim()

            if engine.isAlive {
                EnemyHealthbarOverlay()
                ConsumableOverlay()
                aimOverlay
            }

            VStack(spacing: Space.sm) {
                topBar
                if let alert = engine.rangingAlert {
                    Label(alert, systemImage: "exclamationmark.triangle.fill")
                        .font(.app(.caption2))
                        .foregroundStyle(Color.ltnWarning)
                        .padding(Space.sm)
                        .background(Color.ltnBackground.opacity(Alpha.strong),
                                    in: RoundedRectangle(cornerRadius: Radius.sm))
                        .padding(.horizontal)
                }
                // Minimap left; hearts then kill feed right — they share the band
                // under the status strip instead of stacking and eating the
                // viewfinder.
                HStack(alignment: .top, spacing: Space.sm) {
                    MiniMapView()
                        .frame(width: miniMapWidth, height: miniMapWidth * MiniMapView.aspect)
                        .padding(.leading, Space.xs)   // hugs the edge to offset the smaller fan
                    VStack(alignment: .trailing, spacing: Space.sm) {
                        heartGauge
                        if !engine.activeEffects.isEmpty {
                            effectBadges
                        }
                        killToasts
                    }
                    // Flush with the 28pt glyphs inside their 48pt targets above.
                    .padding(.trailing, Space.xl)
                }
                Spacer()
                FireControl()
            }

            damageOverlay

            if !engine.isAlive {
                DeathView()
            }
        }
        .statusBarHidden()
        .onAppear { engine.camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.camera.resume() }
        }
        .sheet(isPresented: $showScores) { ScoreboardView() }
        .confirmationDialog("Exit match?", isPresented: $showExitOptions,
                            titleVisibility: .visible) {
            Button("End Match") { engine.endMatchEarly() }
            Button("Leave Game", role: .destructive) { engine.leave() }
        } message: {
            Text("Ending the match takes everyone to the results. Leaving shuts the game down for all players.")
        }
    }

    // MARK: - Status strip

    private var topBar: some View {
        // Clock hard left, controls hard right, score dead center — the score
        // rides an overlay so it centers on the bar itself rather than on
        // whatever width the side clusters happen to have.
        HStack(spacing: 0) {
            HStack(spacing: Space.xs) {
                matchClock
                shieldBadge
            }

            Spacer(minLength: Space.sm)

            // Zero spacing between them: each already carries a 48pt target,
            // so extra gap would only push the row wider.
            HStack(spacing: 0) {
                hudArtButton(.leaderboard, "Leaderboard") { showScores = true }
                // The host's exit is a bigger decision than a player's — it can
                // end the match for everyone — so it routes through a dialog.
                hudArtButton(.exitGame, engine.isHost ? "Exit options" : "Leave match") {
                    if engine.isHost {
                        showExitOptions = true
                    } else {
                        engine.leave()
                    }
                }
            }
        }
        .overlay {
            // Team play: the score that decides the match outranks a personal
            // K/D (which still lives in the scoreboard).
            if engine.settings.teamPlay {
                teamScore
            } else {
                Text("K \(engine.me?.kills ?? 0) · D \(engine.me?.deaths ?? 0)")
                    .font(.app(.subheadline).monospacedDigit())
                    .foregroundStyle(Color.ltnTextSecondary)
                    .fixedSize()
                    .accessibilityLabel("\(engine.me?.kills ?? 0) kills, \(engine.me?.deaths ?? 0) deaths")
            }
        }
        .font(.app(.subheadline))
        .foregroundStyle(Color.ltnText)
        .shadow(color: Color.ltnBackground.opacity(Alpha.strong), radius: 3, y: 1)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
    }

    /// The health gauge rides the right column, directly under the leaderboard
    /// and exit glyphs — it lines the gauge up with the chrome it belongs to and
    /// clears the left column so the minimap can start a row higher.
    private var heartGauge: some View {
        HeartBar(fraction: hpFraction, total: engine.myRole.maxHP, size: heartSize)
            .shadow(color: Color.ltnBackground.opacity(Alpha.strong), radius: 3, y: 1)
            .accessibilityElement()
            .accessibilityLabel("Health")
            .accessibilityValue("\(engine.me?.hp ?? 0) of \(engine.myRole.maxHP)")
    }

    /// A HUD chrome button: `.title3` glyph on the full 44x44 HIG target, so a
    /// player in motion can hit it one-handed. `contentShape` makes the whole
    /// square tappable rather than just the glyph's own bounds.
    private func hudButton(_ symbol: String,
                           _ label: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.app(.title3))
                .frame(width: 44, height: 44)   // HIG minimum touch target
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// The same 44pt chrome target as `hudButton`, but fronted by a hand-drawn
    /// brand mark instead of an SF Symbol.
    private func hudArtButton(_ art: Art,
                              _ label: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(art: art)
                .resizable()
                .scaledToFit()
                .frame(width: 28, height: 28)   // glyph inside the 48pt target
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// Your side's kills against theirs, yours first — the "am I winning"
    /// glance. Letters echo the team names; color pairs with position so the
    /// readout survives color-deficient vision.
    private var teamScore: some View {
        let mine = engine.myTeam ?? .alpha
        let theirs = mine.other
        let myKills = engine.teamKills(mine)
        let theirKills = engine.teamKills(theirs)
        return (
            Text("\(mine.initial) \(myKills)")
                .foregroundStyle(Color.ltnTeamAlly)
            + Text(" · ")
                .foregroundStyle(Color.ltnTextTertiary)
            + Text("\(theirs.initial) \(theirKills)")
                .foregroundStyle(Color.ltnDanger)
        )
        .font(.appBold(.subheadline).monospacedDigit())
        .fixedSize()
        .accessibilityLabel("Team \(mine.displayName) \(myKills), team \(theirs.displayName) \(theirKills)")
    }

    /// Shield while spawn protection is running. Ticks on its own clock because
    /// the window lapses on a wall-clock deadline, not on a state change — and
    /// without a visible cue, absorbed shots just read as broken hit detection.
    private var shieldBadge: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let shielded = engine.isInvulnerable(at: context.date)
            Image(systemName: "shield.lefthalf.filled")
                .font(.app(.headline))
                .foregroundStyle(Color.ltnAccent)
                .opacity(shielded ? 1 : 0)
                .accessibilityLabel(shielded ? "Shielded" : "")
                .accessibilityHidden(!shielded)
        }
        .fixedSize()
    }

    private var hpFraction: CGFloat {
        CGFloat(engine.me?.hp ?? 0) / CGFloat(max(1, engine.myRole.maxHP))
    }

    /// Running consumable effects, right under the health gauge: each is its
    /// glyph ringed by the time it has left. The ring IS the countdown — at
    /// this size a ticking numeral would be noise.
    private var effectBadges: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            HStack(spacing: Space.sm) {
                ForEach(engine.activeEffects) { effect in
                    if effect.until > context.date {
                        EffectBadge(effect: effect, at: context.date)
                    }
                }
            }
        }
    }

    /// Turns red and pulses over the last 30 seconds.
    private var matchClock: some View {
        let remaining = engine.matchRemaining
        let urgent = remaining <= 30
        return Text(remaining.clockString)
            .font(.appBold(.headline).monospacedDigit())
            .foregroundStyle(urgent ? Color.ltnDanger : Color.ltnText)
            .accessibilityLabel("Match time \(remaining.clockString)")
            .opacity(urgent && clockPulse ? Alpha.muted : 1)
            .animation(urgent ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true) : .default,
                       value: clockPulse)
            .onChange(of: urgent) { _, isUrgent in clockPulse = isUrgent }
            .fixedSize()   // never let "4:50" wrap to two lines when the row tightens
    }

    /// Kills arrive as toasts that stack newest-on-top and retire themselves
    /// after `killToastLifetime`. The old feed was a static list that sat there
    /// all match, so a tag from thirty seconds ago looked exactly like one that
    /// just landed. Expiry is computed from each event's timestamp against a
    /// ticking clock — `killFeed` itself never changes, so nothing here can
    /// disturb the engine's record.
    private var killToasts: some View {
        // 0.1 s, matching the other HUD clocks: the fade is driven frame by
        // frame from each toast's age rather than by a removal transition,
        // which inside a TimelineView fires against a view the closure has
        // already rebuilt and so pops instead of fading.
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let live = engine.killFeed.filter {
                context.date.timeIntervalSince($0.timestamp) < killToastLifetime
            }
            .prefix(maxKillToasts)

            VStack(alignment: .trailing, spacing: Space.xs) {
                ForEach(Array(live.enumerated()), id: \.element.id) { index, event in
                    killToast(event, isLatest: index == 0)
                        .opacity(fadeOpacity(for: event, at: context.date))
                }
            }
            .animation(.easeOut(duration: 0.25), value: live.map(\.id))
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    /// Solid for most of its life, then a linear ramp to fully transparent
    /// right on the lifetime — a toast that dimmed the whole time would be
    /// half-legible for most of the window it exists to be read in.
    private func fadeOpacity(for event: KillEvent, at now: Date) -> Double {
        let remaining = killToastLifetime - now.timeIntervalSince(event.timestamp)
        guard remaining < killToastFadeDuration else { return 1 }
        return max(0, remaining / killToastFadeDuration)
    }

    /// A capsule so the text survives whatever the camera is pointed at; the
    /// newest is bold and full-strength so the freshest tag reads first. In
    /// team play each name carries its side's tint.
    private func killToast(_ event: KillEvent, isLatest: Bool) -> some View {
        HStack(spacing: Space.xs) {
            Text(event.killer.displayCallSign)
                .foregroundStyle(toastNameColor(event.killer, isLatest: isLatest))
            Image(art: .killSkull)
                .resizable()
                .scaledToFit()
                .frame(height: killSkullSize)
            Text(event.victim.displayCallSign)
                .foregroundStyle(toastNameColor(event.victim, isLatest: isLatest))
        }
        .font(isLatest ? .appBold(.caption2) : .app(.caption2))
        .lineLimit(1)
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(Color.ltnBackground.opacity(Alpha.heavy), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(event.killer.displayCallSign) tagged \(event.victim.displayCallSign)")
    }

    private func toastNameColor(_ name: String, isLatest: Bool) -> Color {
        guard engine.settings.teamPlay else {
            return isLatest ? .ltnText : .ltnTextSecondary
        }
        return .ltnTeam(engine.players[name]?.team, relativeTo: engine.myTeam)
    }

    // MARK: - Scope

    /// Dead center of the screen, independent of the HUD stack — the dot marks
    /// boresight, which is straight out the back of the phone. The lock reads
    /// off the reticle itself (it closes *and* turns green) plus the enemy
    /// healthbar, so no caption sits under it stealing viewfinder.
    private var aimOverlay: some View {
        ZStack {
            ScopeReticle(locked: engine.aimedTarget != nil)
            HitMarkerView(marker: engine.hitMarker)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Aim")
        .accessibilityValue(lockDescription)
    }

    /// VoiceOver's version of the lock caption — the sighted read is the
    /// reticle's own geometry, but a screen-reader player still needs the words.
    private var lockDescription: String {
        guard let target = engine.aimedTarget else {
            return engine.aimHint ?? "No target"
        }
        guard let distance = engine.ranging.latestReading(for: target)?.distance else {
            return "Locked on \(target.displayCallSign)"
        }
        return "Locked on \(target.displayCallSign), \(String(format: "%.1f meters", distance))"
    }

    // MARK: - Damage flash

    private var damageOverlay: some View {
        Color.ltnDanger
            .opacity(engine.damageFlash ? Alpha.muted : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.25), value: engine.damageFlash)
    }
}

/// One of OUR running effects: the shared ring badge at HUD size, which is
/// the one place it scales with Dynamic Type — the same badge on enemy tags
/// stays fixed-geometry like the tag it rides.
private struct EffectBadge: View {
    let effect: ActiveEffect
    let at: Date

    @ScaledMetric(relativeTo: .footnote) private var diameter: CGFloat = 30

    private var fraction: Double {
        guard effect.duration > 0 else { return 0 }
        return effect.until.timeIntervalSince(at) / effect.duration
    }

    var body: some View {
        EffectRingBadge(kind: effect.kind, fraction: fraction, diameter: diameter)
            .accessibilityElement()
            .accessibilityLabel(effect.kind.label)
            .accessibilityValue("\(max(0, Int(effect.until.timeIntervalSince(at).rounded(.up)))) seconds left")
    }
}
