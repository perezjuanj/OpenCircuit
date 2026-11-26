// The "Edit Today" sheet (#394, decision 94; SCOPE.md §7): show, hide and reorder Today's cards and
// Your Numbers tiles. A List held in edit mode, so every movable row has the system reorder handle.
// The sheet edits a draft (`TodayLayoutEdit`); Done hands the draft back, Cancel or a swipe-down hands
// back what it opened on. The rules (what can be hidden, gates, merge on reorder) are `TodayLayout`'s.

import SwiftUI

struct EditTodaySheet: View {
    @State private var edit: TodayLayoutEdit
    let gates: TodayFeatureGates
    let tiles: TodayTileAvailability
    /// Called once, with the layout to keep: the draft on Done, the original on Cancel.
    let onFinish: (TodayLayout) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(layout: TodayLayout, gates: TodayFeatureGates, tiles: TodayTileAvailability,
         onFinish: @escaping (TodayLayout) -> Void) {
        _edit = State(initialValue: TodayLayoutEdit(layout))
        self.gates = gates
        self.tiles = tiles
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Pinned") {
                    lockedRow(title: "Today's scores", note: "Always first", leadingLock: true)
                }

                Section {
                    let rows = edit.draft.editableSections(gates: gates)
                    ForEach(rows) { section in
                        sectionRow(section)
                            .accessibilityActions { moveActions(index: rows.firstIndex(of: section), count: rows.count) { from, to in
                                edit.draft.moveSections(from: [from], to: to, gates: gates)
                            } }
                    }
                    .onMove { edit.draft.moveSections(from: $0, to: $1, gates: gates) }
                } header: {
                    Text("Cards")
                } footer: {
                    Text("Drag to reorder. A hidden card stays here, so you can turn it back on.")
                }

                Section {
                    let rows = edit.draft.editableTiles(available: tiles)
                    ForEach(rows) { tile in
                        switchRow(title: tile.title, spokenTitle: tile.spokenTitle,
                                  isOn: Binding(get: { edit.draft.isShown(tile) },
                                                set: { edit.draft.setShown(tile, $0) }))
                        .accessibilityActions { moveActions(index: rows.firstIndex(of: tile), count: rows.count) { from, to in
                            edit.draft.moveTiles(from: [from], to: to, available: tiles)
                        } }
                    }
                    .onMove { edit.draft.moveTiles(from: $0, to: $1, available: tiles) }
                } header: {
                    Text("Your Numbers tiles")
                } footer: {
                    Text("Shown while Your Numbers is on. Hiding a tile never changes a score or the sentence.")
                }

                Section {
                    Button("Reset to default layout") { edit.draft.reset() }
                        .disabled(edit.draft == .standard)
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Today")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(.cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish(.done) }
                }
            }
        }
    }

    private func finish(_ outcome: TodayLayoutEdit.Outcome) {
        onFinish(edit.result(outcome))
        dismiss()
    }

    @ViewBuilder
    private func sectionRow(_ section: DashboardSection) -> some View {
        if TodayLayout.canHide(section) {
            switchRow(title: section.editTitle, spokenTitle: section.editTitle,
                      isOn: Binding(get: { edit.draft.isShown(section) },
                                    set: { edit.draft.setShown(section, $0) }))
        } else {
            lockedRow(title: section.editTitle, note: "Always shown", leadingLock: false)
        }
    }

    /// A card or tile with its Show switch, which VoiceOver reads as "Show <name>". At the accessibility
    /// sizes the switch goes under the name, so a long name wraps between words, not inside one.
    @ViewBuilder
    private func switchRow(title: String, spokenTitle: String, isOn: Binding<Bool>) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).accessibilityHidden(true)
                Toggle(isOn: isOn) { Text(title) }
                    .labelsHidden()
                    .accessibilityLabel("Show \(spokenTitle)")
            }
        } else {
            Toggle(isOn: isOn) { Text(title) }
                .accessibilityLabel("Show \(spokenTitle)")
        }
    }

    /// A row that can't be switched off: the title, then why, with a lock glyph. Stacked at the
    /// accessibility sizes so nothing truncates.
    private func lockedRow(title: String, note: String, leadingLock: Bool) -> some View {
        let lock = KeylineGlyph(.lock, size: 15, relativeTo: .body).foregroundStyle(.secondary)
        let noteText = Text(note).font(.subheadline).foregroundStyle(.secondary)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if leadingLock { lock }
                        Text(title)
                    }
                    HStack(spacing: 6) {
                        noteText
                        if !leadingLock { lock }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    if leadingLock { lock }
                    Text(title)
                    Spacer(minLength: 8)
                    noteText
                    if !leadingLock { lock }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Move up" / "Move down" for VoiceOver, alongside the List's own reorder handle.
    @ViewBuilder
    private func moveActions(index: Int?, count: Int, move: @escaping (Int, Int) -> Void) -> some View {
        if let index {
            if index > 0 {
                Button("Move up") { move(index, index - 1) }
            }
            if index < count - 1 {
                // `onMove` offsets: moving down one lands before the row after next.
                Button("Move down") { move(index, index + 2) }
            }
        }
    }
}
