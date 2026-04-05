import SwiftUI
import SwiftData

struct LogbookView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var places: [Place]
    @EnvironmentObject var settings: AppSettings

    private var groupedVisits: [(year: Int, months: [(month: Int, visits: [Visit])])] {
        let minStay = settings.minStayMinutes
        let allVisits = places
            .flatMap { $0.visits }
            .filter { $0.departureDate != nil && $0.durationMinutes >= minStay }
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
                                        visits: monthGroup.visits
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
                }
            }
            .navigationTitle("Logbook")
        }
    }
}

private struct MonthSection: View {
    let year: Int
    let month: Int
    let visits: [Visit]

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
                    LogbookVisitRow(visit: visit, place: place)
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
            }
        }
        .padding(.vertical, 2)
    }
}
