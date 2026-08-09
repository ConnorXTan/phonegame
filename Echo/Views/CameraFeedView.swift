import ARKit
import SwiftUI
import UIKit

/// Live viewfinder behind the HUD. Renders the ARSession that also feeds UWB
/// camera assistance (see AimCameraManager) — never its own capture session.
struct CameraFeedView: View {
    @ObservedObject var camera: AimCameraManager

    var body: some View {
        ZStack {
            Color.echoBackground
            if camera.isRunning {
                ARViewfinder(session: camera.session)
                    .transition(.opacity)
            } else {
                unavailablePanel
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: camera.isRunning)
    }

    private var unavailablePanel: some View {
        VStack(spacing: Space.md) {
            Image(systemName: "video.slash")
                .font(.system(size: glyphSize, weight: .thin))
                .foregroundStyle(Color.echoTextTertiary)
                .accessibilityHidden(true)
            if let reason = camera.unavailableReason {
                Text(reason)
                    .font(.app(.footnote))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.echoTextSecondary)
                    .frame(maxWidth: 280)
            }
            if camera.isBlockedByPermission {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .font(.app(.footnote).bold())
                .buttonStyle(.bordered)
                .tint(Color.echoPrimary)
            }
        }
        .padding(.bottom, 120)   // clear of the radar and fire button
    }

    @ScaledMetric(relativeTo: .largeTitle) private var glyphSize: CGFloat = 34
}

/// ARSCNView draws the camera background for a session it doesn't own; the
/// scene stays empty because the HUD is drawn in SwiftUI on top.
private struct ARViewfinder: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        view.isUserInteractionEnabled = false
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFill
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        if view.session !== session { view.session = session }
    }

    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) {
        // The session outlives this view (UWB keeps using it) — just stop
        // rendering, don't pause it.
        view.scene.isPaused = true
    }
}
