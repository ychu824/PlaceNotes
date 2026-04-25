import SwiftUI

struct TrackingControlView: View {
    @EnvironmentObject var trackingViewModel: TrackingViewModel
    @EnvironmentObject var quickCapture: QuickCaptureViewModel

    @State private var showTrackingSheet = false
    @State private var showCameraPermissionAlert = false

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 32) {
                    trackingChip
                        .padding(.top, 8)

                    Spacer()

                    shutterButton

                    Text("Tap to log this place")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                .padding()

                if case let .done(payload) = quickCapture.state {
                    VStack {
                        Spacer()
                        QuickCaptureToast(
                            payload: payload,
                            onUndo: { quickCapture.undoNewVisit(payload) },
                            onSplit: { quickCapture.splitFromMerge(payload) },
                            onDismiss: { quickCapture.cancelCapture() }
                        )
                        .padding(.bottom, 24)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("PlaceNotes")
            .sheet(isPresented: $showTrackingSheet) { trackingSheet }
            .fullScreenCover(isPresented: $quickCapture.showCamera) {
                CameraPickerView(
                    onCaptured: { image, exif in
                        quickCapture.showCamera = false
                        quickCapture.photoCaptured(image: image, exifLocation: exif)
                    },
                    onCancelled: {
                        quickCapture.showCamera = false
                        quickCapture.cancelCapture()
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: Binding(
                get: { quickCapture.state == .manualPickNeeded },
                set: { newValue in
                    if !newValue, quickCapture.state == .manualPickNeeded {
                        quickCapture.cancelCapture()
                    }
                }
            )) {
                ManualPlacePickerView(
                    onPicked: { place in
                        if let id = quickCapture.pendingPhotoAssetId {
                            quickCapture.manualPlaceSelected(place, photoAssetId: id)
                        }
                    },
                    onCancelled: { quickCapture.cancelCapture() }
                )
            }
            .alert("Capture failed", isPresented: Binding(
                get: { if case .error = quickCapture.state { return true } else { return false } },
                set: { if !$0 { quickCapture.cancelCapture() } }
            )) {
                Button("OK") { quickCapture.cancelCapture() }
            } message: {
                if case let .error(msg) = quickCapture.state { Text(msg) }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var trackingChip: some View {
        Button { showTrackingSheet = true } label: {
            HStack(spacing: 6) {
                Image(systemName: chipIcon).foregroundStyle(chipColor)
                Text(trackingViewModel.statusText).font(.footnote.weight(.medium))
                if let remaining = trackingViewModel.pauseTimeRemainingText {
                    Text("·").foregroundStyle(.secondary)
                    Text(remaining).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var isBusy: Bool {
        switch quickCapture.state {
        case .idle: return false
        default: return true
        }
    }

    @ViewBuilder
    private var shutterButton: some View {
        Button {
            Task {
                if await CameraPickerView.requestCameraPermission() {
                    quickCapture.beginCapture()
                } else {
                    showCameraPermissionAlert = true
                }
            }
        } label: {
            ZStack {
                Circle().fill(.white).frame(width: 96, height: 96)
                Circle().stroke(.primary, lineWidth: 4).frame(width: 112, height: 112)
            }
        }
        .disabled(isBusy)
        .buttonStyle(.plain)
        .alert("Camera access needed", isPresented: $showCameraPermissionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Enable Camera access in Settings → PlaceNotes to capture photos.")
        }
    }

    @ViewBuilder
    private var trackingSheet: some View {
        VStack(spacing: 16) {
            Text("Tracking")
                .font(.title2.bold())
                .padding(.top, 16)

            if trackingViewModel.trackingManager.state.status == .disabled {
                Button {
                    trackingViewModel.enable()
                    showTrackingSheet = false
                } label: {
                    Label("Enable Tracking", systemImage: "location.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else if trackingViewModel.trackingManager.state.isPaused {
                Button {
                    trackingViewModel.resume()
                    showTrackingSheet = false
                } label: {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                VStack(spacing: 8) {
                    Text("Pause for…").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        ForEach(PauseDuration.allCases, id: \.label) { duration in
                            Button(duration.label) {
                                trackingViewModel.pause(for: duration)
                                showTrackingSheet = false
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                Button(role: .destructive) {
                    trackingViewModel.disable()
                    showTrackingSheet = false
                } label: {
                    Label("Disable Tracking", systemImage: "location.slash.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding()
        .presentationDetents([.height(260)])
    }

    // MARK: - Chip styling

    private var chipIcon: String {
        switch trackingViewModel.trackingManager.state.status {
        case .active: return "location.fill"
        case .paused: return "pause.circle.fill"
        case .disabled: return "location.slash"
        }
    }

    private var chipColor: Color {
        switch trackingViewModel.trackingManager.state.status {
        case .active: return .green
        case .paused: return .orange
        case .disabled: return .secondary
        }
    }
}
