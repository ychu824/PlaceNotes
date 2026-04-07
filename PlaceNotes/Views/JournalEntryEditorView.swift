import SwiftUI
import PhotosUI

struct JournalEntryEditorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let place: Place
    var existingEntry: JournalEntry?

    @State private var title: String = ""
    @State private var bodyText: String = ""
    @State private var entryDate: Date = Date()
    @State private var photoFilenames: [String] = []
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

                        PhotoGridView(photoFilenames: photoFilenames) { filename in
                            photoFilenames.removeAll { $0 == filename }
                            PhotoStorage.deleteImage(filename: filename)
                        }
                    }

                    Divider()

                    // Date
                    DatePicker("Date", selection: $entryDate, displayedComponents: [.date])
                        .datePickerStyle(.compact)

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
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty && bodyText.trimmingCharacters(in: .whitespaces).isEmpty && photoFilenames.isEmpty)
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
                    entryDate = entry.date
                    photoFilenames = entry.photoAssetIdentifiers
                }
            }
        }
    }

    private func loadSelectedPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isLoadingPhotos = true

        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data),
               let filename = PhotoStorage.saveImage(uiImage) {
                photoFilenames.append(filename)
            }
        }

        isLoadingPhotos = false
        selectedItems = []
    }

    private func saveEntry() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedBody = bodyText.trimmingCharacters(in: .whitespaces)

        if let entry = existingEntry {
            // Delete removed photos from disk
            let removed = Set(entry.photoAssetIdentifiers).subtracting(photoFilenames)
            for filename in removed {
                PhotoStorage.deleteImage(filename: filename)
            }
            entry.title = trimmedTitle
            entry.body = trimmedBody
            entry.date = entryDate
            entry.photoAssetIdentifiers = photoFilenames
        } else {
            let entry = JournalEntry(
                title: trimmedTitle,
                body: trimmedBody,
                date: entryDate,
                photoAssetIdentifiers: photoFilenames
            )
            entry.place = place
            modelContext.insert(entry)
        }
        try? modelContext.save()
    }
}
