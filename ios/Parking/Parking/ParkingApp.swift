import SwiftUI

@main
struct ParkingApp: App {
    @StateObject private var engine = PassEngine()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(engine)
        }
    }
}
