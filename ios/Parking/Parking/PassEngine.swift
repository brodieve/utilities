import Foundation
import WebKit

/// Drives the Pass10x resident web app in a WKWebView, one step at a time.
///
/// pass10x.js is injected into every page and does the work inside the page;
/// this class loads pages, calls one P10 step, and polls P10.where() until
/// the next page is up. tests/run.mjs runs the same sequence in Chromium.
@MainActor
final class PassEngine: NSObject, ObservableObject {
    static let home = URL(string: "https://www.pass10x.com/")!

    @Published private(set) var state = ParkingState.cached()
    @Published private(set) var status: String?
    @Published var error: String?

    var isBusy: Bool { status != nil }
    var activePass: ActivePass? { state.active.first }

    let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        let source = Bundle.main.url(forResource: "pass10x", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        config.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        // The default store keeps the site's login between launches, so most
        // runs skip the login pages.
        config.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    // MARK: - Operations

    func refresh() async {
        await run("Checking passes") {
            try await self.openManage()
            try await self.read()
        }
    }

    /// Make `guest` the active pass, cancelling any other active pass first.
    func activate(_ guest: Guest) async {
        await run("Creating pass for \(guest.title)") {
            try await self.activateSteps(guest)
        }
    }

    /// Save a new plate on Pass10x, and optionally make it the active pass.
    func add(_ guest: Guest, activate: Bool) async {
        await run("Saving \(guest.plate)") {
            try await self.openManage()
            try await self.step("saveVisitor", ["plate": guest.plate, "name": guest.name, "phone": guest.phone])
            try await self.read()
            if activate { try await self.activateSteps(guest) }
        }
    }

    /// Delete a saved plate on Pass10x with its trash icon. The JS step
    /// refuses a plate that has the active pass.
    func remove(_ guest: Guest) async {
        await run("Removing \(guest.title)") {
            try await self.openManage()
            try await self.step("removeVisitor", ["plate": guest.plate])
            try await self.read()
        }
    }

    /// Cancel `pass` with its delete button in Active Visitor Parking Passes.
    /// It need not be a saved guest's: a pass made on the website works too.
    func revoke(_ pass: ActivePass) async {
        await run("Revoking \(pass.title)'s pass") {
            try await self.openManage()
            try await self.step("cancelPass", ["plate": pass.plate])
            try await self.read()
        }
    }

    private func activateSteps(_ guest: Guest) async throws {
        try await openManage()
        try await read()
        let plate = normPlate(guest.plate)
        for pass in state.active where normPlate(pass.plate) != plate {
            status = "Cancelling \(pass.title)"
            try await step("cancelPass", ["plate": pass.plate])
        }
        if state.active.contains(where: { normPlate($0.plate) == plate }) {
            try await read()
            return
        }
        status = "Creating pass for \(guest.title)"
        try await step("openCreate", ["plate": guest.plate])
        try await waitFor("the pass form") { $0["passForm"] as? Bool == true }
        try await step("submitPass", ["plate": guest.plate])
        let w = try await waitFor("the pass to be created") {
            $0["passCreated"] as? Bool == true || !(($0["messages"] as? [String]) ?? []).isEmpty
        }
        if w["passCreated"] as? Bool != true {
            throw EngineError((w["messages"] as? [String])?.joined(separator: " ") ?? "Pass10x did not create the pass.")
        }
        status = "Checking passes"
        try await openManage()
        try await read()
    }

    private func run(_ label: String, _ work: @escaping () async throws -> Void) async {
        guard !isBusy else { return }
        error = nil
        status = label
        defer { status = nil }
        do {
            try await work()
        } catch {
            self.error = Self.message(error)
        }
    }

    // MARK: - Pages

    private func ensureDashboard() async throws {
        let credentials = Credentials.load()
        guard credentials.isComplete else { throw EngineError("Add your Pass10x login in Settings.") }

        try await load(URL(string: "/dashboard", relativeTo: Self.home)!)
        let w = try? await waitFor("the dashboard", timeout: 10) {
            $0["dashboard"] as? Bool == true || $0["home"] as? Bool == true || $0["signin"] as? Bool == true
        }
        if w?["dashboard"] as? Bool == true { return }

        let label = status
        status = "Logging in"
        try await load(Self.home)
        try await waitFor("the home page") { $0["home"] as? Bool == true }
        try await step("chooseBuilding", ["building": credentials.building])
        try await waitFor("the building") { $0["buildingChosen"] as? Bool == true }
        try await step("chooseResident", ["suite": credentials.suite])
        try await waitFor("the sign in page") { $0["signin"] as? Bool == true }
        try await step("submitLogin", ["password": credentials.password])
        try await waitFor("the dashboard") { $0["dashboard"] as? Bool == true }
        status = label
    }

    private func openManage() async throws {
        try await ensureDashboard()
        try await step("openManage")
        try await waitFor("Manage Parking") { $0["manage"] as? Bool == true }
    }

    private func read() async throws {
        let result = try await step("readParking")
        let data = try JSONSerialization.data(withJSONObject: result ?? [:])
        state = try JSONDecoder().decode(ParkingState.self, from: data)
        state.cache()
    }

    // MARK: - Web view plumbing

    @discardableResult
    private func step(_ name: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await webView.callAsyncJavaScript(
            "return await window.P10[name](args)",
            arguments: ["name": name, "args": args],
            contentWorld: .page)
    }

    private func whereNow() async -> [String: Any] {
        let result = try? await webView.callAsyncJavaScript(
            "return window.P10 ? window.P10.where() : {}", contentWorld: .page)
        return result as? [String: Any] ?? [:]
    }

    @discardableResult
    private func waitFor(_ what: String, timeout: TimeInterval = 20,
                         _ done: ([String: Any]) -> Bool) async throws -> [String: Any] {
        let end = Date().addingTimeInterval(timeout)
        while true {
            let w = await whereNow()
            if done(w) { return w }
            if let loginError = w["loginError"] as? String, !loginError.isEmpty { throw EngineError(loginError) }
            if Date() > end { throw EngineError("Timed out waiting for \(what).") }
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private func load(_ url: URL) async throws {
        loadContinuation?.resume()
        try await withCheckedThrowingContinuation { continuation in
            loadContinuation = continuation
            webView.load(URLRequest(url: url))
        }
    }

    private func finishLoad(_ error: Error?) {
        guard let continuation = loadContinuation else { return }
        loadContinuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    private static func message(_ error: Error) -> String {
        let ns = error as NSError
        if let js = ns.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return js.replacingOccurrences(of: "Error: ", with: "")
        }
        return error.localizedDescription
    }
}

extension PassEngine: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoad(nil) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let failure = Self.ignoringCancel(error)
        Task { @MainActor in self.finishLoad(failure) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        let failure = Self.ignoringCancel(error)
        Task { @MainActor in self.finishLoad(failure) }
    }

    /// A load replaced by a redirect or a newer load is not a failure.
    nonisolated private static func ignoringCancel(_ error: Error) -> Error? {
        (error as NSError).code == NSURLErrorCancelled ? nil : error
    }
}

struct EngineError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
