import SwiftUI

@main
struct GuestPassApp: App {
    @StateObject private var engine = PassEngine()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(engine)
        }
    }
}
