import SwiftUI
import MapKit
import SwiftData

struct FrequentPlacesMapView: View {
    @Query private var places: [Place]
    @StateObject private var viewModel = PlacesViewModel()
    @State private var selectedPlace: Place?
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            Map(position: $cameraPosition, selection: $selectedPlace) {
                ForEach(viewModel.monthlyPlaces.prefix(20)) { ranking in
                    Annotation(ranking.place.name, coordinate: ranking.place.coordinate) {
                        PlaceAnnotationView(ranking: ranking)
                    }
                    .tag(ranking.place)
                }
            }
            .mapStyle(.standard)
            .sheet(item: $selectedPlace) { place in
                PlaceDetailSheet(place: place)
                    .presentationDetents([.medium])
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { viewModel.refresh(places: places) }
        }
    }
}

struct PlaceAnnotationView: View {
    let ranking: PlaceRanking

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: PlaceCategorizer.icon(for: ranking.place.category))
                .font(.title)
                .foregroundStyle(.red)

            Text("\(ranking.qualifiedStays)")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
        }
    }
}

struct PlaceDetailSheet: View {
    let place: Place

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(place.name)
                .font(.title2.bold())

            if let category = place.category {
                Label(category, systemImage: PlaceCategorizer.icon(for: category))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            LabeledContent("Total Visits", value: "\(place.visits.count)")
            LabeledContent("Total Time", value: "\(place.totalTrackedMinutes) min")

            if let lastVisit = place.visits.sorted(by: { $0.arrivalDate > $1.arrivalDate }).first {
                LabeledContent("Last Visit", value: lastVisit.arrivalDate.formatted(date: .abbreviated, time: .shortened))
            }

            Spacer()
        }
        .padding()
    }
}
