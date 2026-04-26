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
        .background(Color.clear)
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
            HStack(spacing: 0) {
                BreadcrumbView(model: model, currentLevel: level)
                SortMenuButton(level: level, model: model)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func emptyMessage(for state: CascadeModel.Level) -> String {
        if state.readError { return "Can't read folder" }
        if state.isLoading { return "Loading…" }
        return level == 0 ? "No folders yet" : "Empty folder"
    }

    @ViewBuilder private var listBody: some View {
        if let state {
            if state.items.isEmpty {
                Spacer()
                Text(emptyMessage(for: state))
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                if level == 0 && !state.readError && !state.isLoading {
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
        VStack(spacing: 0) {
            // Top bar with settings button (replaces LevelListView's header for level 0)
            HStack {
                if let url = Bundle.main.url(forResource: "AppIconArtwork", withExtension: "png"),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
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

            // The level 0 list — resize grip is embedded in the footer row.
            LevelListBody(
                level: 0,
                model: model,
                onResizeBegan: onResizeBegan,
                onResizeDrag: onResizeDrag,
                onResizeEnded: onResizeEnded
            )
        }
    }
}

// MARK: - Sort menu button

private struct SortMenuButton: View {
    let level: Int
    @ObservedObject var model: CascadeModel

    var body: some View {
        let (currentOrder, descending) = model.sortState(forLevel: level)
        Menu {
            ForEach(FileSortOrder.allCases, id: \.rawValue) { order in
                Button {
                    let newDescending = (currentOrder == order)
                        ? !descending
                        : (order == .dateModified || order == .dateCreated)
                    model.setSort(order: order, descending: newDescending, forLevel: level)
                } label: {
                    HStack {
                        Text(order.label)
                        if currentOrder == order {
                            Image(systemName: descending ? "chevron.down" : "chevron.up")
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Onboarding empty state (level 0, no folders configured yet)

private struct OnboardingEmptyView: View {
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Pulsing arrow nudges toward the ··· button in the top-right corner.
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .offset(x: 0, y: pulse ? -3 : 0)
                .animation(
                    .easeInOut(duration: 0.65).repeatForever(autoreverses: true),
                    value: pulse
                )
                .padding(.top, 6)
                .padding(.trailing, 14)

            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 30))
                    .foregroundStyle(.tertiary)
                Text("Nothing here yet")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Click ··· to add a folder or file")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear  { pulse = true  }
        .onDisappear { pulse = false }
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
    @FocusState private var searchFocused: Bool

    // Resize callbacks — only provided for level 0 from CascadeRootView.
    var onResizeBegan: (() -> Void)?
    var onResizeDrag: ((CGSize) -> Void)?
    var onResizeEnded: (() -> Void)?

    @AppStorage(UDKey.rowDensity) private var densityRaw: String = RowDensity.medium.rawValue
    private var density: RowDensity { RowDensity(rawValue: densityRaw) ?? .medium }

    private var state: CascadeModel.Level? {
        model.levels.indices.contains(level) ? model.levels[level] : nil
    }

    private var activeFilter: String { model.filterText[level] ?? "" }
    private var isFiltering: Bool { !activeFilter.isEmpty }

    /// Original item indices to display. The model owns this so visible rows
    /// and keyboard navigation use identical filtering rules.
    private var displayIndices: [Int] {
        model.visibleIndices(forLevel: level)
    }

    private var activeDisplayIndex: Int? {
        guard model.focus.level == level else { return nil }
        if displayIndices.contains(model.focus.index) {
            return model.focus.index
        }
        if isFiltering,
           let highlighted = model.filterHighlightIndex[level],
           displayIndices.contains(highlighted) {
            return highlighted
        }
        return isFiltering ? displayIndices.first : nil
    }

    private var showFooter: Bool {
        UserDefaults.standard.object(forKey: UDKey.showFooterBar) as? Bool ?? true
    }
    private var selectionCount: Int { selectionState.selectedURLs.count }

    // Whether the footer (and embedded grip) will be shown.
    private func willShowFooter(state: CascadeModel.Level) -> Bool {
        selectionCount > 0 || (showFooter && !state.items.isEmpty)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                if model.searchVisible[level] == true {
                    searchBarView
                    Divider()
                }
                if let state {
                    if displayIndices.isEmpty {
                        emptyView
                    } else {
                        scrollView(state: state)
                    }
                    if willShowFooter(state: state) {
                        footerView(state: state)
                    }
                }
            }

            // Fallback grip: shown only when the footer is hidden (empty list or
            // footer pref off) so the popover can still be resized.
            if let state = state, !willShowFooter(state: state),
               let onBegan = onResizeBegan, let onDrag = onResizeDrag, let onEnded = onResizeEnded {
                ResizeGripSwiftUI(onBegan: onBegan, onChanged: onDrag, onEnded: onEnded)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
            }
        }
        .background(Color.clear)
        .background(WindowMouseTracker(level: level, model: model))
        .onReceive(selectionState.$selectedURLs) { urls in
            model.setSelectedURLs(urls, forLevel: level)
        }
        .onChange(of: model.clearSelectionVersion) { _ in
            selectionState.clear()
        }
        .onDisappear {
            model.setSelectedURLs([], forLevel: level)
        }
        .onChange(of: model.focusSearchLevel) { val in
            guard val == level else { return }
            model.focusSearchLevel = nil
            // Only level 0 (popover) can become key — peek levels use virtual typing.
            if level == 0 {
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }

    // MARK: - Search bar

    @ViewBuilder private var searchBarView: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)

            if level == 0 {
                // The popover window can become key — use a real text field.
                TextField("Filter…", text: Binding(
                    get: { model.filterText[level] ?? "" },
                    set: { model.setFilter($0, forLevel: level, deferFocus: true) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
            } else {
                // Peek windows can never become key, so a real text field can't
                // receive focus. Instead the key monitor intercepts printable
                // keystrokes and writes them to model.filterText directly.
                // This view is a read-only display of the accumulated input.
                Group {
                    if activeFilter.isEmpty {
                        Text("Type to filter…").foregroundStyle(.tertiary)
                    } else {
                        Text(activeFilter).foregroundStyle(.primary)
                    }
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isFiltering {
                Button { model.hideSearch(forLevel: level) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Empty state

    @ViewBuilder private var emptyView: some View {
        if isFiltering {
            VStack {
                Spacer()
                Text("No results for \"\(activeFilter)\"")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if level == 0 {
            OnboardingEmptyView()
        } else {
            VStack {
                Spacer()
                Text(state?.readError == true ? "Can't read folder"
                     : state?.isLoading == true ? "Loading…"
                     : "Empty folder")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Footer bar

    @ViewBuilder private func footerView(state: CascadeModel.Level) -> some View {
        if selectionCount > 0 {
            selectionFooterView
        } else {
            defaultFooterView(state: state)
        }
    }

    @ViewBuilder private var selectionFooterView: some View {
        Divider()
        HStack(spacing: 8) {
            Text("\(selectionCount) selected")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Clear Selection") {
                selectionState.clear()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if let onBegan = onResizeBegan, let onDrag = onResizeDrag, let onEnded = onResizeEnded {
                ResizeGripSwiftUI(onBegan: onBegan, onChanged: onDrag, onEnded: onEnded)
                    .padding(.trailing, 8)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 4)
        .background(Color.clear)
    }

    @ViewBuilder private func defaultFooterView(state: CascadeModel.Level) -> some View {
        let totalCount = state.items.count
        let shownCount = displayIndices.count
        let label: String = {
            let countText: String
            if isFiltering {
                countText = "\(shownCount) of \(totalCount) \(totalCount == 1 ? "item" : "items")"
            } else {
                countText = "\(totalCount) \(totalCount == 1 ? "item" : "items")"
            }
            // Level 0 shows root folders only — skip size (not a real folder listing).
            if level == 0 { return countText }
            guard state.totalSize > 0 else { return countText }
            return "\(countText) · \(formatSize(state.totalSize))"
        }()

        Divider()
        HStack(spacing: 0) {
            Spacer()
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            if let onBegan = onResizeBegan, let onDrag = onResizeDrag, let onEnded = onResizeEnded {
                ResizeGripSwiftUI(onBegan: onBegan, onChanged: onDrag, onEnded: onEnded)
                    .padding(.trailing, 8)
            }
        }
        .padding(.vertical, 4)
        .background(Color.clear)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    private func formatSize(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    // MARK: - Scroll list

    @ViewBuilder private func scrollView(state: CascadeModel.Level) -> some View {
        ScrollViewReader { sp in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isFiltering {
                        // Flat filtered list, preserving original indices so
                        // model calls (click, focus, spring-load) remain correct.
                        ForEach(displayIndices, id: \.self) { idx in
                            rowView(state: state, item: state.items[idx], idx: idx)
                        }
                    } else if state.sections.isEmpty {
                        rowsView(state: state, range: state.items.indices)
                    } else {
                        ForEach(state.sections, id: \.self) { sec in
                            sectionHeader(sec.title)
                            rowsView(state: state, range: sec.range)
                        }
                    }
                }
            }
            .onChange(of: model.keyboardFocusVersion) { _ in
                let f = model.focus
                guard f.level == level,
                      state.items.indices.contains(f.index),
                      model.isIndexVisible(f.index, forLevel: level) else { return }
                withAnimation(.none) {
                    sp.scrollTo(state.items[f.index].id, anchor: .center)
                }
            }
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        if title == "Frequent" {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Frequent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        } else if title == "Shortcuts" {
            VStack(spacing: 0) {
                Divider()
                    .padding(.leading, 12)
                    .padding(.trailing, 12)

                HStack {
                    Text("Your Shortcuts")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 2)
            }
            .padding(.top, 10)
        } else {
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
    }

    @ViewBuilder
    private func rowView(state: CascadeModel.Level, item: FileItem, idx: Int) -> some View {
        let isActive = activeDisplayIndex == idx
        let isPath = model.pathIndices[level] == idx && level + 1 < model.levels.count
        DraggableFileRow(
            item: item,
            onTap: { model.clickRow(level: level, index: idx) },
            selectionState: selectionState,
            isFocused: isActive,
            isOnPath: isPath,
            onHover: { model.mouseHover(level: level, index: idx) },
            parentFolder: state.source,
            onSpringLoad: item.isDirectory
                ? { model.springLoadFolder(level: level, index: idx) }
                : nil,
            removeFromRootHandler: level == 0 && item.role == .rootShortcut
                ? { model.onRemoveRoot?(item.url) }
                : nil,
            replaceRootHandler: level == 0 && item.role == .rootShortcut
                ? { oldURL, newURL in model.replaceRootShortcut(oldURL: oldURL, newURL: newURL) }
                : nil,
            updateRootDisplayNameHandler: level == 0 && item.role == .rootShortcut
                ? { url, displayName in model.setRootDisplayName(displayName, for: url) }
                : nil,
            addToRootHandler: item.role != .rootShortcut && !model.isInRoot(item.url)
                ? { model.addToRoot($0) }
                : nil,
            hideFromFrequentHandler: item.role == .frequent
                ? { FrequentStore.shared.hide(item.url) }
                : nil
        )
        .id("\(item.id.uuidString)-\(isActive ? "active" : "idle")-\(isPath ? "path" : "offpath")")
        .frame(height: density.rowHeight)
        .id(item.id)
        .background(RowFrameReporter(level: level, index: idx, model: model))
    }

    @ViewBuilder
    private func rowsView(state: CascadeModel.Level, range: Range<Int>) -> some View {
        ForEach(range, id: \.self) { idx in
            rowView(state: state, item: state.items[idx], idx: idx)
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
                let r: CGFloat = 1.4
                let step: CGFloat = 4.5
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
        .frame(width: 18, height: 18)
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
