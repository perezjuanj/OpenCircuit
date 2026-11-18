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
import UIKit

// MARK: - Wide split (width, not just size class)

/// Whether a tab shows its two-column master–detail layout. `horizontalSizeClass == .regular` is
/// necessary but not enough: iPhone Duo's inner display is regular width in PORTRAIT too, at about
/// 669 pt, where a 340–440 pt list column leaves a cramped detail pane (the system then tucks the
/// list behind a sidebar button). Below `WideSplit.minimumWidth` the app keeps the single-column
/// phone layout; landscape (951 pt) and iPad keep the split.
enum WideSplit {
    static let minimumWidth: CGFloat = 700
}

private struct WideSplitKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the window is regular width AND wide enough for two columns. Set once at the root
    /// by `provideWideSplit()`; read by `SplitTab` and the tabs that branch on wide.
    var isWideSplit: Bool {
        get { self[WideSplitKey.self] }
        set { self[WideSplitKey.self] = newValue }
    }
}

private struct WindowWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct WideSplitProvider: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = Self.initialWindowWidth()

    /// The window's width before the first layout pass, so a regular-width but narrow window (iPhone
    /// Duo's inner display in portrait) never builds the split for one frame on a cold launch. 0 when
    /// no scene is connected yet, which falls back to the size class alone.
    private static func initialWindowWidth() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.coordinateSpace.bounds.width ?? 0
    }

    func body(content: Content) -> some View {
        // Until a width is known, follow the size class alone (as the app always did).
        let wide = sizeClass == .regular && (width == 0 || width >= WideSplit.minimumWidth)
        content
            .environment(\.isWideSplit, wide)
            .background(GeometryReader { geo in
                Color.clear.preference(key: WindowWidthKey.self, value: geo.size.width)
            })
            .onPreferenceChange(WindowWidthKey.self) { width = $0 }
    }
}

extension View {
    /// Apply once, above everything that reads `isWideSplit` (including `ContentView` itself).
    func provideWideSplit() -> some View { modifier(WideSplitProvider()) }
}

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
    @Environment(\.isWideSplit) private var isWide
    @State private var model = SplitDetailModel()
    private let primary: Primary
    private let emptyDetail: EmptyDetail

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder emptyDetail: () -> EmptyDetail) {
        self.primary = primary()
        self.emptyDetail = emptyDetail()
    }

    var body: some View {
        if isWide {
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

// MARK: - Viewport-pinned scroll view (compact only)

/// A vertical `ScrollView` whose content is pinned to exactly the scroll view's own width, so
/// fractional-point rounding can never let it pan SIDEWAYS. Measured on device (iPhone 15 Pro,
/// 393pt): the NavigationStack is 393.00, the ScrollView 393.33 and the content 393.67 — SwiftUI
/// rounds a fractional row width UP to the 1/3pt pixel grid, one step per nesting level, and two
/// physical pixels is enough for UIScrollView to allow a horizontal drag that rubber-banding turns
/// into ~77pt (the Sleep tab, commit 87d2911). No subview is over-wide, so there is nothing to
/// narrow; the content simply has to be told it is exactly viewport-width.
///
/// The width is the space the PARENT offers (a `GeometryReader` around the scroll view), never the
/// scroll view's own size and never `containerRelativeFrame`. On iOS 27 both of those follow the
/// content: `containerRelativeFrame` kept the portrait width after the phone turned (Sleep stayed a
/// narrow column in landscape, #374), and measuring the scroll view kept the LANDSCAPE width after
/// turning back, because the scroll view hugged the content it had just pinned. A GeometryReader's
/// size comes only from its proposal, so there is no loop: it follows rotation both ways, Split
/// View and fold changes. Skipped in a wide split-view column, which proposes the right width
/// already.
struct ViewportPinnedScrollView<Content: View>: View {
    @Environment(\.isWideSplit) private var isWide
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        if isWide {
            ScrollView { content }
        } else {
            GeometryReader { viewport in
                ScrollView {
                    content.frame(width: viewport.size.width)
                }
            }
        }
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
