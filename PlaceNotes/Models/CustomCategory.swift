import Foundation
import SwiftData

@Model
final class CustomCategory {
    var id: UUID
    var name: String
    var emoji: String

    init(name: String, emoji: String) {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
    }
}
