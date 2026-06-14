/*
 Spatial Stash - Grid Column Layout

 Shared column-sizing for the gallery grids (Pictures, Videos, Local).

 `.adaptive` fills the window width but can't express a column-count *floor*
 (it just drops to fewer, larger columns when the window narrows). These grids
 want a minimum column count — once the window is too narrow to fit them at the
 preferred size, the cells should shrink to keep the count and increase density.

 So we pick the count manually (the same count `.adaptive(minimum:)` would) and
 build `.flexible()` columns, which — like `.adaptive` — expand to fill the
 width. That keeps the grid hugging the window edges (resize grabbers don't
 float), lets inter-cell spacing grow smoothly within a band instead of
 snapping, and keeps the columns array stable while only the cell size changes,
 so the scroll position isn't reset. Callers animate `columns.count` to make the
 add/remove-a-column transition slide instead of snap.
 */

import SwiftUI

enum GridColumnLayout {
    /// Resolve the column layout for a container width.
    /// - Parameters:
    ///   - width: The container width (e.g. from a `GeometryReader`). `<= 0`
    ///     falls back to `minColumns` at `preferredCellSize`.
    ///   - preferredCellSize: Target cell edge — the count is chosen so cells
    ///     stay around this size (matches `.adaptive(minimum:)`).
    ///   - minColumns: Never lay out fewer than this many columns.
    ///   - spacing: Inter-column spacing (must match the `LazyVGrid` spacing).
    ///   - contentInset: Horizontal padding applied to the scroll content, so
    ///     the available width is computed correctly.
    /// - Returns: The columns and the resolved column width (== cell edge for
    ///   grids whose cells fill the column; grids that cap the cell use
    ///   `min(preferredCellSize, columnWidth)`).
    static func resolve(width: CGFloat,
                        preferredCellSize: CGFloat,
                        minColumns: Int,
                        spacing: CGFloat = 16,
                        contentInset: CGFloat = 16) -> (columns: [GridItem], columnWidth: CGFloat) {
        let count: Int
        let columnWidth: CGFloat
        if width > 0 {
            let available = max(preferredCellSize, width - contentInset * 2)
            // Same count `.adaptive(minimum: preferredCellSize)` would pick.
            let natural = Int((available + spacing) / (preferredCellSize + spacing))
            count = max(minColumns, natural)
            columnWidth = (available - spacing * CGFloat(count - 1)) / CGFloat(count)
        } else {
            count = minColumns
            columnWidth = preferredCellSize
        }
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
        return (columns, columnWidth)
    }
}
