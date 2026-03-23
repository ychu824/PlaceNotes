import SwiftUI
import SwiftData
import Charts

struct ReportView: View {
    @Query private var places: [Place]
    @StateObject private var viewModel = ReportViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if let report = viewModel.report {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            ReportHeaderView(report: report)
                            TimeOfDayChartView(report: report)
                            TopPlacesSection(topPlaces: report.topPlaces)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                    }
                } else {
                    ContentUnavailableView(
                        "No Report",
                        systemImage: "chart.bar",
                        description: Text("Tap Generate to create your monthly report.")
                    )
                }
            }
            .navigationTitle("Report")
            .toolbar {
                Button("Generate") {
                    viewModel.generateReport(places: places)
                }
            }
            .onAppear {
                viewModel.generateReport(places: places)
            }
        }
    }
}

struct ReportHeaderView: View {
    let report: MonthlyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(report.month)
                .font(.title2.bold())

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                StatCard(title: "Total Visits", value: "\(report.totalVisits)", icon: "mappin")
                StatCard(title: "Total Time", value: formatMinutes(report.totalTrackedMinutes), icon: "clock")
                StatCard(title: "Top Places", value: "\(report.topPlaces.count)", icon: "star.fill")
                StatCard(title: "Most Active", value: report.preferredTimeOfDay.rawValue, icon: "sun.max.fill")
            }
        }
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 {
            return "\(hours)h \(mins)m"
        }
        return "\(mins)m"
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            Text(value)
                .font(.headline)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct TimeOfDayChartView: View {
    let report: MonthlyReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Visits by Time of Day")
                .font(.headline)

            Chart {
                ForEach(TimeOfDay.allCases, id: \.self) { time in
                    BarMark(
                        x: .value("Time", time.rawValue),
                        y: .value("Visits", report.visitsByTimeOfDay[time] ?? 0)
                    )
                    .foregroundStyle(Color.accentColor)
                    .cornerRadius(6)
                }
            }
            .frame(height: 180)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct TopPlacesSection: View {
    let topPlaces: [PlaceRanking]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top Places")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(topPlaces.enumerated()), id: \.element.id) { index, ranking in
                    HStack(spacing: 12) {
                        Text("#\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .leading)

                        Text(ranking.place.name)
                            .font(.subheadline)
                            .lineLimit(1)

                        Spacer()

                        Text("\(ranking.qualifiedStays) visits")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("\(ranking.totalMinutes)m")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(.vertical, 10)

                    if index < topPlaces.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
