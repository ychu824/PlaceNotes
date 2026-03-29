import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var trackingViewModel: TrackingViewModel

    @State private var showMinStayInput = false
    @State private var minStayInputText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        minStayInputText = "\(settings.minStayMinutes)"
                        showMinStayInput = true
                    } label: {
                        HStack {
                            Text("Minimum Stay")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(settings.minStayMinutes) min")
                                .font(.body.bold())
                                .foregroundStyle(Color.accentColor)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
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
            .alert("Set Minimum Stay", isPresented: $showMinStayInput) {
                TextField("Minutes", text: $minStayInputText)
                    .keyboardType(.numberPad)

                Button("Apply") {
                    applyMinStay()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter the minimum number of minutes a visit must last to be recorded (1–1440).\n\nCurrently set to \(settings.minStayMinutes) min.")
            }
        }
    }

    private func applyMinStay() {
        guard let value = Int(minStayInputText),
              value >= 1, value <= 1440 else {
            return
        }
        settings.minStayMinutes = value
    }
}
