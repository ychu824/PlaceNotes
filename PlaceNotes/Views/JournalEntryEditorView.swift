import SwiftUI
import PhotosUI
import Photos

struct JournalEntryEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let place: Place
    var existingEntry: JournalEntry?

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var photoIdentifiers: [String] = []
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isLoadingPhotos = false

    private var isEditing: Bool { existingEntry != nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Photos section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Photos", systemImage: "photo.on.rectangle.angled")
                                .font(.headline)
                            Spacer()
                            PhotosPicker(
                                selection: $selectedItems,
                                maxSelectionCount: 20,
                                matching: .images
                            ) {
                                Label("Add Photos", systemImage: "plus.circle")
                                    .font(.subheadline)
                            }
                        }

                        if isLoadingPhotos {
                            ProgressView("Adding photos...")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding()
                        }

                        PhotoGridView(assetIdentifiers: photoIdentifiers) { identifier in
                            photoIdentifiers.removeAll { $0 == identifier }
                        }
                    }

                    Divider()

                    // Title
                    TextField("Title", text: $title)
                        .font(.title2.bold())

                    // Body text
                    ZStack(alignment: .topLeading) {
                        if bodyText.isEmpty {
                            Text("Write about your experience...")
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                        }
                        TextEditor(text: $bodyText)
                            .frame(minHeight: 200)
                            .scrollContentBackground(.hidden)
                    }
                }
                .padding()
            }
            .navigationTitle(isEditing ? "Edit Entry" : "New Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveEntry()
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && bodyText.trimmingCharacters(in: .whitespaces).isEmpty && photoIdentifiers.isEmpty)
                }
            }
            .onChange(of: selectedItems) { _, newItems in
                Task {
                    await loadSelectedPhotos(newItems)
                }
            }
            .onAppear {
                if let entry = existingEntry {
                    title = entry.title
                    bodyText = entry.body
                    photoIdentifiers = entry.photoAssetIdentifiers
                }
            }
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }

        for item in items {
            if let identifier = item.itemIdentifier,
               !photoIdentifiers.contains(identifier) {
                photoIdentifiers.append(identifier)
            }
        }
        selectedItems = []
    }

    private func saveEntry() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedBody = bodyText.trimmingCharacters(in: .whitespaces)

        if let entry = existingEntry {
            entry.title = trimmedTitle
            entry.body = trimmedBody
            entry.photoAssetIdentifiers = photoIdentifiers
        } else {
            let entry = JournalEntry(
                title: trimmedTitle,
                body: trimmedBody,
                photoAssetIdentifiers: photoIdentifiers
            )
            entry.place = place
            modelContext.insert(entry)
        }
        try? modelContext.save()
    }
}
