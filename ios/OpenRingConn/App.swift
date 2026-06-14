import SwiftUI
import SwiftData

@main
struct OpenRingConnApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [StoredSample.self, StoredCursor.self])
    }
}
