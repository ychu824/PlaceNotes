import SwiftUI
import SwiftData

struct FrequentPlacesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var places: [Place]
    @StateObject private var viewModel = PlacesViewModel()
    @State private var selectedTab: PlacesPeriod = .weekly
    @State private var placeToDelete: Place?
    @State private var showDeleteConfirmation = false
    @State private var isEditing = false
    @State private var placeToRename: Place?
    @State private var showRenameDialog = false
    @State private var renameText = ""
    @State private var placeToRecategorize: Place?

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
                    List {
                        ForEach(rankings) { ranking in
                            HStack(spacing: 12) {
                                // Visible delete button in edit mode
                                if isEditing {
                                    Button {
                                        placeToDelete = ranking.place
                                        showDeleteConfirmation = true
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }

                                PlaceRankingRow(ranking: ranking)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    placeToDelete = ranking.place
                                    showDeleteConfirmation = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    placeToRename = ranking.place
                                    renameText = ranking.place.displayName
                                    showRenameDialog = true
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.orange)

                                Button {
                                    placeToRecategorize = ranking.place
                                } label: {
                                    Label("Category", systemImage: "tag")
                                }
                                .tint(.purple)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .id(isEditing)
                    .animation(.default, value: isEditing)
                }
            }
            .navigationTitle("Frequent Places")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    let rankings = selectedTab == .weekly ? viewModel.weeklyPlaces : viewModel.monthlyPlaces
                    if !rankings.isEmpty {
                        Button(isEditing ? "Done" : "Edit") {
                            isEditing.toggle()
                        }
                    }
                }
            }
            .onAppear { viewModel.refresh(places: places) }
            .onChange(of: selectedTab) { _, _ in viewModel.refresh(places: places) }
            .onChange(of: places) { _, newPlaces in viewModel.refresh(places: newPlaces) }
            .alert("Rename Place", isPresented: $showRenameDialog) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let place = placeToRename, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                        place.nickname = renameText.trimmingCharacters(in: .whitespaces)
                        try? modelContext.save()
                        viewModel.refresh(places: places)
                    }
                    placeToRename = nil
                }
                Button("Reset to Original", role: .destructive) {
                    if let place = placeToRename {
                        place.nickname = nil
                        try? modelContext.save()
                        viewModel.refresh(places: places)
                    }
                    placeToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    placeToRename = nil
                }
            } message: {
                if let place = placeToRename {
                    Text("Original name: \(place.name)")
                }
            }
            .sheet(item: $placeToRecategorize) { place in
                CategoryPickerSheet(place: place)
                    .presentationDetents([.medium, .large])
            }
            .alert("Delete Place?", isPresented: $showDeleteConfirmation) {
                Button("Delete", role: .destructive) {
                    if let place = placeToDelete {
                        deletePlace(place)
                    }
                }
                Button("Cancel", role: .cancel) {
                    placeToDelete = nil
                }
            } message: {
                if let place = placeToDelete {
                    Text("Delete \"\(place.name)\" and all \(place.visits.count) recorded visits? This cannot be undone.")
                }
            }
        }
    }

    private func deletePlace(_ place: Place) {
        for visit in place.visits {
            modelContext.delete(visit)
        }
        modelContext.delete(place)
        try? modelContext.save()
        placeToDelete = nil
        viewModel.refresh(places: places)
    }
}

enum PlacesPeriod {
    case weekly, monthly
}

struct PlaceRankingRow: View {
    let ranking: PlaceRanking

    var body: some View {
        HStack(spacing: 12) {
            if ranking.place.customEmoji != nil {
                Text(ranking.place.emoji)
                    .font(.title3)
                    .frame(width: 28)
            } else {
                Image(systemName: PlaceCategorizer.icon(for: ranking.place.category))
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(ranking.place.displayName)
                    .font(.body.weight(.medium))

                if ranking.place.nickname != nil {
                    Text(ranking.place.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

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
