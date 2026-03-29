import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var trackingViewModel: TrackingViewModel

    @State private var pendingMinStay: Int?
    @State private var showConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Minimum Stay")
                                .font(.body)
                            Spacer()
                            Text("\(settings.minStayMinutes) min")
                                .font(.body.bold())
                                .foregroundStyle(Color.accentColor)
                        }

                        Stepper(
                            value: Binding(
                                get: { pendingMinStay ?? settings.minStayMinutes },
                                set: { newValue in
                                    pendingMinStay = newValue
                                    showConfirmation = true
                                }
                            ),
                            in: 1...120,
                            step: 1
                        ) {
                            EmptyView()
                        }
                    }
                } header: {
                    Text("Stay Threshold")
                } footer: {
                    Text("Controls both when a visit is recorded and which visits count as qualified stays. A lower value records more places but may include brief stops.")
                }

                Section {
                    ForEach(Array(settings.milestoneVisitCounts), id: \.self) { count in
                        HStack {
                            Image(systemName: "bell.fill")
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)
                            Text("Visit #\(count)")
                        }
                    }
                } header: {
                    Text("Milestone Notifications")
                } footer: {
                    Text("You'll be notified when any place reaches these visit counts.")
                }

                Section("Tracking Status") {
                    LabeledContent("Status", value: trackingViewModel.statusText)

                    if let remaining = trackingViewModel.pauseTimeRemainingText {
                        LabeledContent("Resumes", value: remaining)
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                    LabeledContent("Storage", value: "On-device only")
                }
            }
            .navigationTitle("Settings")
            .alert("Change Minimum Stay?", isPresented: $showConfirmation) {
                Button("Apply") {
                    if let newValue = pendingMinStay {
                        settings.minStayMinutes = newValue
                    }
                    pendingMinStay = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingMinStay = nil
                }
            } message: {
                if let newValue = pendingMinStay {
                    Text("Change minimum stay from \(settings.minStayMinutes) min to \(newValue) min?\n\nThis affects both when visits are recorded and which visits appear in your reports.")
                }
            }
        }
    }
}
