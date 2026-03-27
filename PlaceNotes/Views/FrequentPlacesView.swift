import SwiftUI
import SwiftData

struct FrequentPlacesView: View {
    @Query private var places: [Place]
    @StateObject private var viewModel = PlacesViewModel()
    @State private var selectedTab: PlacesPeriod = .weekly

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Period", selection: $selectedTab) {
                    Text("Weekly").tag(PlacesPeriod.weekly)
                    Text("Monthly").tag(PlacesPeriod.monthly)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                let rankings = selectedTab == .weekly ? viewModel.weeklyPlaces : viewModel.monthlyPlaces

                if rankings.isEmpty {
                    Spacer()
                    ContentUnavailableView(
                        "No Places Yet",
                        systemImage: "mappin.slash",
                        description: Text("Visit places with tracking enabled to see your frequent spots.")
                    )
                    Spacer()
                } else {
                    List(rankings) { ranking in
                        PlaceRankingRow(ranking: ranking)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Frequent Places")
            .onAppear { viewModel.refresh(places: places) }
            .onChange(of: selectedTab) { _, _ in viewModel.refresh(places: places) }
        }
    }
}

enum PlacesPeriod {
    case weekly, monthly
}

struct PlaceRankingRow: View {
    let ranking: PlaceRanking

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: PlaceCategorizer.icon(for: ranking.place.category))
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(ranking.place.name)
                    .font(.body.weight(.medium))

                if let category = ranking.place.category, !category.isEmpty {
                    Text(category)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(ranking.qualifiedStays) visits")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.accentColor)
                Text("\(ranking.totalMinutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
