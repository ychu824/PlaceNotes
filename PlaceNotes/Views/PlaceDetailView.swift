import SwiftUI

struct PlaceDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let place: Place

    @State private var showNewEntry = false
    @State private var entryToEdit: JournalEntry?
    @State private var entryToDelete: JournalEntry?
    @State private var showDeleteConfirmation = false

    private var sortedEntries: [JournalEntry] {
        place.journalEntries.sorted { $0.date > $1.date }
    }

    private var allPhotoFilenames: [String] {
        place.journalEntries.flatMap { $0.photoAssetIdentifiers }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Place header
                placeHeader

                // Stats row
                statsRow

                Divider()

                // Photos overview
                if !allPhotoFilenames.isEmpty {
                    photosSection
                    Divider()
                }

                // Journal entries
                journalSection
            }
            .padding()
        }
        .navigationTitle(place.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNewEntry = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showNewEntry) {
            JournalEntryEditorView(place: place)
        }
        .sheet(item: $entryToEdit) { entry in
            JournalEntryEditorView(place: place, existingEntry: entry)
        }
        .alert("Delete Entry?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let entry = entryToDelete {
                    modelContext.delete(entry)
                    try? modelContext.save()
                    entryToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                entryToDelete = nil
            }
        } message: {
            Text("This journal entry will be permanently deleted.")
        }
    }

    // MARK: - Place Header

    private var placeHeader: some View {
        HStack(spacing: 14) {
            Text(place.emoji)
                .font(.system(size: 44))

            VStack(alignment: .leading, spacing: 4) {
                Text(place.displayName)
                    .font(.title2.bold())

                if place.nickname != nil {
                    Text(place.name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    if let category = place.category {
                        Text(category)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let city = place.city {
                        Text(city)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(value: "\(place.visits.count)", label: "Visits")
            Spacer()
            statItem(value: formatDuration(place.totalTrackedMinutes), label: "Total Time")
            Spacer()
            statItem(value: "\(place.journalEntries.count)", label: "Entries")
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(minutes)m"
    }

    // MARK: - Photos Section

    private var photosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Photos")
                .font(.headline)

            PhotoGridView(photoFilenames: Array(allPhotoFilenames.prefix(6)))
        }
    }

    // MARK: - Journal Section

    private var journalSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Journal")
                    .font(.headline)
                Spacer()
                Button {
                    showNewEntry = true
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                }
            }

            if sortedEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "book")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("No journal entries yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Tap + to write about this place")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                ForEach(sortedEntries) { entry in
                    JournalEntryCard(entry: entry) {
                        entryToEdit = entry
                    } onDelete: {
                        entryToDelete = entry
                        showDeleteConfirmation = true
                    }
                }
            }
        }
    }

}

// MARK: - Journal Entry Card

struct JournalEntryCard: View {
    let entry: JournalEntry
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Photos
            if !entry.photoAssetIdentifiers.isEmpty {
                PhotoGridView(photoFilenames: entry.photoAssetIdentifiers)
            }

            // Title
            if !entry.title.isEmpty {
                Text(entry.title)
                    .font(.headline)
            }

            // Body
            if !entry.body.isEmpty {
                Text(entry.body)
                    .font(.body)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(8)
            }

            // Date and actions
            HStack {
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Menu {
                    Button {
                        onEdit()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
