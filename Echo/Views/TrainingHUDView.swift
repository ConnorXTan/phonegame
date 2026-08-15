import SwiftUI

/// The range's HUD: viewfinder, reticle, FIRE cluster — the match HUD's
/// trigger feel with the multiplayer chrome stripped away. The drill itself
/// (console orbs, counter, drones) floats in world space via TrainingOverlay;
/// the only flat chrome is the exit control and a score chip, so progress
/// survives facing away from the console.
struct TrainingHUDView: View {
    @EnvironmentObject private var engine: GameEngine
    @ObservedObject var range: TrainingRange
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CameraFeedView(camera: engine.camera)
            HUDScrim()
            TrainingOverlay(range: range, camera: engine.camera)
            aimOverlay

            VStack(spacing: Space.sm) {
                topBar
                if range.state == .placing, engine.camera.isRunning {
                    placingHint
                }
                Spacer()
                FireControl()
            }
        }
        .statusBarHidden()
        .onAppear { engine.camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.camera.resume() }
        }
    }

    /// Exit hard right; the score chip rides an overlay so it centers on the
    /// bar itself, mirroring the match HUD's layout grammar.
    private var topBar: some View {
        HStack {
            Spacer()
            Button { engine.exitTraining() } label: {
                Image(art: .exitGame)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)   // glyph inside the 48pt target
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Leave training")
        }
        .overlay {
            // The world-anchored counter is the primary readout; this chip is
            // the glance that works while the console is behind you.
            if range.state == .running || range.state == .finished {
                Text("\(range.kills) / \(TrainingRange.dronesPerRun)")
                    .font(.appBold(.subheadline).monospacedDigit())
                    .foregroundStyle(Color.ltnText)
                    .fixedSize()
                    .accessibilityLabel("\(range.kills) of \(TrainingRange.dronesPerRun) drones down")
            }
        }
        .shadow(color: Color.ltnBackground.opacity(Alpha.strong), radius: 3, y: 1)
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.sm)
    }

    /// ARKit needs a little parallax before the console can anchor.
    private var placingHint: some View {
        Label("Mapping the room — sweep the phone slowly", systemImage: "arrow.left.arrow.right")
            .font(.app(.caption2))
            .foregroundStyle(Color.ltnTextSecondary)
            .padding(Space.sm)
            .background(Color.ltnBackground.opacity(Alpha.strong),
                        in: RoundedRectangle(cornerRadius: Radius.sm))
            .padding(.horizontal)
    }

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

    private var lockDescription: String {
        guard let id = engine.aimedTarget,
              let name = range.displayName(for: id) else { return "No target" }
        return "Locked on \(name)"
    }
}
