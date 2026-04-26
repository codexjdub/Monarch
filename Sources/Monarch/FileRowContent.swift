import SwiftUI
import AppKit

// MARK: - Row content
//
// Pure visual for one row. No AppKit, no drag/drop — just icon, name,
// subtitle, selection/focus/path highlight, and missing-shortcut styling.
// The NSView wrapper in DraggableFileRow hosts this view for behavior.

struct FileRowContent: View {
    let item: FileItem
    @ObservedObject var selectionState: SelectionState
    let isFocused: Bool
    let isOnPath: Bool

    @AppStorage(UDKey.rowDensity) private var densityRaw: String = RowDensity.medium.rawValue
    private var density: RowDensity { RowDensity(rawValue: densityRaw) ?? .medium }

    var isSelected: Bool { selectionState.isSelected(item.url) }

    var highlightColor: Color {
        if isFocused  { return Color.accentColor.opacity(0.30) }
        if isOnPath   { return Color.accentColor.opacity(0.22) }
        if isSelected { return Color.accentColor.opacity(0.25) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 8) {
            RowIconView(item: item)
                .frame(width: density.iconSize, height: density.iconSize)
                .opacity(item.exists ? 1.0 : 0.45)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayName)
                    .font(.system(size: density.fontSize))
                    .strikethrough(!item.exists, color: .secondary)
                    .foregroundStyle(item.exists ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitleView
            }

            Spacer()

            if !item.exists {
                // Broken-shortcut badge. Tooltip (NSView-level) could be added
                // later; for now the visual is enough to signal "click me".
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: density.chevronSize + 1))
                    .foregroundStyle(.orange)
            } else if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: density.chevronSize))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(highlightColor)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var subtitleView: some View {
        if !item.exists {
            Text("Missing — click to locate")
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
        } else if let subtitle = item.subtitleOverride {
            Text(subtitle)
                .font(.system(size: density.subtitleFontSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            let parts: [String?] = item.isDirectory
                ? []
                : [item.fileSize, formatModifiedDate(item.contentModifiedAt), item.imageDimensions]
            let subtitle = parts.compactMap { $0 }.joined(separator: "  ·  ")
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: density.subtitleFontSize))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func formatModifiedDate(_ date: Date?) -> String? {
        guard let date else { return nil }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        return Self.modifiedDateFormatter.string(from: date)
    }

    private static let modifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = false
        return formatter
    }()
}
