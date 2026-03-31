import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var places: [Place]
    @Query private var visits: [Visit]
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var trackingViewModel: TrackingViewModel

    @State private var showMinStayInput = false
    @State private var minStayInputText = ""
    @State private var showClearDataConfirmation = false
    @State private var storageSizeText = "Calculating…"

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

                Section {
                    LabeledContent("Places", value: "\(places.count)")
                    LabeledContent("Visits", value: "\(visits.count)")
                    LabeledContent("Total Tracked Time", value: totalTrackedTimeText)
                    LabeledContent("Storage Used", value: storageSizeText)
                        .onAppear { refreshStorageSize() }
                        .onChange(of: places.count) { refreshStorageSize() }
                        .onChange(of: visits.count) { refreshStorageSize() }
                } header: {
                    Text("Data Storage")
                } footer: {
                    Text("All data is stored on-device only.")
                }

                Section {
                    Button(role: .destructive) {
                        showClearDataConfirmation = true
                    } label: {
                        HStack {
                            Spacer()
                            Text("Delete All Data")
                            Spacer()
                        }
                    }
                    .disabled(places.isEmpty && visits.isEmpty)
                }

                Section("About") {
                    LabeledContent("Version", value: "1.0.0")
                }
            }
            .navigationTitle("Settings")
            .alert("Delete All Data?", isPresented: $showClearDataConfirmation) {
                Button("Delete All", role: .destructive) {
                    clearAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete all \(places.count) places and \(visits.count) visits. This cannot be undone.")
            }
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

    private func clearAllData() {
        for visit in visits {
            modelContext.delete(visit)
        }
        for place in places {
            modelContext.delete(place)
        }
        try? modelContext.save()
    }

    private func refreshStorageSize() {
        storageSizeText = estimateDataSize()
    }

    /// Estimates storage used by tracked places data only.
    /// Each Place row: UUID (16B) + name ~50B + nickname ~50B + lat/lon 16B + category ~20B ≈ 152B
    /// Each Visit row: UUID (16B) + 2 dates 16B + foreign key 16B ≈ 48B
    /// SQLite overhead ~40% for indexes, page alignment, etc.
    private func estimateDataSize() -> String {
        let placeBytes = places.reduce(0) { total, place in
            var bytes = 16  // UUID
            bytes += (place.name.utf8.count)
            bytes += (place.nickname?.utf8.count ?? 0)
            bytes += 16     // latitude + longitude (Double x2)
            bytes += (place.category?.utf8.count ?? 0)
            return total + bytes
        }

        let visitBytes = visits.reduce(0) { total, _ in
            // UUID + arrivalDate + departureDate + foreign key
            total + 16 + 8 + 8 + 16
        }

        let rawBytes = placeBytes + visitBytes
        // Account for SQLite overhead (indexes, page headers, alignment)
        let estimatedBytes = Int64(Double(rawBytes) * 1.4)

        if estimatedBytes == 0 {
            return "0 KB"
        }

        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(estimatedBytes, 1))
    }

    private var totalTrackedTimeText: String {
        let totalMinutes = places.reduce(0) { $0 + $1.totalTrackedMinutes }
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        return mins > 0 ? "\(hours) hr \(mins) min" : "\(hours) hr"
    }
}
