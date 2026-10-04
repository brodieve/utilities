import SwiftUI

struct SettingsView: View {
    @Binding var showBrowser: Bool
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var credentials = Credentials.load()
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Building", text: $credentials.building)
                    TextField("Suite / User ID", text: $credentials.suite)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $credentials.password)
                } header: {
                    Text("Pass10x Login")
                } footer: {
                    Text("Saved in this iPhone's Keychain.")
                }
                Section {
                    Toggle("Show browser", isOn: $showBrowser)
                } footer: {
                    Text("Shows the Pass10x page the app is working in, to see where a step gets stuck.")
                }
                if let error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            credentials.suite = credentials.suite.trimmingCharacters(in: .whitespaces)
                            try credentials.save()
                            dismiss()
                            onSave()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    .disabled(!credentials.isComplete)
                }
            }
        }
    }
}
