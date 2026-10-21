// Master–detail for wide windows (an unfolded foldable, an iPad, a split view).
//
// The rule is Apple's own (Mail, Health, Settings on iPad): the screen you already know stays as the
// LEFT column at its normal phone width — cards are never stretched — and whatever a tap would have
// pushed opens in the RIGHT column instead of replacing it.
//
// Closed (compact width) nothing changes: every tab is the same `NavigationStack` it always was.
// The switch is the window's horizontal size class, so fold posture, rotation, Split View and Stage
// Manager all just work with no per-device branching.
//
// Pure layout and navigation plumbing; no state beyond which detail is showing.

import SwiftUI

// MARK: - Detail model + environment

/// Which screen the right-hand column is showing. Lives only in a wide `SplitTab`.
@Observable
final class SplitDetailModel {
    private(set) var content: AnyView?
    /// Changes on every `show`, so re-selecting resets the detail column's navigation stack
    /// instead of leaving a previous push on top of it.
    private(set) var token = UUID()

    func show<V: View>(_ view: V) {
        content = AnyView(view)
        token = UUID()
    }
}

private struct SplitDetailKey: EnvironmentKey {
    static let defaultValue: SplitDetailModel? = nil
}

extension EnvironmentValues {
    /// Non-nil only inside the left column of a wide `SplitTab`.
    var splitDetail: SplitDetailModel? {
        get { self[SplitDetailKey.self] }
        set { self[SplitDetailKey.self] = newValue }
    }
}

// MARK: - DetailLink

/// A `NavigationLink` that opens in the right-hand column when there is one, and pushes as usual
/// when there isn't. Drop-in for `NavigationLink { destination } label: { … }` on the primary
/// screens of a tab.
struct DetailLink<Destination: View, Label: View>: View {
    @Environment(\.splitDetail) private var splitDetail
    private let destination: Destination
    private let label: Label

    init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {
        self.destination = destination()
        self.label = label()
    }

    var body: some View {
        if let splitDetail {
            Button { splitDetail.show(destination) } label: { label }
        } else {
            NavigationLink { destination } label: { label }
        }
    }
}

// MARK: - SplitTab

/// One tab's root. Compact: a plain `NavigationStack` around `primary`. Regular: `primary` as the
/// left column and the selected detail (or `emptyDetail` until something is chosen) on the right.
struct SplitTab<Primary: View, EmptyDetail: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var model = SplitDetailModel()
    private let primary: Primary
    private let emptyDetail: EmptyDetail

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder emptyDetail: () -> EmptyDetail) {
        self.primary = primary()
        self.emptyDetail = emptyDetail()
    }

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView(columnVisibility: .constant(.doubleColumn)) {
                primary
                    .environment(\.splitDetail, model)
                    .navigationSplitViewColumnWidth(min: 340, ideal: 390, max: 440)
            } detail: {
                NavigationStack {
                    Group {
                        if let content = model.content { content } else { emptyDetail }
                    }
                    .id(model.token)
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack { primary }
        }
    }
}

// MARK: - Viewport pin (compact only)

private struct PinnedToViewportWhenCompact: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            // Wide: this view lives in a split-view column. `containerRelativeFrame` would size it
            // against the WHOLE window instead of the column, so a detail pane overran its column
            // and was clipped (the Sleep tab on an unfolded foldable / iPad). The column already
            // proposes the right width.
            content
        } else {
            content.containerRelativeFrame(.horizontal)
        }
    }
}

extension View {
    /// Pins a vertical `ScrollView`'s content to exactly the viewport width, so fractional-point
    /// rounding can never let it pan sideways (see the Sleep tab, commit 87d2911). Compact width
    /// only: in a wide split-view column the pin is skipped, because it resolves against the window.
    func pinnedToViewportWhenCompact() -> some View {
        modifier(PinnedToViewportWhenCompact())
    }
}

// MARK: - Tab bar

extension View {
    /// iPadOS 18+/wide windows: let the bottom tab bar become the top bar / sidebar. Phone widths
    /// still get the standard bottom tab bar, and iOS 17 keeps it everywhere.
    @ViewBuilder
    func adaptiveTabBar() -> some View {
        if #available(iOS 18.0, *) {
            self.tabViewStyle(.sidebarAdaptable)
        } else {
            self
        }
    }
}
