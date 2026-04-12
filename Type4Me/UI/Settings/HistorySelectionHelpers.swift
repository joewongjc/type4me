import Foundation

/// Pure helpers for history batch selection (unit-tested).
enum HistorySelectionHelpers {

    /// True when `filteredIds` is non-empty and every id is in `selectedIds`.
    static func isAllFilteredSelected(filteredIds: Set<String>, selectedIds: Set<String>) -> Bool {
        guard !filteredIds.isEmpty else { return false }
        return filteredIds.isSubset(of: selectedIds)
    }

    /// Toggles “select all in current list” vs “deselect all in current list”.
    /// - If every `filteredIds` is selected, removes those ids from the selection (others unchanged).
    /// - Otherwise unions `filteredIds` into the selection.
    /// - If `filteredIds` is empty, returns `selectedIds` unchanged.
    static func togglingSelectAllInFiltered(
        filteredIds: Set<String>,
        selectedIds: Set<String>
    ) -> Set<String> {
        guard !filteredIds.isEmpty else { return selectedIds }
        if filteredIds.isSubset(of: selectedIds) {
            return selectedIds.subtracting(filteredIds)
        }
        return selectedIds.union(filteredIds)
    }
}
