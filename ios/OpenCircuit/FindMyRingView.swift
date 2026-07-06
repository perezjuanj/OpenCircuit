import SwiftUI
import OpenCircuitKit

/// Find My Ring (#96) — mirrors the official app's locator screen. While it's on screen the ring is
/// in proximity/search mode and we poll the BLE link RSSI (~1 Hz), driving an approximate-distance
/// readout, plus a button to blink the ring's LED on/off. Leaving the screen turns the LED off and
/// exits proximity mode (see `RingSession.startFindingRing`/`stopFindingRing`).
///
/// The distance is a deliberately-coarse Bluetooth estimate (`RingProximity`) — the qualitative band
/// is the trustworthy part; the "≈ N ft" is a hint.
struct FindMyRingView: View {
    var session: RingSession?

    private var rssi: Int? { session?.ringRSSI }
    private var band: RingProximity.Band { RingProximity.band(forRSSI: rssi) }
    private var lightOn: Bool { session?.findRingLightOn ?? false }

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)

            proximityDial

            VStack(spacing: 6) {
                Text(band.label)
                    .font(.title2.weight(.semibold))
                    .contentTransition(.opacity)
                if let distance = RingProximity.distanceText(forRSSI: rssi) {
                    Text(distance)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Move around the room to pick up a signal.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer(minLength: 12)

            lightButton

            Text("Distance is a rough Bluetooth estimate — walls, your hand, and how the ring is "
                 + "turned all affect it. Use “Light up ring” to spot it once you're close.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .navigationTitle("Find My Ring")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { session?.startFindingRing() }
        .onDisappear { session?.stopFindingRing() }
    }

    /// A radial signal dial: the ring fills with proximity, and the centre glyph lights up when the LED is on.
    private var proximityDial: some View {
        let fraction = RingProximity.signalFraction(forRSSI: rssi)
        return ZStack {
            Circle().stroke(.quaternary, lineWidth: 14)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.45), value: fraction)
            Image(systemName: lightOn ? "lightbulb.fill" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 56))
                .foregroundStyle(lightOn ? AnyShapeStyle(.yellow) : AnyShapeStyle(tint))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 200, height: 200)
        .padding(.vertical, 8)
    }

    private var lightButton: some View {
        Button {
            session?.setFindRingLight(on: !lightOn)
        } label: {
            Label(lightOn ? "Turn off light" : "Light up ring",
                  systemImage: lightOn ? "lightbulb.slash.fill" : "lightbulb.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(lightOn ? .orange : .accentColor)
        .disabled(session?.ready != true)
    }

    /// Dial colour tracks the proximity band — green when you're on top of it, cooling to grey as it fades.
    private var tint: Color {
        switch band {
        case .veryClose: return .green
        case .close:     return .mint
        case .nearby:    return .blue
        case .far:       return .orange
        case .searching: return .gray
        }
    }
}
