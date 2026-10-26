import SwiftUI

/// A flow layout that wraps children to the next line when they exceed available width.
struct WrappingHStack: Layout {

    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { total, row in
            total + row.height + (total > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.subview.sizeThatFits(.unspecified)
                // Vertically center each item within the row
                let itemY = y + (row.height - size.height) / 2
                item.subview.place(at: CGPoint(x: x, y: itemY), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    // MARK: - Row computation

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [RowItem] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [Row] = [Row()]

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let currentRow = rows[rows.count - 1]
            let newWidth = currentRow.width + (currentRow.items.isEmpty ? 0 : spacing) + size.width

            if newWidth > maxWidth && !currentRow.items.isEmpty {
                rows.append(Row(items: [RowItem(subview: subview, size: size)], width: size.width, height: size.height))
            } else {
                rows[rows.count - 1].items.append(RowItem(subview: subview, size: size))
                rows[rows.count - 1].width = newWidth
                rows[rows.count - 1].height = max(currentRow.height, size.height)
            }
        }

        return rows
    }
}
