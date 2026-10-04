import SwiftUI
import WebKit

struct ContentView: View {
    @EnvironmentObject private var engine: PassEngine
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var showBrowser = false
    @State private var replacing: Guest?

    var body: some View {
        ZStack {
            // The web view does the work behind the app; it stays on screen
            // (just covered) so WebKit keeps the page running at full speed.
            WebViewHost(webView: engine.webView)
                .ignoresSafeArea()
                .zIndex(showBrowser ? 1 : 0)
                .allowsHitTesting(showBrowser)

            NavigationStack { content }
                .zIndex(showBrowser ? 0 : 1)

            if showBrowser {
                Button("Hide Browser") { showBrowser = false }
                    .buttonStyle(.borderedProminent)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding()
                    .zIndex(2)
            }
        }
        .task {
            if Credentials.load().isComplete { await engine.refresh() } else { showSettings = true }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ActivePassCard(pass: engine.activePass)

                if let status = engine.status {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(status + "…").foregroundStyle(.secondary)
                    }
                }
                if let error = engine.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(engine.state.saved) { guest in
                        GuestButton(guest: guest, isActive: isActive(guest)) { tapped(guest) }
                            .disabled(engine.isBusy)
                    }
                }

                if engine.state.saved.isEmpty && !engine.isBusy {
                    VStack(spacing: 12) {
                        Image("Logo").resizable().frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                        Text("No saved guests yet. Tap + to add one.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .refreshable { await engine.refresh() }
        .navigationTitle("Guest Parking")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showAdd = true } label: { Image(systemName: "plus") }
                    .disabled(engine.isBusy)
            }
        }
        .confirmationDialog(replaceTitle, isPresented: replacingBinding, titleVisibility: .visible) {
            if let guest = replacing {
                Button("Create pass for \(guest.title)") { Task { await engine.activate(guest) } }
            }
        } message: {
            Text("Only one visitor pass is allowed at a time, so the current pass will be cancelled.")
        }
        .sheet(isPresented: $showAdd) {
            AddGuestView { guest, activateNow in
                Task { await engine.add(guest, activate: activateNow) }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(showBrowser: $showBrowser) { Task { await engine.refresh() } }
        }
    }

    private func isActive(_ guest: Guest) -> Bool {
        engine.state.active.contains { normPlate($0.plate) == normPlate(guest.plate) }
    }

    private func tapped(_ guest: Guest) {
        if isActive(guest) { return }
        if engine.activePass != nil {
            replacing = guest
        } else {
            Task { await engine.activate(guest) }
        }
    }

    private var replaceTitle: String {
        guard let pass = engine.activePass else { return "" }
        return "Replace \(pass.name.isEmpty ? pass.plate : pass.name)'s pass?"
    }

    private var replacingBinding: Binding<Bool> {
        Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })
    }
}

struct ActivePassCard: View {
    let pass: ActivePass?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ACTIVE PASS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if let pass {
                Text(pass.name.isEmpty ? pass.plate : pass.name).font(.title2.weight(.semibold))
                Text(pass.plate).font(.headline.monospaced())
                Text("Until \(pass.end)").foregroundStyle(.secondary)
            } else {
                Text("None").font(.title2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct GuestButton: View {
    let guest: Guest
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(guest.title).font(.headline).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    if isActive { Image(systemName: "checkmark.circle.fill") }
                }
                Text(guest.plate).font(.subheadline.monospaced()).opacity(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(12)
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .background(isActive ? Color.green : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

struct WebViewHost: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
