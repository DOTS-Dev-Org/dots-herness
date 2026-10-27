// Copyright (c) 2026 DOTS
// The planner never scrolls vertically. Only its cards scroll, horizontally,
// when a full two-column grid cannot fit inside the available window.
import Foundation

struct TaskSuggestionLayout {
    let contentWidth: CGFloat
    let padding: CGFloat
    let spacing: CGFloat
    let mascotHeight: CGFloat
    let headerHeight: CGFloat
    let horizontal: Bool
    let cardHeight: CGFloat
    let cardWidth: CGFloat
    let cardsHeight: CGFloat

    init(size: CGSize) {
        padding = size.height < 500 ? 12 : 20
        spacing = size.height < 500 ? 12 : 18
        contentWidth = max(0, min(874, size.width - 40))
        mascotHeight = size.height >= 600 ? 140 : size.height >= 450 ? 90 : size.height >= 320 ? 50 : 0
        headerHeight = mascotHeight + (mascotHeight > 0 ? 8 : 0) + 64
        let available = size.height - padding * 2 - headerHeight - 24 - spacing * 2
        let gridHeight: CGFloat = 96 * 4 + 14 * 3
        horizontal = contentWidth < 574 || available < gridHeight
        cardHeight = horizontal ? min(112, max(96, available)) : 96
        cardWidth = horizontal ? max(280, min(380, contentWidth * 0.7)) : (contentWidth - 14) / 2
        cardsHeight = horizontal ? cardHeight : gridHeight
    }

    var occupiedHeight: CGFloat { padding * 2 + headerHeight + 24 + spacing * 2 + cardsHeight }
}
