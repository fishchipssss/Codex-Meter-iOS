import SwiftUI
import UIKit

struct ProxySetupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: MeterViewModel
    @State private var setupCode = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Run Proxy/install.sh on a signed-in Mac or Linux computer connected to your tailnet, then paste the setup code it prints.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextEditor(text: $setupCode)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 110)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        setupCode = UIPasteboard.general.string ?? ""
                        errorMessage = nil
                    } label: {
                        Label("Paste setup code", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("Setup code")
                } footer: {
                    Text("The access token is stored in this device’s Keychain and is only sent to your Tailscale HTTPS address.")
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                Section {
                    Button {
                        Task { await addProxy() }
                    } label: {
                        HStack {
                            if model.isAddingProxy { ProgressView() }
                            Text(model.isAddingProxy ? "Testing proxy…" : "Test and add proxy")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(setupCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isAddingProxy)
                }
            }
            .scrollContentBackground(.hidden)
            .background { MeterBackdrop() }
            .navigationTitle("Codex CLI Proxy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .tint(MeterTheme.blue)
    }

    private func addProxy() async {
        let original = setupCode
        do {
            try await model.addProxy(setupCode: original)
            if UIPasteboard.general.string == original { UIPasteboard.general.string = "" }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
