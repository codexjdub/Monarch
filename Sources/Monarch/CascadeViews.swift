import SwiftUI
import AppKit

// MARK: - Level List View
//
// Renders one level's contents: a small header + a scrollable list of rows.
// Used both inside the main popover (level 0) and inside each peek window.

struct LevelListView: View {
    let level: Int
    @ObservedObject var model: CascadeModel

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
        if level == 0 {
            HStack {
                Text("Monarch").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        } else {
            BreadcrumbView(model: model, currentLevel: level)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
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
                // Reuse LevelListBody's section-aware rendering for peek lists.
                LevelListBody(level: level, model: model)
            }
        }
    }
}

extension Notification.Name {
    static let monarchRemoveRoot = Notification.Name("MonarchRemoveRoot")
}

// MARK: - Breadcrumb
//
// Renders "Root › Sub › Sub › Current" across the top of a peek window.
// Non-current segments are clickable; clicking one collapses the cascade
// back to that level. Overflow scrolls horizontally.

struct BreadcrumbView: View {
    @ObservedObject var model: CascadeModel
    let currentLevel: Int

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(segments, id: \.level) { seg in
                    if seg.level != segments.first?.level {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    segmentLabel(seg)
                }
            }
            .padding(.trailing, 4)
        }
    }

    private struct Segment: Hashable {
        let level: Int
        let name: String
    }

    private var segments: [Segment] {
        // Levels 1...currentLevel. Each segment shows that level's source
        // folder name. Skips level 0 (the configured-roots list).
        var out: [Segment] = []
        for l in 1...currentLevel {
            guard model.levels.indices.contains(l),
                  let src = model.levels[l].source else { continue }
            out.append(Segment(level: l, name: src.lastPathComponent))
        }
        return out
    }

    @ViewBuilder
    private func segmentLabel(_ seg: Segment) -> some View {
        if seg.level == currentLevel {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
                Text(seg.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
        } else {
            Button {
                model.jumpToBreadcrumb(level: seg.level)
            } label: {
                Text(seg.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
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
                    Text("Monarch").font(.headline)
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
                                if state.sections.isEmpty {
                                    // Flat list — no section headers.
                                    rowsView(state: state, range: state.items.indices)
                                } else {
                                    ForEach(state.sections, id: \.self) { sec in
                                        sectionHeader(sec.title)
                                        rowsView(state: state, range: sec.range)
                                    }
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

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func rowsView(state: CascadeModel.Level, range: Range<Int>) -> some View {
        ForEach(range, id: \.self) { idx in
            let item = state.items[idx]
            DraggableFileRow(
                item: item,
                onTap: { model.clickRow(level: level, index: idx) },
                selectionState: selectionState,
                isFocused: model.focus.level == level && model.focus.index == idx,
                isOnPath: model.pathIndices[level] == idx
                    && level + 1 < model.levels.count,
                parentFolder: state.source,
                onSpringLoad: item.isDirectory
                    ? { model.springLoadFolder(level: level, index: idx) }
                    : nil,
                removeFromRootHandler: level == 0
                    ? { NotificationCenter.default.post(name: .monarchRemoveRoot, object: item.url) }
                    : nil
            )
            .frame(height: 34)
            .id(item.id)
            .background(RowFrameReporter(level: level, index: idx, model: model))
        }
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
