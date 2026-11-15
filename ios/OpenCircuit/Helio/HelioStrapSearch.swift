import Foundation

/// #372: telling two Helio Straps apart.
///
/// Every strap advertises the same name (`docs/ZEPP_PROTOCOL.md` §1), so a search can't tell the
/// person's strap from one nearby (a strap given to someone in the same home). The key can: only the
/// strap it was minted for accepts it. So in a foreground connect, a strap that answers `10 05 25` is
/// passed over instead of having the key marked rejected, and the search goes on.
///
/// - A refusing strap is skipped for the rest of this connect, and its identifier isn't saved: a
///   strap reached while passing one over is saved only once it accepts the key.
/// - A search that runs out with only refusing straps ends as decision 7 always did: the key is marked
///   rejected, and the app goes back to the first refusing strap (standard heart rate only).
/// - Background paths never pass a refusal on (`HelioSession.passesWrongKeyOn` is off): iOS drops
///   unfiltered background scans, so there is nothing to search with.
struct HelioStrapSearch: Equatable {
    /// Straps that refused the key in this connect, in the order they were tried.
    private(set) var refused: [UUID] = []

    /// A strap has refused the key in this connect: the next one is saved only once it accepts.
    var isPassingOver: Bool { !refused.isEmpty }

    /// A search result to ignore: it already refused the key.
    func skips(_ id: UUID) -> Bool { refused.contains(id) }

    /// A session should pass a wrong key on (look further) rather than mark it rejected: only with the
    /// app in front and no background run holding or adopting the link.
    static func passesWrongKeyOn(appIsActive: Bool, backgroundRunActive: Bool) -> Bool {
        appIsActive && !backgroundRunActive
    }

    /// The strap `id` refused the key: skip it from now on.
    mutating func refusedBy(_ id: UUID) {
        if !refused.contains(id) { refused.append(id) }
    }

    /// The search found no other strap. Returns the strap to go back to with the key marked rejected
    /// (the first that refused), or nil when nothing refused (a plain "not found"). Ends the connect.
    mutating func ranOut() -> UUID? {
        defer { refused = [] }
        return refused.first
    }

    /// A strap accepted the key, or a new connect started: forget the refusals.
    mutating func reset() { refused = [] }
}
