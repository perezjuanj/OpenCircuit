import SwiftUI

/// The strap's on-demand live heart rate, shaped like the ring's Measure (decision 30): one round
/// heart control on the Measure card under the Resting HR detail's chart (`VitalMeasureCard`, #245),
/// and the same "Live Heart Rate" card on Today while it streams. A thin adapter over `HelioSession`;
/// the ring's path (`VitalMeasureCard.measureButton`, `RingSession.startMonitoring`) is untouched.
@MainActor
struct StrapLiveHeartRate {
    let session: HelioSession

    /// How long one measurement runs: the ring's heart-rate Measure budget (`RingSession`'s 90 s user
    /// measure). The spec sets no limit: the strap streams for as long as the app sends the 1 s
    /// keep-alive (ZEPP_PROTOCOL.md §7.1), and stops on `04 00`.
    nonisolated static let duration: TimeInterval = 90
    /// Said on the live card, so the stop is never a surprise.
    static let durationCopy = "Stops by itself after 90 seconds."

    /// The control appears only when this connection can start a stream: authenticated, with the
    /// heart-rate endpoint and characteristic present (a keyless strap has nothing to start).
    var canMeasure: Bool { session.canStreamHeartRate }
    /// A Measure is running. A workout's stream is not a measurement: it has its own screen (#227).
    var measuring: Bool { session.liveHeartRateRunning && session.liveHeartRateOwner == .measure }
    /// A reading from THIS measurement only (the start clears the previous one), nil while warming up.
    var liveHR: Int? { measuring ? session.liveHR : nil }
    /// Like the ring's, not while a history sync or a workout holds the link.
    var disabled: Bool { session.syncing || session.liveHeartRateOwner == .workout }

    func toggle() {
        if measuring { session.stopLiveHeartRate() } else { session.startLiveHeartRate(duration: Self.duration) }
    }
}

/// The same 30 pt round control as the ring's `VitalMeasureCard.measureButton` for heart rate (a heart
/// in a grey circle; while running, a stop icon in a filled red circle with a pulse), driving the strap.
struct StrapMeasureButton: View {
    let live: StrapLiveHeartRate

    var body: some View {
        let active = live.measuring
        let color: Color = .red
        Button {
            live.toggle()
        } label: {
            Image(systemName: active ? "stop.fill" : "heart.fill")
                .font(.caption2.weight(.bold))
                .frame(width: 30, height: 30)
                .background(Circle().fill(active ? color : Color(.systemGray5)))
                .foregroundStyle(active ? .white : color)
                .symbolEffect(.pulse, isActive: active)
        }
        .buttonStyle(.plain)
        .disabled(live.disabled)
        .accessibilityLabel(active ? "Stop measuring heart rate" : "Measure heart rate")
    }
}
