import SwiftUI
import MapKit
import SwiftData

struct FrequentPlacesMapView: View {
    @Query private var places: [Place]
    @StateObject private var viewModel = PlacesViewModel()
    @EnvironmentObject private var locationManager: LocationManager
    @State private var selectedPlace: Place?
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var cachedAnnotations: [any MapAnnotationItem] = []

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                Map(position: $cameraPosition, selection: $selectedPlace) {
                    UserAnnotation()

                    ForEach(cachedAnnotations, id: \.id) { item in
                        if let cluster = item as? ClusterItem {
                            Annotation("", coordinate: cluster.coordinate) {
                                ClusterAnnotationView(cluster: cluster)
                            }
                        } else if let single = item as? SingleItem {
                            Annotation(single.ranking.place.name, coordinate: single.coordinate) {
                                PlaceAnnotationView(ranking: single.ranking)
                            }
                            .tag(single.ranking.place)
                        }
                    }
                }
                .mapStyle(.standard(showsTraffic: false))
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .onMapCameraChange(frequency: .onEnd) { context in
                    visibleRegion = context.region
                    rebuildAnnotations()
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
                PlaceDetailSheet(place: place) {
                    selectedPlace = nil
                    viewModel.refresh(places: places)
                }
                .presentationDetents([.medium])
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                viewModel.refresh(places: places)
                rebuildAnnotations()
            }
        }
    }

    // MARK: - Clustering

    /// Rebuilds annotations only when region or data changes — not on every render.
    private func rebuildAnnotations() {
        let rankings = Array(viewModel.monthlyPlaces.prefix(50))
        guard let region = visibleRegion else {
            cachedAnnotations = rankings.map { SingleItem(ranking: $0) }
            return
        }

        let clusterRadius = region.span.latitudeDelta * 0.08
        cachedAnnotations = clusterItems(from: rankings, radius: clusterRadius)
    }

    private func clusterItems(from rankings: [PlaceRanking], radius: Double) -> [any MapAnnotationItem] {
        var used = Set<UUID>()
        var result: [any MapAnnotationItem] = []

        for ranking in rankings {
            guard !used.contains(ranking.id) else { continue }

            // Find nearby rankings within cluster radius
            var group = [ranking]
            used.insert(ranking.id)

            for other in rankings {
                guard !used.contains(other.id) else { continue }
                let latDiff = abs(ranking.place.latitude - other.place.latitude)
                let lonDiff = abs(ranking.place.longitude - other.place.longitude)
                if latDiff < radius && lonDiff < radius {
                    group.append(other)
                    used.insert(other.id)
                }
            }

            if group.count == 1 {
                result.append(SingleItem(ranking: ranking))
            } else {
                let avgLat = group.reduce(0.0) { $0 + $1.place.latitude } / Double(group.count)
                let avgLon = group.reduce(0.0) { $0 + $1.place.longitude } / Double(group.count)
                result.append(ClusterItem(
                    coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon),
                    rankings: group
                ))
            }
        }

        return result
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

// MARK: - Annotation Data Models

protocol MapAnnotationItem: Identifiable {
    var id: String { get }
    var coordinate: CLLocationCoordinate2D { get }
}

struct SingleItem: MapAnnotationItem {
    let ranking: PlaceRanking

    /// Stable ID derived from the place, so SwiftUI reuses the view.
    var id: String { "single-\(ranking.place.id)" }
    var coordinate: CLLocationCoordinate2D { ranking.place.coordinate }
}

struct ClusterItem: MapAnnotationItem {
    let coordinate: CLLocationCoordinate2D
    let rankings: [PlaceRanking]

    /// Stable ID derived from sorted member place IDs.
    var id: String {
        let memberIDs = rankings.map { $0.place.id.uuidString }.sorted().joined(separator: "+")
        return "cluster-\(memberIDs)"
    }

    var totalVisits: Int {
        rankings.reduce(0) { $0 + $1.qualifiedStays }
    }

    var topEmojis: String {
        let emojis = rankings
            .prefix(3)
            .map { PlaceCategorizer.emoji(for: $0.place.category) }
        return emojis.joined()
    }
}

// MARK: - Annotation Views

struct PlaceAnnotationView: View {
    let ranking: PlaceRanking

    var body: some View {
        VStack(spacing: 2) {
            Text(PlaceCategorizer.emoji(for: ranking.place.category))
                .font(.title)
                .frame(width: 44, height: 44)
                .background(.white)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

            Text("\(ranking.qualifiedStays)")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor)
                .clipShape(Capsule())
        }
    }
}

struct ClusterAnnotationView: View {
    let cluster: ClusterItem

    var body: some View {
        VStack(spacing: 2) {
            Text(cluster.topEmojis)
                .font(.callout)
                .frame(width: 52, height: 52)
                .background(.white)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

            Text("\(cluster.rankings.count) places")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor)
                .clipShape(Capsule())
        }
    }
}

// MARK: - Place Detail Sheet

struct PlaceDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let place: Place
    var onDelete: (() -> Void)?

    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(PlaceCategorizer.emoji(for: place.category))
                    .font(.largeTitle)

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.title2.bold())

                    if let category = place.category {
                        Text(category)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            LabeledContent("Total Visits", value: "\(place.visits.count)")
            LabeledContent("Total Time", value: "\(place.totalTrackedMinutes) min")

            if let lastVisit = place.visits.sorted(by: { $0.arrivalDate > $1.arrivalDate }).first {
                LabeledContent("Last Visit", value: lastVisit.arrivalDate.formatted(date: .abbreviated, time: .shortened))
            }

            Spacer()

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete Place", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding()
        .alert("Delete Place?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                for visit in place.visits {
                    modelContext.delete(visit)
                }
                modelContext.delete(place)
                try? modelContext.save()
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete \"\(place.name)\" and all \(place.visits.count) recorded visits? This cannot be undone.")
        }
    }
}
