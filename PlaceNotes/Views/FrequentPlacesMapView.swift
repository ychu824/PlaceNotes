import SwiftUI
import MapKit
import SwiftData
import UIKit

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
                            Annotation(single.ranking.place.displayName, coordinate: single.coordinate) {
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
                    rebuildAnnotations()
                }
                .presentationDetents([.medium])
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                viewModel.refresh(places: places)
                rebuildAnnotations()
            }
            .onChange(of: places) { _, newPlaces in
                viewModel.refresh(places: newPlaces)
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
            .map { $0.place.emoji }
        return emojis.joined()
    }
}

// MARK: - Annotation Views

struct PlaceAnnotationView: View {
    let ranking: PlaceRanking

    var body: some View {
        VStack(spacing: 2) {
            Text(ranking.place.emoji)
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
    @State private var showRenameDialog = false
    @State private var renameText = ""
    @State private var showCategoryPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(place.emoji)
                    .font(.largeTitle)

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.displayName)
                        .font(.title2.bold())

                    if place.nickname != nil {
                        Text(place.name)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

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

            HStack(spacing: 12) {
                Button {
                    renameText = place.displayName
                    showRenameDialog = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    showCategoryPicker = true
                } label: {
                    Label("Category", systemImage: "tag")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

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
        .sheet(isPresented: $showCategoryPicker) {
            CategoryPickerSheet(place: place)
                .presentationDetents([.medium, .large])
        }
        .alert("Rename Place", isPresented: $showRenameDialog) {
            TextField("Name", text: $renameText)
            Button("Save") {
                let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    place.nickname = trimmed
                    try? modelContext.save()
                }
            }
            Button("Reset to Original", role: .destructive) {
                place.nickname = nil
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Original name: \(place.name)")
        }
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
            Text("Delete \"\(place.displayName)\" and all \(place.visits.count) recorded visits? This cannot be undone.")
        }
    }
}

// MARK: - Category Picker Sheet

struct CategoryPickerSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let place: Place

    @State private var showCustomCategory = false
    @State private var customName = ""
    @State private var customEmoji = ""

    private let columns = [GridItem(.adaptive(minimum: 72))]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Current category
                    HStack(spacing: 8) {
                        Text(place.emoji)
                            .font(.title)
                        Text(place.category ?? "Uncategorized")
                            .font(.headline)
                        Spacer()
                        Text("Current")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Built-in categories
                    Text("Built-in Categories")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(PlaceCategorizer.categoryMap, id: \.label) { entry in
                            let isSelected = place.category == entry.label && place.customEmoji == nil
                            Button {
                                place.category = entry.label
                                place.customEmoji = nil
                                try? modelContext.save()
                                dismiss()
                            } label: {
                                VStack(spacing: 4) {
                                    Text(PlaceCategorizer.emoji(for: entry.label))
                                        .font(.title2)
                                    Text(entry.label)
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Custom category
                    Text("Custom Category")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)

                    if showCustomCategory {
                        VStack(spacing: 12) {
                            HStack(spacing: 12) {
                                EmojiTextField(text: $customEmoji, placeholder: "Tap")
                                    .frame(width: 56, height: 44)
                                    .background(Color(.systemGray6))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                TextField("Category name", text: $customName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Button {
                                let trimmedName = customName.trimmingCharacters(in: .whitespaces)
                                let trimmedEmoji = customEmoji.trimmingCharacters(in: .whitespaces)
                                guard !trimmedName.isEmpty, !trimmedEmoji.isEmpty else { return }
                                place.category = trimmedName
                                place.customEmoji = trimmedEmoji
                                try? modelContext.save()
                                dismiss()
                            } label: {
                                Text("Save Custom Category")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(customName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                      customEmoji.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } else {
                        Button {
                            customName = place.category ?? ""
                            customEmoji = place.customEmoji ?? ""
                            showCustomCategory = true
                        } label: {
                            Label("Create Custom Category", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle("Change Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Emoji Keyboard Text Field

/// A UITextField wrapper that opens the emoji keyboard directly.
struct EmojiTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeUIView(context: Context) -> UIEmojiTextField {
        let field = UIEmojiTextField()
        field.placeholder = placeholder
        field.font = .systemFont(ofSize: 32)
        field.textAlignment = .center
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        return field
    }

    func updateUIView(_ uiView: UIEmojiTextField, context: Context) {
        uiView.text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        @objc func textChanged(_ sender: UITextField) {
            // Keep only the last entered character (emoji)
            if let value = sender.text, !value.isEmpty {
                let last = String(value.suffix(1))
                text = last
                sender.text = last
            } else {
                text = ""
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            textField.text = text
        }
    }
}

/// UITextField subclass that forces the emoji keyboard.
class UIEmojiTextField: UITextField {
    override var textInputMode: UITextInputMode? {
        for mode in UITextInputMode.activeInputModes {
            if mode.primaryLanguage == "emoji" {
                return mode
            }
        }
        return super.textInputMode
    }
}
