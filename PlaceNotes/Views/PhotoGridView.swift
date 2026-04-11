import SwiftUI

struct PhotoGridView: View {
    let photoFilenames: [String]
    var onRemove: ((String) -> Void)?

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        if photoFilenames.isEmpty {
            EmptyView()
        } else {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(photoFilenames, id: \.self) { filename in
                    PhotoThumbnailView(filename: filename)
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            if let onRemove {
                                Button {
                                    onRemove(filename)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black.opacity(0.5))
                                }
                                .padding(6)
                            }
                        }
                }
            }
        }
    }
}

struct PhotoThumbnailView: View {
    let filename: String
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .overlay {
                            Image(systemName: "photo")
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .clipped()
            .onAppear {
                image = PhotoStorage.loadImage(filename: filename)
            }
    }
}

// MARK: - Photo Storage

enum PhotoStorage {
    private static var photosDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JournalPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func saveImage(_ image: UIImage) -> String? {
        let filename = UUID().uuidString + ".jpg"
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let url = photosDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url)
            return filename
        } catch {
            return nil
        }
    }

    static func loadImage(filename: String) -> UIImage? {
        let url = photosDirectory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func deleteImage(filename: String) {
        let url = photosDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: url)
    }
}
