import Foundation
import SwiftData

/// SwiftData cascade rules don't run our code, so photo files on disk leak when
/// a JournalEntry (or its parent Visit/Place) is deleted. Use these helpers
/// anywhere a JournalEntry is removed or anywhere a cascade will sweep entries.
enum JournalEntryDeletion {

    @MainActor
    static func delete(_ entry: JournalEntry, in context: ModelContext) {
        for filename in entry.photoAssetIdentifiers {
            PhotoStorage.deleteImage(filename: filename)
        }
        context.delete(entry)
    }

    @MainActor
    static func cleanupPhotos(for visit: Visit) {
        for entry in visit.journalEntries {
            for filename in entry.photoAssetIdentifiers {
                PhotoStorage.deleteImage(filename: filename)
            }
        }
    }

    @MainActor
    static func cleanupPhotos(for place: Place) {
        for entry in place.journalEntries {
            for filename in entry.photoAssetIdentifiers {
                PhotoStorage.deleteImage(filename: filename)
            }
        }
    }
}
