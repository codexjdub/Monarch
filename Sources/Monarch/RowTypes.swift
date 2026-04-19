import AppKit
import SwiftUI

// MARK: - Row density
//
// User-selectable row height / font size. Changed in Preferences; read by
// FileRowContent and by LevelListBody to set the row frame.

enum RowDensity: String, CaseIterable {
    case small, medium, large

    var label: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }
    var rowHeight: CGFloat {
        switch self {
        case .small:  return 26
        case .medium: return 34
        case .large:  return 44
        }
    }
    var fontSize: CGFloat {
        switch self {
        case .small:  return 11
        case .medium: return 13
        case .large:  return 15
        }
    }
    var subtitleFontSize: CGFloat {
        switch self {
        case .small:  return 9
        case .medium: return 10
        case .large:  return 12
        }
    }
    var iconSize: CGFloat {
        switch self {
        case .small:  return 14
        case .medium: return 20
        case .large:  return 24
        }
    }
    var chevronSize: CGFloat {
        switch self {
        case .small:  return 9
        case .medium: return 10
        case .large:  return 11
        }
    }
}

// MARK: - Selection state (Cmd-click multi-select for drag-out)
//
// Tracks Cmd-selected rows within a single level's list. Used to carry
// multiple URLs in a drag-out operation.

class SelectionState: ObservableObject {
    @Published var selectedURLs: Set<URL> = []

    func toggle(_ url: URL) {
        if selectedURLs.contains(url) { selectedURLs.remove(url) }
        else { selectedURLs.insert(url) }
    }
    func clear() { selectedURLs = [] }
    func isSelected(_ url: URL) -> Bool { selectedURLs.contains(url) }
}
