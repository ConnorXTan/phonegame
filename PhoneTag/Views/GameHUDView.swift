import SwiftUI

struct GameHUDView: View {
    @EnvironmentObject private var engine: GameEngine
    @State private var showDebug = false
    @State private var showScores = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 8) {
                topBar
                if let alert = engine.rangingAlert {
                    Label(alert, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(8)
                        .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                }
                killFeedView
                Spacer()
                if engine.isAlive { targetIndicator }
                Spacer()
                RadarView()
                    .frame(height: 170)
                    .padding(.horizontal)
                fireControl
            }

            damageOverlay

            if !engine.isAlive {
                DeathView()
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showDebug) { DebugRangingView() }
        .sheet(isPresented: $showScores) { ScoreboardView() }
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Text(engine.myName.displayCallSign.uppercased())
                    .font(.caption.bold())
                Spacer()
                Text("K \(engine.me?.kills ?? 0) · D \(engine.me?.deaths ?? 0)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { showScores = true } label: {
                    Image(systemName: "list.number")
                }
                Button { showDebug = true } label: {
                    Image(systemName: "waveform.badge.magnifyingglass")
                }
                Button { engine.leave() } label: {
                    Image(systemName: "xmark.circle")
                }
            }
            .foregroundStyle(.white)

            GeometryReader { geo in
                let frac = CGFloat(engine.me?.hp ?? 0) / CGFloat(max(1, engine.settings.maxHP))
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(frac > 0.5 ? Color.green : frac > 0.25 ? Color.orange : Color.red)
                        .frame(width: geo.size.width * max(0, frac))
                }
                .animation(.easeOut(duration: 0.2), value: frac)
            }
            .frame(height: 10)

            HStack {
                Text("HP \(engine.me?.hp ?? 0)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(engine.settings.mode == .indoor ? "INDOOR · 8 m" : "OUTDOOR · 20 m")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var killFeedView: some View {
        VStack(alignment: .trailing, spacing: 2) {
            ForEach(engine.killFeed.prefix(4)) { event in
                Text("\(event.killer.displayCallSign)  ⚡︎  \(event.victim.displayCallSign)")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal)
    }

    // MARK: - Crosshair

    private var targetIndicator: some View {
        VStack(spacing: 10) {
            Image(systemName: engine.aimedTarget != nil ? "scope" : "plus")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(engine.aimedTarget != nil ? Color.red : Color.white.opacity(0.35))
                .scaleEffect(engine.aimedTarget != nil ? 1.15 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: engine.aimedTarget)

            Text(engine.aimedTarget.map { "LOCKED · \($0.displayCallSign.uppercased())" }
                 ?? "hold phone up — the BACK faces your target")
                .font(.footnote.weight(engine.aimedTarget != nil ? .bold : .regular))
                .foregroundStyle(engine.aimedTarget != nil ? Color.red : Color.secondary)
        }
    }

    // MARK: - Fire button

    private var fireControl: some View {
        Button(action: engine.fire) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let progress = cooldownProgress(at: context.date)
                ZStack {
                    Circle()
                        .fill(engine.isAlive ? Color.red : Color.gray)
                        .shadow(color: .red.opacity(progress >= 1 ? 0.6 : 0), radius: 12)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(4)
                    Text("FIRE")
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: 116, height: 116)
        .disabled(!engine.isAlive)
        .padding(.bottom, 20)
    }

    private func cooldownProgress(at date: Date) -> CGFloat {
        guard let last = engine.lastFireTime else { return 1 }
        return CGFloat(min(1, date.timeIntervalSince(last) / engine.settings.fireCooldown))
    }

    // MARK: - Damage flash

    private var damageOverlay: some View {
        Color.red
            .opacity(engine.damageFlash ? 0.5 : 0)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.25), value: engine.damageFlash)
    }
}
