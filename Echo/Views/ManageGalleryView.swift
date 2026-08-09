import SwiftUI

/// Game-master curation of the public gallery: every published clip, with a
/// two-tap delete. Deletion needs the upload secret, which lives only in the
/// app — visitors to the website can watch, like, and save, never delete.
struct ManageGalleryView: View {
    @Environment(\.dismiss) private var dismiss
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
                            .foregroundStyle(Color.echoTextSecondary)
                        Button("Retry") { load() }
                            .buttonStyle(.bordered)
                    }
                } else if clips.isEmpty {
                    Text("The gallery is empty.")
                        .foregroundStyle(Color.echoTextSecondary)
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
        .onAppear(perform: load)
    }

    private func row(_ clip: ReplayPublisher.GalleryClip) -> some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                (
                    Text(clip.killer)
                    + Text("  \(Image(systemName: "bolt.fill"))  ")
                    + Text(clip.victim)
                )
                .font(.headline)
                Text(clip.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(Color.echoTextSecondary)
            }
            Spacer()
            Label("\(clip.likes)", systemImage: "heart.fill")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.echoTextSecondary)
            if deleting.contains(clip.key) {
                ProgressView().controlSize(.small)
            } else if confirming == clip.key {
                Button("Confirm delete") { performDelete(clip.key) }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.echoDanger)
            } else {
                Button("Delete") { confirming = clip.key }
                    .buttonStyle(.bordered)
                    .tint(Color.echoDanger)
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
