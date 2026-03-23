import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var trackingViewModel: TrackingViewModel

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
                            value: $settings.minStayMinutes,
                            in: 1...120,
                            step: 5
                        ) {
                            EmptyView()
                        }
                    }
                } header: {
                    Text("Stay Threshold")
                } footer: {
                    Text("Only visits lasting at least \(settings.minStayMinutes) minutes count as qualified stays.")
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
        }
    }
}
