import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject var trackingViewModel: TrackingViewModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        TabView {
            TrackingControlView()
                .tabItem {
                    Label("Tracking", systemImage: "location.fill")
                }

            FrequentPlacesView()
                .tabItem {
                    Label("Places", systemImage: "mappin.and.ellipse")
                }

            FrequentPlacesMapView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }

            ReportView()
                .tabItem {
                    Label("Report", systemImage: "chart.bar.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .tint(.accentColor)
    }
}
