import SwiftUI

struct TrackingControlView: View {
    @EnvironmentObject var trackingViewModel: TrackingViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer()

                // Status indicator
                VStack(spacing: 16) {
                    Image(systemName: statusIcon)
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(statusColor)
                        .symbolEffect(.pulse, isActive: trackingViewModel.trackingManager.state.status == .active)

                    Text(trackingViewModel.statusText)
                        .font(.title2.bold())

                    if let remaining = trackingViewModel.pauseTimeRemainingText {
                        Text(remaining)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                    }
                }

                Spacer()
                Spacer()

                // Controls
                VStack(spacing: 16) {
                    if trackingViewModel.trackingManager.state.status == .disabled {
                        Button {
                            trackingViewModel.enable()
                        } label: {
                            Label("Enable Tracking", systemImage: "location.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else if trackingViewModel.trackingManager.state.isPaused {
                        Button {
                            trackingViewModel.resume()
                        } label: {
                            Label("Resume Now", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        // Active — show pause options and disable
                        VStack(spacing: 12) {
                            Text("Pause Tracking")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 10) {
                                ForEach(PauseDuration.allCases, id: \.label) { duration in
                                    Button(duration.label) {
                                        trackingViewModel.pause(for: duration)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }

                        Button(role: .destructive) {
                            trackingViewModel.disable()
                        } label: {
                            Label("Disable Tracking", systemImage: "location.slash.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationTitle("PlaceNotes")
        }
    }

    private var statusIcon: String {
        switch trackingViewModel.trackingManager.state.status {
        case .active: return "location.fill"
        case .disabled: return "location.slash"
        case .paused: return "pause.circle.fill"
        }
    }

    private var statusColor: Color {
        switch trackingViewModel.trackingManager.state.status {
        case .active: return .green
        case .disabled: return .secondary
        case .paused: return .orange
        }
    }
}
