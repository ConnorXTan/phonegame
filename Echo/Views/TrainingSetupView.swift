import SwiftUI

/// Loadout pick on the way into the solo range. A sheet rather than another
/// control on the menu: the choice belongs to one destination, and the menu
/// already carries the name field and four buttons.
///
/// Difficulty isn't here — it's picked inside the range by shooting a console
/// orb, which keeps the phone up and drills the trigger from the first tap.
struct TrainingSetupView: View {
    @EnvironmentObject private var engine: GameEngine
    @Environment(\.dismiss) private var dismiss

    /// Local until Enter Range commits it, so backing out of the sheet can't
    /// quietly change the loadout the player takes into a real match.
    @State private var role: PlayerRole

    init(role: PlayerRole) {
        _role = State(initialValue: role)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("LOADOUT")
                        .font(.appBold(.caption))
                        .foregroundStyle(Color.ltnTextSecondary)
                    Picker("Loadout", selection: $role) {
                        ForEach(PlayerRole.allCases) { role in
                            Text(role.label).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(role.blurb)
                        .font(.app(.footnote))
                        .foregroundStyle(Color.ltnTextSecondary)
                    Text(loadoutLine)
                        .font(.app(.footnote).monospacedDigit())
                        .foregroundStyle(Color.ltnTextTertiary)
                }

                Text("Thirty drones pop up one after another in a frontal arc, three at a time. Four hits drops one whatever you're carrying — so what changes between loadouts is how fast you can put four rounds on it, and how often you're reloading instead of shooting.")
                    .font(.app(.footnote))
                    .foregroundStyle(Color.ltnTextSecondary)

                Spacer()

                Button {
                    // Dismiss first: committing flips the phase, which tears
                    // the presenting menu out from under this sheet.
                    dismiss()
                    engine.enterTraining(as: role)
                } label: {
                    Text("Enter Range")
                        .font(.appBold(.headline))
                        .foregroundStyle(Color.ltnOnPrimary)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Color.ltnPrimary)
            }
            .padding(Space.xl)
            .navigationTitle("Training Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .font(.app(.body))
    }

    /// The four numbers that actually change how the drill plays. Unlabeled
    /// units where the format already says it — "16 rds" needs no "magazine".
    private var loadoutLine: String {
        let cadence = String(format: "%.2gs", role.fireCooldown)
        let reload = String(format: "%.2gs", role.reloadDuration)
        return "\(role.maxHP) hearts · \(cadence) per shot · \(role.magazineSize) rds · \(reload) reload"
    }
}
