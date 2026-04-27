import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject var trackingViewModel: TrackingViewModel
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var quickCapture: QuickCaptureViewModel

    var body: some View {
        TabView {
            TrackingControlView()
                .tabItem {
                    Label("Tracking", systemImage: "location.fill")
                }

            LogbookView()
                .tabItem {
                    Label("Logbook", systemImage: "book.fill")
                }

            FrequentPlacesMapView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }

            SearchPlacesView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .tint(.accentColor)
        .overlay(alignment: .top) {
            if quickCapture.isWorkingInBackground {
                BackgroundWorkPill(state: quickCapture.state)
                    .padding(.top, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: quickCapture.isWorkingInBackground)
    }
}

private struct BackgroundWorkPill: View {
    let state: QuickCaptureViewModel.State

    private var label: String {
        switch state {
        case .savingPhoto: return "Saving photo…"
        case .resolvingPlace: return "Resolving place…"
        default: return ""
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 3, y: 1)
    }
}
