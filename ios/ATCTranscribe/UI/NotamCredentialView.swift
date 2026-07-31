import SwiftUI

/// Where the FAA NOTAM API key is entered.
///
/// The FAA's NOTAM service refuses anonymous requests, so this feature cannot work without a key the
/// pilot registers for themselves. The screen therefore has to do two things honestly: explain why it
/// is asking, and make clear that until a key is present the app is not saying there are no NOTAMs —
/// it is saying it has not asked.
///
/// The secret goes to the KEYCHAIN, never to UserDefaults, and is never rendered back after saving.
struct NotamCredentialView: View {
    @ObservedObject var store: NotamStore
    let palette: Palette

    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var saved = false

    private var p: Palette { palette }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                explain
                if store.credentialConfigured && !saved { configured } else { form }
                privacy
            }
            .padding(16)
        }
        .background(p.bg.ignoresSafeArea())
        .navigationTitle("NOTAM feed")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("notam-credential")
    }

    private var explain: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WHY A KEY IS NEEDED").dsSectionHeader(p)
            Text("The FAA's NOTAM API rejects anonymous requests. A developer key is free and takes a few minutes to register at api.faa.gov; it gives a client ID and a client secret, which go below.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Text("Without one, the NOTAM panel says so explicitly rather than showing an empty list — an empty list would read as “there are no NOTAMs”, which is a very different thing.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var configured: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("A key is configured", systemImage: "checkmark.seal.fill")
                .font(.dsLabelBold).foregroundStyle(p.good)
            Button {
                Haptics.impact(.medium); store.clearCredential(); clientID = ""; clientSecret = ""
            } label: {
                Text("Remove this key").font(.dsLabelS)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(p.bad.opacity(0.14), in: Capsule())
                    .foregroundStyle(p.bad)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("notam-clear-credential")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Client ID").font(.dsLabelS).foregroundStyle(p.textDim)
            TextField("client_id", text: $clientID)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("notam-client-id")
            Text("Client secret").font(.dsLabelS).foregroundStyle(p.textDim)
            SecureField("client_secret", text: $clientSecret)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("notam-client-secret")
            Button {
                Haptics.impact(.medium)
                store.setCredential(clientID: clientID, clientSecret: clientSecret)
                clientSecret = ""
                saved = false
            } label: {
                Text("Save").font(.dsLabelBold)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background(p.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: DS.Radius.r4))
                    .foregroundStyle(p.accent)
            }
            .buttonStyle(.plain)
            .disabled(clientID.isEmpty || clientSecret.isEmpty)
            .accessibilityIdentifier("notam-save-credential")
        }
    }

    private var privacy: some View {
        Text("The secret is stored in the device keychain, not in preferences, and is never written to the log. It is sent only to external-api.faa.gov.")
            .font(.system(size: 9)).foregroundStyle(p.textDim)
            .fixedSize(horizontal: false, vertical: true)
    }
}
