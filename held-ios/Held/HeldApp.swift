import SwiftUI

@main
struct HeldApp: App {
    @StateObject private var engine = PitchEngine()

    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView(engine: engine)
                    .tabItem { Label("Tune", systemImage: "tuningfork") }
                RecallView(engine: engine)
                    .tabItem { Label("Recall", systemImage: "brain") }
            }
            .tint(Color.heldBrass)
        }
    }
}
