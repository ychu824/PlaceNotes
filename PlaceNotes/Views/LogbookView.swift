import SwiftUI
import SwiftData

struct LogbookView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var places: [Place]
    @EnvironmentObject var settings: AppSettings
    @State private var visitForAlternatives: Visit?
    @State private var refreshID = UUID()

    private var groupedVisits: [(year: Int, months: [(month: Int, visits: [Visit])])] {
        let minStay = settings.minStayMinutes
        let allVisits = places
            .flatMap { $0.visits }
            .filter { $0.durationMinutes >= minStay }
            .sorted { $0.arrivalDate > $1.arrivalDate }

        let calendar = Calendar.current
        var yearMonthMap: [Int: [Int: [Visit]]] = [:]

        for visit in allVisits {
            let year = calendar.component(.year, from: visit.arrivalDate)
            let month = calendar.component(.month, from: visit.arrivalDate)
            yearMonthMap[year, default: [:]][month, default: []].append(visit)
        }

        return yearMonthMap
            .sorted { $0.key > $1.key }
            .map { year, months in
                let sortedMonths = months
                    .sorted { $0.key > $1.key }
                    .map { month, visits in
                        (month: month, visits: visits.sorted { $0.arrivalDate > $1.arrivalDate })
                    }
                return (year: year, months: sortedMonths)
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groupedVisits.isEmpty {
                    ContentUnavailableView(
                        "No Visits Yet",
                        systemImage: "book.closed",
                        description: Text("Your logbook will fill up as you visit places with tracking enabled.")
                    )
                } else {
                    List {
                        ForEach(groupedVisits, id: \.year) { yearGroup in
                            Section {
                                ForEach(yearGroup.months, id: \.month) { monthGroup in
                                    MonthSection(
                                        year: yearGroup.year,
                                        month: monthGroup.month,
                                        visits: monthGroup.visits,
                                        onPickAlternative: { visit in
                                            visitForAlternatives = visit
                                        }
                                    )
                                }
                            } header: {
                                Text(String(yearGroup.year))
                                    .font(.title2.bold())
                                    .foregroundStyle(.primary)
                                    .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .id(refreshID)
                    .refreshable {
                        refreshID = UUID()
                    }
                }
            }
            .navigationTitle("Logbook")
            .sheet(item: $visitForAlternatives) { visit in
                AlternativePlacePicker(visit: visit)
            }
        }
    }
}

// MARK: - Alternative Place Picker

private struct AlternativePlacePicker: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let visit: Visit

    var body: some View {
        NavigationStack {
            List {
                if let place = visit.place {
                    Section("Current") {
                        Button {
                            confirmPlace()
                        } label: {
                            HStack {
                                Image(systemName: PlaceCategorizer.icon(for: place.category))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if let category = place.category {
                                        Text(category)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text("Confirm")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }

                if !visit.alternativePlaces.isEmpty {
                    Section("Did you mean?") {
                        ForEach(visit.alternativePlaces) { candidate in
                            Button {
                                reassignVisit(to: candidate)
                            } label: {
                                HStack {
                                    Image(systemName: PlaceCategorizer.icon(for: candidate.category))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        HStack(spacing: 6) {
                                            if let category = candidate.category {
                                                Text(category)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Text("\(Int(candidate.distanceMeters))m away")
                                                .font(.caption)
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "No Alternatives",
                        systemImage: "mappin.slash",
                        description: Text("No other nearby places were found when this visit was recorded.")
                    )
                }
            }
            .navigationTitle("Wrong Place?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func confirmPlace() {
        visit.alternativePlacesData = nil
        try? modelContext.save()
        dismiss()
    }

    private func reassignVisit(to candidate: PlaceCandidate) {
        let threshold = 0.0005
        let descriptor = FetchDescriptor<Place>()
        let allPlaces = (try? modelContext.fetch(descriptor)) ?? []

        let place: Place
        if let existing = allPlaces.first(where: {
            abs($0.latitude - candidate.latitude) < threshold && abs($0.longitude - candidate.longitude) < threshold
        }) {
            place = existing
        } else {
            place = Place(
                name: candidate.name,
                latitude: candidate.latitude,
                longitude: candidate.longitude,
                category: candidate.category,
                city: candidate.city,
                state: candidate.state
            )
            modelContext.insert(place)
        }

        visit.place = place
        visit.alternativePlacesData = nil
        try? modelContext.save()
        dismiss()
    }
}

private struct MonthSection: View {
    let year: Int
    let month: Int
    let visits: [Visit]
    var onPickAlternative: ((Visit) -> Void)?

    private var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM"
        var components = DateComponents()
        components.month = month
        let date = Calendar.current.date(from: components) ?? Date()
        return formatter.string(from: date)
    }

    private var uniquePlaceCount: Int {
        Set(visits.compactMap { $0.place?.id }).count
    }

    private var totalMinutes: Int {
        visits.reduce(0) { $0 + $1.durationMinutes }
    }

    var body: some View {
        DisclosureGroup {
            ForEach(visits) { visit in
                if let place = visit.place {
                    NavigationLink {
                        PlaceDetailView(place: place)
                    } label: {
                        LogbookVisitRow(visit: visit, place: place) {
                            onPickAlternative?(visit)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        } label: {
            HStack {
                Text(monthName)
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(visits.count) visits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(uniquePlaceCount) places")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct LogbookVisitRow: View {
    let visit: Visit
    let place: Place
    var onPickAlternative: (() -> Void)?

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: visit.arrivalDate)
    }

    private var durationString: String {
        let mins = visit.durationMinutes
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(mins)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if place.customEmoji != nil {
                    Text(place.emoji)
                        .font(.title3)
                        .frame(width: 28)
                } else {
                    Image(systemName: PlaceCategorizer.icon(for: place.category))
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(place.displayName)
                        .font(.body.weight(.medium))

                    HStack(spacing: 8) {
                        if let category = place.category, !category.isEmpty {
                            Text(category)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let city = place.city {
                            Text(city)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text(dateString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(durationString)
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                    if visit.confidence == .low {
                        Label("Low confidence", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !visit.alternativePlaces.isEmpty {
                Button {
                    onPickAlternative?()
                } label: {
                    Label("Not the right place?", systemImage: "arrow.triangle.swap")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, 2)
    }
}
