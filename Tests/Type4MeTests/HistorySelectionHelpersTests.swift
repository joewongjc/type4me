import XCTest
@testable import Type4Me

final class HistorySelectionHelpersTests: XCTestCase {

    func testIsAllFilteredSelected_emptyFilteredFalse() {
        XCTAssertFalse(
            HistorySelectionHelpers.isAllFilteredSelected(
                filteredIds: [],
                selectedIds: ["a"]
            )
        )
    }

    func testIsAllFilteredSelected_allSelectedTrue() {
        XCTAssertTrue(
            HistorySelectionHelpers.isAllFilteredSelected(
                filteredIds: ["a", "b"],
                selectedIds: ["a", "b", "extra"]
            )
        )
    }

    func testIsAllFilteredSelected_partialFalse() {
        XCTAssertFalse(
            HistorySelectionHelpers.isAllFilteredSelected(
                filteredIds: ["a", "b", "c"],
                selectedIds: ["a", "b"]
            )
        )
    }

    func testTogglingSelectAllInFiltered_emptyFilteredUnchanged() {
        let selected: Set<String> = ["x"]
        let out = HistorySelectionHelpers.togglingSelectAllInFiltered(
            filteredIds: [],
            selectedIds: selected
        )
        XCTAssertEqual(out, selected)
    }

    func testTogglingSelectAllInFiltered_selectAllUnions() {
        let out = HistorySelectionHelpers.togglingSelectAllInFiltered(
            filteredIds: ["a", "b"],
            selectedIds: ["a"]
        )
        XCTAssertEqual(out, Set(["a", "b"]))
    }

    func testTogglingSelectAllInFiltered_deselectSubtractsOnlyFiltered() {
        let out = HistorySelectionHelpers.togglingSelectAllInFiltered(
            filteredIds: ["a", "b"],
            selectedIds: ["a", "b", "keep"]
        )
        XCTAssertEqual(out, Set(["keep"]))
    }

    func testTogglingSelectAllInFiltered_partialThenFullSelect() {
        var selected = HistorySelectionHelpers.togglingSelectAllInFiltered(
            filteredIds: ["a", "b", "c"],
            selectedIds: ["a"]
        )
        XCTAssertEqual(selected, Set(["a", "b", "c"]))

        selected = HistorySelectionHelpers.togglingSelectAllInFiltered(
            filteredIds: ["a", "b", "c"],
            selectedIds: selected
        )
        XCTAssertEqual(selected, Set<String>())
    }
}
