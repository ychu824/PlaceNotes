import SwiftUI
import MapKit
import SwiftData

struct FrequentPlacesMapView: View {
    @Query private var places: [Place]
    @StateObject private var viewModel = PlacesViewModel()
    @EnvironmentObject private var locationManager: LocationManager
    @State private var selectedPlace: Place?
    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Map(position: $cameraPosition, selection: $selectedPlace) {
                    // User's current location
                    UserAnnotation()

                    ForEach(viewModel.monthlyPlaces.prefix(20)) { ranking in
                        Annotation(ranking.place.name, coordinate: ranking.place.coordinate) {
                            PlaceAnnotationView(ranking: ranking)
                        }
                        .tag(ranking.place)
                    }
                }
                .mapStyle(.standard(showsTraffic: false))
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }

                // Current location button
                Button {
                    goToCurrentLocation()
                } label: {
                    Image(systemName: "location.fill")
                        .font(.title3)
                        .padding(12)
                        .background(.regularMaterial)
                        .clipShape(Circle())
                        .shadow(radius: 2)
                }
                .padding(.trailing, 16)
                .padding(.bottom, 24)
            }
            .sheet(item: $selectedPlace) { place in
                PlaceDetailSheet(place: place)
                    .presentationDetents([.medium])
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { viewModel.refresh(places: places) }
        }
    }

    private func goToCurrentLocation() {
        if let coordinate = locationManager.userLocation {
            withAnimation {
                cameraPosition = .region(MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 500,
                    longitudinalMeters: 500
                ))
            }
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
