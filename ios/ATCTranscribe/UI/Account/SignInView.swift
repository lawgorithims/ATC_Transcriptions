import AuthenticationServices
import SwiftUI

/// Sign in, or create an account.
///
/// Reached from Settings → Account. It is a pushed page, never a modal wall: `UI/ConsoleView.swift`
/// records what a non-dismissible cover cost this app once — *"bricked, with no way out but a
/// reinstall"* — and an EFB must never put a login between a pilot and a chart. The copy says so
/// out loud, because a pilot who opens this by accident should be able to tell at a glance that
/// they can walk away.
struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var account: AccountStore

    private enum Mode: String, CaseIterable {
        case signIn = "Sign in"
        case create = "Create account"
    }

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""

    /// One nonce per attempt, replaced every time the button builds a request. Apple echoes it into
    /// the identity token and the server compares it — see `AppleSignIn.makeNonce`.
    @State private var appleNonce = AppleSignIn.makeNonce()

    @Environment(\.openURL) private var openURL

    private var canSubmit: Bool {
        !account.isWorking
            && email.contains("@")
            && password.count >= 8
    }

    var body: some View {
        let p = model.palette
        ScrollView {
            VStack(spacing: 16) {
                optionalNotice(p)

                Card(title: mode.rawValue) {
                    Picker("", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("account-mode")

                    if mode == .create {
                        field(p, "Name", text: $name, id: "account-name",
                              placeholder: "Optional", keyboard: .default,
                              capitalization: .words, content: .name)
                    }
                    field(p, "Email", text: $email, id: "account-email",
                          placeholder: "you@example.com", keyboard: .emailAddress,
                          capitalization: .never, content: .username)
                    secureField(p)

                    if let error = account.errorMessage {
                        Text(error)
                            .font(.dsLabelS).foregroundStyle(p.bad)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("account-error")
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        HStack(spacing: 8) {
                            if account.isWorking { ProgressView().controlSize(.small) }
                            Text(mode == .signIn ? "Sign in" : "Create account")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.outlinedProminent(p))
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)
                    .accessibilityIdentifier("account-submit")

                    if mode == .signIn {
                        Button("Forgot your password?") {
                            openURL(URL(string: "https://obeliskaerospace.com/forgot-password")!)
                        }
                        .font(.dsLabelS)
                        .foregroundStyle(p.accent)
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("account-forgot")
                    }
                }

                federatedCard(p)
                legalFootnote(p)
            }
            .padding(16)
        }
        .background(p.bg)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: email) { _, _ in account.errorMessage = nil }
        .onChange(of: password) { _, _ in account.errorMessage = nil }
        .onChange(of: mode) { _, _ in account.errorMessage = nil }
    }

    // MARK: Pieces

    /// The first thing on the page: you do not need this.
    private func optionalNotice(_ p: Palette) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle").font(.dsLabel).foregroundStyle(p.accent)
            Text("An account is optional. Charts, plates, procedures and flight planning all work "
                 + "without one, and nothing about your flying is ever sent to us. Signing in is "
                 + "how a subscription follows you onto another device.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(p.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r4))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.r4).stroke(p.border, lineWidth: 1))
    }

    private func federatedCard(_ p: Palette) -> some View {
        Card(title: "Or continue with") {
            SignInWithAppleButton(.continue) { request in
                appleNonce = AppleSignIn.makeNonce()
                AppleSignIn.configure(request, nonce: appleNonce)
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    do {
                        let credential = try AppleSignIn.credential(from: authorization)
                        Task {
                            await account.signInWithApple(identityToken: credential.identityToken,
                                                          nonce: appleNonce,
                                                          fullName: credential.fullName)
                        }
                    } catch {
                        account.report(error)
                    }
                case .failure(let error):
                    account.report(AppleSignIn.mapError(error))
                }
            }
            // Apple ships three styles and none of them is red. On the night theme the whole app
            // emits red only, to protect dark adaptation, so take the darkest option there rather
            // than putting a white rectangle in front of a pilot at altitude.
            .signInWithAppleButtonStyle(model.theme == .day ? .black
                                        : model.theme == .night ? .black : .white)
            .frame(height: 44)
            .disabled(account.isWorking)
            .accessibilityIdentifier("account-apple")

            Button {
                Task { await account.signInWithGoogle() }
            } label: {
                Text("Continue with Google").frame(maxWidth: .infinity)
            }
            .buttonStyle(.outlined(p))
            .disabled(account.isWorking)
            .accessibilityIdentifier("account-google")

            Text("Either one creates an account the first time you use it. If you already signed "
                 + "up on obeliskaerospace.com, use the same method and you'll land on the same "
                 + "account.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func legalFootnote(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By creating an account you agree to the Terms of Service and acknowledge the "
                 + "Privacy Policy.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Button("Privacy Policy") {
                    openURL(URL(string: "https://obeliskaerospace.com/legal/privacy")!)
                }
                .accessibilityIdentifier("account-privacy")
                Button("Terms of Service") {
                    openURL(URL(string: "https://obeliskaerospace.com/legal/terms")!)
                }
                .accessibilityIdentifier("account-terms")
            }
            .font(.dsLabelS)
            .foregroundStyle(p.accent)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }

    // MARK: Fields

    private func field(_ p: Palette, _ label: String, text: Binding<String>, id: String,
                       placeholder: String, keyboard: UIKeyboardType,
                       capitalization: TextInputAutocapitalization,
                       content: UITextContentType) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.dsLabel).foregroundStyle(p.textDim)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).autocorrectionDisabled()
                .textInputAutocapitalization(capitalization)
                .keyboardType(keyboard)
                .textContentType(content)
                .font(.dsLabel)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: DS.Radius.r2))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.r2).stroke(p.border, lineWidth: 1))
                .accessibilityIdentifier(id)
        }
    }

    private func secureField(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Password").font(.dsLabel).foregroundStyle(p.textDim)
            SecureField(mode == .create ? "At least 8 characters" : "Your password", text: $password)
                .textFieldStyle(.plain)
                .textContentType(mode == .create ? .newPassword : .password)
                .font(.dsLabel)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(p.surfaceAlt).clipShape(RoundedRectangle(cornerRadius: DS.Radius.r2))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.r2).stroke(p.border, lineWidth: 1))
                .accessibilityIdentifier("account-password")
            if mode == .create {
                Text("8 characters or more.").font(.dsLabelS).foregroundStyle(p.textDim)
            }
        }
    }

    private func submit() async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .signIn:
            await account.signIn(email: trimmedEmail, password: password)
        case .create:
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            await account.signUp(email: trimmedEmail,
                                 password: password,
                                 name: trimmedName.isEmpty ? nil : trimmedName)
        }
        if account.isSignedIn { password = "" }
    }
}
