import Foundation
import SwiftData

@Model
final class JournalEntry {
    var id: UUID
    var title: String
    var body: String
    var date: Date
    var photoAssetIdentifiers: [String]
    var place: Place?

    init(title: String = "", body: String = "", date: Date = Date(), photoAssetIdentifiers: [String] = []) {
        self.id = UUID()
        self.title = title
        self.body = body
        self.date = date
        self.photoAssetIdentifiers = photoAssetIdentifiers
    }
}
