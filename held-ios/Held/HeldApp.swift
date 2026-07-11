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
                EarView()
                    .tabItem { Label("Ear", systemImage: "ear") }
                IntervalView(engine: engine)
                    .tabItem { Label("Intervals", systemImage: "arrow.up.arrow.down") }
                LibraryView(engine: engine)
                    .tabItem { Label("Songs", systemImage: "music.note.list") }
            }
            .tint(Color.heldBrass)
        }
    }
}
