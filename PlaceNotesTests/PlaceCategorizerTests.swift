import XCTest
@testable import PlaceNotes

final class PlaceCategorizerTests: XCTestCase {

    // MARK: - Icon Mapping

    func testIconForKnownCategories() {
        XCTAssertEqual(PlaceCategorizer.icon(for: "Restaurant"), "fork.knife")
        XCTAssertEqual(PlaceCategorizer.icon(for: "Cafe"), "cup.and.saucer.fill")
        XCTAssertEqual(PlaceCategorizer.icon(for: "Gym"), "figure.run")
        XCTAssertEqual(PlaceCategorizer.icon(for: "Park"), "leaf.fill")
        XCTAssertEqual(PlaceCategorizer.icon(for: "Hospital"), "cross.case.fill")
        XCTAssertEqual(PlaceCategorizer.icon(for: "Store"), "bag.fill")
        XCTAssertEqual(PlaceCategorizer.icon(for: "Airport"), "airplane")
    }

    func testIconForNilCategory() {
        XCTAssertEqual(PlaceCategorizer.icon(for: nil), "mappin.circle.fill")
    }

    func testIconForUnknownCategory() {
        XCTAssertEqual(PlaceCategorizer.icon(for: "SomeRandomCategory"), "mappin.circle.fill")
    }

    // MARK: - Emoji Mapping

    func testEmojiForKnownCategories() {
        XCTAssertEqual(PlaceCategorizer.emoji(for: "Restaurant"), "\u{1F374}")
        XCTAssertEqual(PlaceCategorizer.emoji(for: "Cafe"), "\u{2615}")
        XCTAssertEqual(PlaceCategorizer.emoji(for: "Gym"), "\u{1F4AA}")
        XCTAssertEqual(PlaceCategorizer.emoji(for: "Park"), "\u{1F333}")
        XCTAssertEqual(PlaceCategorizer.emoji(for: "Hospital"), "\u{1F3E5}")
        XCTAssertEqual(PlaceCategorizer.emoji(for: "Bank"), "\u{1F3E6}")
    }

    func testEmojiForNilCategory() {
        XCTAssertEqual(PlaceCategorizer.emoji(for: nil), "\u{1F4CD}") // pushpin
    }

    func testEmojiForUnknownCategory() {
        XCTAssertEqual(PlaceCategorizer.emoji(for: "UnknownPlace"), "\u{1F4CD}")
    }

    // MARK: - Category Map Consistency

    func testAllCategoryMapEntriesHaveNonEmptyLabels() {
        for entry in PlaceCategorizer.categoryMap {
            XCTAssertFalse(entry.label.isEmpty, "Category label should not be empty")
            XCTAssertFalse(entry.icon.isEmpty, "Category icon should not be empty")
        }
    }

    func testCategoryMapHasNoDuplicateLabels() {
        let labels = PlaceCategorizer.categoryMap.map(\.label)
        let uniqueLabels = Set(labels)
        // Allow Museum/University to share "classical building" icon, but labels should be unique
        XCTAssertEqual(labels.count, uniqueLabels.count, "Category labels should be unique")
    }
}
