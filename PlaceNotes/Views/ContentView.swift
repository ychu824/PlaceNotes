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
    }
}
