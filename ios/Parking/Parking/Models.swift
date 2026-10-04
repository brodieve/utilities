import Foundation

/// A saved plate on Pass10x ("Previously Parked Plates"), shown as a button.
struct Guest: Codable, Identifiable, Hashable {
    var plate: String
    var name: String
    var phone: String

    var id: String { plate }
    var title: String { name.isEmpty ? plate : name }
}

/// A row of "Active Visitor Parking Passes".
struct ActivePass: Codable, Hashable {
    var name: String
    var plate: String
    var phone: String
    var start: String
    var end: String

    var title: String { name.isEmpty ? plate : name }
}

/// What Manage Parking shows, as read by P10.readParking().
struct ParkingState: Codable, Equatable {
    var active: [ActivePass] = []
    var saved: [Guest] = []

    static let cacheKey = "parkingState"

    /// The last state read, so the buttons show at once on launch.
    static func cached() -> ParkingState {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let state = try? JSONDecoder().decode(ParkingState.self, from: data) else { return ParkingState() }
        return state
    }

    func cache() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}

func normPlate(_ s: String) -> String {
    s.filter { !$0.isWhitespace && $0 != "-" }.uppercased()
}
