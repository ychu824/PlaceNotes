import SwiftUI
import SwiftData
import MapKit

struct DayTrajectoryView: View {
    @Environment(\.modelContext) private var modelContext
    let day: Date

    @State private var segments: [TrajectorySegment] = []
    @State private var stats: TrajectoryStats?
    @State private var dayPlaces: [Place] = []
    @State private var selectedPlace: Place?
    @State private var cameraPosition: MapCameraPosition = .automatic

    private static let navTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private var isPathAvailable: Bool { !segments.isEmpty }

    private var dayRange: (start: Date, end: Date) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    var body: some View {
        ZStack {
            Map(position: $cameraPosition, selection: $selectedPlace) {
                TrajectoryPolyline(segments: segments, colorMode: .time)

                ForEach(rankings(), id: \.id) { ranking in
                    Annotation(
                        ranking.place.displayName,
                        coordinate: ranking.place.coordinate
                    ) {
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

            VStack {
                TrajectoryHeaderCard(day: day, stats: stats, isPathAvailable: isPathAvailable)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                Spacer()
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        withAnimation {
                            cameraPosition = initialCamera(segments: segments, places: dayPlaces)
                        }
                    } label: {
                        Image(systemName: "scope")
                            .font(.title3)
                            .padding(12)
                            .background(.regularMaterial)
                            .clipShape(Circle())
                            .shadow(radius: 2)
                    }
                    .padding(.trailing, 16)
                    .padding(.bottom, 24)
                }
            }

            if !isPathAvailable && dayPlaces.isEmpty {
                emptyOverlay
            }
        }
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPlace) { place in
            PlaceDetailSheet(place: place)
                .presentationDetents([.medium])
        }
        .task(id: day) {
            await load()
        }
    }

    private var navTitle: String {
        Self.navTitleFormatter.string(from: day)
    }

    private var emptyOverlay: some View {
        VStack {
            Spacer()
            Text("No location data recorded for this day")
                .font(.callout)
                .padding(12)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 32)
        }
    }

    /// Build a synthetic ranking-per-place so we can reuse PlaceAnnotationView.
    /// `qualifiedStays` and `totalMinutes` here are scoped to this day only.
    private func rankings() -> [PlaceRanking] {
        let range = dayRange
        return dayPlaces.map { place in
            let visitsToday = place.visits.filter {
                $0.arrivalDate >= range.start && $0.arrivalDate < range.end
            }
            let minutesToday = visitsToday.reduce(0) { $0 + $1.durationMinutes }
            return PlaceRanking(
                place: place,
                qualifiedStays: visitsToday.count,
                totalMinutes: minutesToday
            )
        }
    }

    private func load() async {
        let range = dayRange
        let dayStart = range.start
        let dayEnd = range.end

        let sampleDescriptor = FetchDescriptor<RawLocationSample>(
            predicate: #Predicate {
                $0.timestamp >= dayStart
                && $0.timestamp < dayEnd
                && $0.filterStatus == "accepted"
            },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let samples = (try? modelContext.fetch(sampleDescriptor)) ?? []

        let placeDescriptor = FetchDescriptor<Place>()
        let allPlaces = (try? modelContext.fetch(placeDescriptor)) ?? []
        let placesToday = allPlaces.filter { place in
            place.visits.contains { $0.arrivalDate >= dayStart && $0.arrivalDate < dayEnd }
        }

        let builtSegments = TrajectoryBuilder.build(samples: samples, day: day)
        let computedStats = TrajectoryBuilder.computeStats(
            segments: builtSegments,
            rawSampleCount: samples.count,
            placeCount: placesToday.count
        )

        self.segments = builtSegments
        self.dayPlaces = placesToday
        self.stats = computedStats
        self.cameraPosition = initialCamera(segments: builtSegments, places: placesToday)
    }

    private func initialCamera(
        segments: [TrajectorySegment],
        places: [Place]
    ) -> MapCameraPosition {
        var coords: [CLLocationCoordinate2D] = []
        coords.append(contentsOf: segments.flatMap { $0.points.map(\.coordinate) })
        coords.append(contentsOf: places.map(\.coordinate))

        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(),
              let maxLat = lats.max(),
              let minLon = lons.min(),
              let maxLon = lons.max() else {
            return .automatic
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.005, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.005, (maxLon - minLon) * 1.4)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}
