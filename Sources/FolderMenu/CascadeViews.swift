import SwiftUI
import AppKit

// MARK: - Level List View
//
// Renders one level's contents: a small header + a scrollable list of rows.
// Used both inside the main popover (level 0) and inside each peek window.

struct LevelListView: View {
    let level: Int
    @ObservedObject var model: CascadeModel
    @StateObject private var selectionState = SelectionState()

    private var state: CascadeModel.Level? {
        model.levels.indices.contains(level) ? model.levels[level] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            listBody
        }
        .background(Color(NSColor.windowBackgroundColor))
        .background(WindowMouseTracker(level: level, model: model))
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 6) {
            if level == 0 {
                Text("FolderMenu").font(.headline)
            } else {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Text(state?.source?.lastPathComponent ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var listBody: some View {
        if let state {
            if state.items.isEmpty {
                Spacer()
                Text(level == 0 ? "No folders yet" : "Empty folder")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                if level == 0 {
                    Text("Click ··· to add a folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollViewReader { sp in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(state.items.enumerated()), id: \.element.id) { idx, item in
                                DraggableFileRow(
                                    item: item,
                                    onTap: { model.clickRow(level: level, index: idx) },
                                    selectionState: selectionState,
                                    isFocused: model.focus.level == level && model.focus.index == idx,
                                    isOnPath: model.pathIndices[level] == idx
                                        && level + 1 < model.levels.count,
                                    removeFromRootHandler: level == 0 ? { removeRoot(item.url) } : nil
                                )
                                .frame(height: 34)
                                .id(item.id)
                                .background(RowFrameReporter(level: level, index: idx, model: model))
                            }
                        }
                    }
                    .onChange(of: model.focus) { f in
                        guard f.level == level,
                              state.items.indices.contains(f.index) else { return }
                        withAnimation(.none) {
                            sp.scrollTo(state.items[f.index].id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func removeRoot(_ url: URL) {
        // Reach back to the store via a notification — decoupled from the model.
        NotificationCenter.default.post(name: .folderMenuRemoveRoot, object: url)
    }
}

extension Notification.Name {
    static let folderMenuRemoveRoot = Notification.Name("FolderMenuRemoveRoot")
}

// MARK: - Cascade Root View
//
// Hosted inside the main NSPopover. Wraps LevelListView(level: 0) with
// an app-level header (settings button) and the resize grip.

struct CascadeRootView: View {
    @ObservedObject var model: CascadeModel
    let onSettingsTapped: () -> Void
    let onResizeBegan: () -> Void
    let onResizeDrag: (CGSize) -> Void
    let onResizeEnded: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                // Top bar with settings button (replaces LevelListView's header for level 0)
                HStack {
                    Text("FolderMenu").font(.headline)
                    Spacer()
                    Button(action: onSettingsTapped) {
                        Image(systemName: "ellipsis.circle").font(.system(size: 15))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                // The level 0 list, without its own header (we provided one above)
                LevelListBody(level: 0, model: model)
            }

            ResizeGripSwiftUI(
                onBegan: onResizeBegan,
                onChanged: onResizeDrag,
                onEnded: onResizeEnded
            )
            .padding(.trailing, 6)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Level List Body
//
// The list portion of a level (no header). Used by CascadeRootView (which
// composes its own header with the settings button).

struct LevelListBody: View {
    let level: Int
    @ObservedObject var model: CascadeModel
    @StateObject private var selectionState = SelectionState()

    private var state: CascadeModel.Level? {
        model.levels.indices.contains(level) ? model.levels[level] : nil
    }

    var body: some View {
        Group {
            if let state {
                if state.items.isEmpty {
                    VStack {
                        Spacer()
                        Text(level == 0 ? "No folders yet" : "Empty folder")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                        if level == 0 {
                            Text("Click ··· to add a folder")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { sp in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(state.items.enumerated()), id: \.element.id) { idx, item in
                                    DraggableFileRow(
                                        item: item,
                                        onTap: { model.clickRow(level: level, index: idx) },
                                        selectionState: selectionState,
                                        isFocused: model.focus.level == level && model.focus.index == idx,
                                        isOnPath: model.pathIndices[level] == idx
                                            && level + 1 < model.levels.count,
                                        removeFromRootHandler: level == 0
                                            ? { NotificationCenter.default.post(name: .folderMenuRemoveRoot, object: item.url) }
                                            : nil
                                    )
                                    .frame(height: 34)
                                    .id(item.id)
                                    .background(RowFrameReporter(level: level, index: idx, model: model))
                                }
                            }
                        }
                        .onChange(of: model.focus) { f in
                            guard f.level == level,
                                  state.items.indices.contains(f.index) else { return }
                            withAnimation(.none) {
                                sp.scrollTo(state.items[f.index].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .background(WindowMouseTracker(level: level, model: model))
    }
}

// MARK: - Resize grip

struct ResizeGripSwiftUI: View {
    let onBegan: () -> Void
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    @State private var dragging = false

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            Path { p in
                let r: CGFloat = 1.8
                let step: CGFloat = 6
                let pts: [CGPoint] = [
                    CGPoint(x: step * 3, y: step * 1),
                    CGPoint(x: step * 3, y: step * 2),
                    CGPoint(x: step * 3, y: step * 3),
                    CGPoint(x: step * 2, y: step * 2),
                    CGPoint(x: step * 2, y: step * 3),
                    CGPoint(x: step * 1, y: step * 3),
                ]
                for pt in pts {
                    p.addEllipse(in: CGRect(x: pt.x - r, y: pt.y - r, width: r*2, height: r*2))
                }
            }
            .fill(Color.secondary.opacity(0.7))
        }
        .frame(width: 24, height: 24)
        .onHover { inside in
            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging { dragging = true; onBegan() }
                    onChanged(CGSize(width: value.translation.width,
                                     height: value.translation.height))
                }
                .onEnded { _ in
                    dragging = false
                    onEnded()
                }
        )
    }
}
