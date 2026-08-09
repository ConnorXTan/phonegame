import AVFoundation
import SwiftUI
import UIKit

/// Game-master curation of the public gallery: every published clip, with a
/// two-tap delete. Deletion needs the upload secret, which lives only in the
/// app — visitors to the website can watch, like, and save, never delete.
struct ManageGalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .headline) private var skullSize: CGFloat = 18
    @State private var clips: [ReplayPublisher.GalleryClip] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var confirming: String?      // clip key awaiting the second tap
    @State private var deleting: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Loading gallery…")
                } else if let errorText {
                    VStack(spacing: Space.md) {
                        Text(errorText)
                            .foregroundStyle(Color.ltnTextSecondary)
                        Button("Retry") { load() }
                            .buttonStyle(.bordered)
                    }
                } else if clips.isEmpty {
                    Text("The gallery is empty.")
                        .foregroundStyle(Color.ltnTextSecondary)
                } else {
                    List {
                        ForEach(clips) { clip in
                            row(clip)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("Manage Gallery")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { load() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                }
            }
        }
        .font(.app(.body))
        .onAppear(perform: load)
    }

    private func row(_ clip: ReplayPublisher.GalleryClip) -> some View {
        HStack(spacing: Space.md) {
            if let url = URL(string: clip.url) {
                ClipPreview(url: url)
                    .frame(width: 76, height: 135)   // 9:16, the clips' own aspect
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    .accessibilityHidden(true)   // the title row carries the info
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.sm) {
                    Text(clip.killer)
                    Image(art: .killSkull)
                        .resizable()
                        .scaledToFit()
                        .frame(height: skullSize)
                    Text(clip.victim)
                }
                .font(.appBold(.headline))
                Text(clip.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.app(.caption2))
                    .foregroundStyle(Color.ltnTextSecondary)
            }
            Spacer()
            Label("\(clip.likes)", systemImage: "heart.fill")
                .font(.app(.caption).monospacedDigit())
                .foregroundStyle(Color.ltnTextSecondary)
            if deleting.contains(clip.key) {
                ProgressView().controlSize(.small)
            } else if confirming == clip.key {
                Button("Confirm delete") { performDelete(clip.key) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.ltnDanger)
            } else {
                Button("Delete") { confirming = clip.key }
                    .buttonStyle(.bordered)
                    .tint(Color.ltnDanger)
            }
        }
        .padding(.vertical, Space.xs)
    }

    private func load() {
        loading = true
        errorText = nil
        confirming = nil
        ReplayPublisher.fetchClips { result in
            loading = false
            switch result {
            case .success(let fetched): clips = fetched
            case .failure: errorText = "Couldn't reach the gallery."
            }
        }
    }

    private func performDelete(_ key: String) {
        confirming = nil
        deleting.insert(key)
        ReplayPublisher.deleteClip(key: key) { result in
            deleting.remove(key)
            switch result {
            case .success: clips.removeAll { $0.key == key }
            case .failure: errorText = "Delete failed — try again."
            }
        }
    }
}

/// A muted, looping, chrome-free live preview of a published clip — the row's
/// thumbnail, but playing. Layer-backed rather than AVKit's `VideoPlayer` so
/// no transport controls ever appear over a 76pt-wide cell. The list is lazy,
/// so only visible rows hold a player.
private struct ClipPreview: UIViewRepresentable {
    let url: URL

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        private(set) var url: URL?

        func configure(url: URL) {
            guard self.url != url else { return }
            self.url = url
            let player = AVQueuePlayer()
            player.isMuted = true   // previews never talk over the room
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            self.player = player
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            player.play()
        }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        view.configure(url: url)
    }
}
