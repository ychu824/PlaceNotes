import SwiftUI
import SwiftData

struct ManualPlacePickerView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Place.name) private var allPlaces: [Place]

    let onPicked: (Place) -> Void
    let onCancelled: () -> Void

    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Recent places") {
                    if filteredPlaces.isEmpty {
                        Text("No matching places")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredPlaces) { place in
                            Button {
                                onPicked(place)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(place.displayName)
                                    if let city = place.city {
                                        Text(city).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search)
            .navigationTitle("Pick a place")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancelled()
                        dismiss()
                    }
                }
            }
        }
    }

    private var filteredPlaces: [Place] {
        guard !search.isEmpty else { return Array(allPlaces.prefix(20)) }
        let needle = search.lowercased()
        return allPlaces.filter { $0.displayName.lowercased().contains(needle) }
    }
}
