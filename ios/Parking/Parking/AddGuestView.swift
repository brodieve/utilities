import SwiftUI

/// Saves a new plate on Pass10x ("Setup a Visitor Pass"), which becomes a button.
struct AddGuestView: View {
    let onSave: (Guest, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var plate = ""
    @State private var name = ""
    @State private var phone = ""
    @State private var createNow = true

    private var cleanPlate: String { normPlate(plate) }
    private var phoneOK: Bool { phone.isEmpty || (phone.count == 10 && phone.allSatisfy(\.isNumber)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Plate", text: $plate)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    TextField("Name", text: $name)
                    TextField("Cell number (optional)", text: $phone)
                        .keyboardType(.phonePad)
                } footer: {
                    if !phoneOK { Text("Cell number must be 10 digits.") }
                }
                Section {
                    Toggle("Create pass now", isOn: $createNow)
                } footer: {
                    Text(createNow ? "Any other active pass will be cancelled." : "Saves the guest as a button only.")
                }
            }
            .navigationTitle("New Guest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(Guest(plate: cleanPlate, name: name.trimmingCharacters(in: .whitespaces), phone: phone),
                               createNow)
                        dismiss()
                    }
                    .disabled(cleanPlate.isEmpty || !phoneOK)
                }
            }
        }
    }
}
