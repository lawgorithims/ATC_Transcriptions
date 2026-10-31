import SwiftUI

/// Settings → Account. Shows the sign-in form or the account, depending on state.
///
/// One entry point for both so the Settings row never has to know, and so signing in or out
/// swaps the page in place instead of popping the navigation stack out from under the pilot.
struct AccountScreen: View {
    @EnvironmentObject var account: AccountStore

    var body: some View {
        if account.isSignedIn {
            AccountView()
        } else {
            SignInView()
        }
    }
}

/// The signed-in account: who you are, what your subscription says, and the two ways out.
///
/// # What is deliberately NOT here
///
/// There is no upgrade button, no price, and no link to a page that sells anything. App Store
/// guideline 3.1.1 forbids buttons, external links or other calls to action pointing at a
/// purchasing mechanism other than in-app purchase, and that prohibition covers a "subscribe on
/// our website" link however politely it is worded. Showing the *status* of a subscription bought
/// elsewhere is what 3.1.3(b) permits for a multiplatform service, so this page reports and stops.
///
/// When the StoreKit rail lands (M3) the upgrade path belongs here as a real in-app purchase, and
/// `HANDOFF_MONETIZATION.md` §10 has the order of work.
struct AccountView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var account: AccountStore

    @State private var confirmingSignOut = false
    @State private var confirmingDelete = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let p = model.palette
        ScrollView {
            VStack(spacing: 16) {
                identityCard(p)
                subscriptionCard(p)
                sessionCard(p)
                dangerCard(p)
                legalCard(p)
            }
            .padding(16)
        }
        .background(p.bg)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Quietly re-read on open, so the plan on screen is not a week-old cache.
            await account.refresh()
        }
        .alert("Sign out?", isPresented: $confirmingSignOut) {
            Button("Cancel", role: .cancel) { }
            Button("Sign out", role: .destructive) { Task { await account.signOut() } }
        } message: {
            Text("Your downloaded charts, plates and notes stay on this device. Nothing is deleted.")
        }
        .alert("Delete your account?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete account", role: .destructive) {
                Task { _ = await account.deleteAccount() }
            }
        } message: {
            Text("This permanently deletes your account, signs you out everywhere and cancels any "
                 + "active subscription immediately. It cannot be undone. Charts and notes already "
                 + "on this device are not affected.")
        }
    }

    // MARK: Cards

    private func identityCard(_ p: Palette) -> some View {
        Card(title: "Signed in") {
            if let user = account.user {
                VStack(alignment: .leading, spacing: 4) {
                    if let name = user.name, !name.isEmpty {
                        Text(name).font(.dsHeadline).foregroundStyle(p.text)
                    }
                    Text(user.email)
                        .font(.dsDataMono).foregroundStyle(user.name == nil ? p.text : p.textDim)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("account-email-shown")
                }
                if !user.emailVerified {
                    Text("Email not yet verified.")
                        .font(.dsLabelS).foregroundStyle(p.textDim)
                }
            }
        }
    }

    private func subscriptionCard(_ p: Palette) -> some View {
        let entitlement = account.entitlement
        return Card(title: "Subscription") {
            HStack(spacing: 8) {
                Circle()
                    .fill(entitlement?.active == true ? p.good : p.textDim)
                    .frame(width: 8, height: 8)
                Text(entitlement?.planLabel ?? "Unknown")
                    .font(.dsLabelBold).foregroundStyle(p.text)
                    .accessibilityIdentifier("account-plan")
            }

            if let entitlement, entitlement.active, let end = entitlement.currentPeriodEnd {
                Text(entitlement.cancelAtPeriodEnd
                     ? "Ends \(Self.dateText(end))."
                     : "Renews \(Self.dateText(end)).")
                    .font(.dsLabelS).foregroundStyle(p.textDim)
            }

            // The honest statement of what this build does, and it is worth being explicit: the
            // entitlement layer grants every capability in this build (see EntitlementStore), so a
            // pilot without a subscription is not missing anything yet and should not be left
            // wondering what they lost.
            Text("Every feature is unlocked for everyone during the beta, whatever this says.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sessionCard(_ p: Palette) -> some View {
        Card(title: "This device") {
            Button {
                confirmingSignOut = true
            } label: {
                HStack(spacing: 8) {
                    if account.isWorking { ProgressView().controlSize(.small) }
                    Text("Sign out")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.outlined(p))
            .disabled(account.isWorking)
            .accessibilityIdentifier("account-signout")

            Text("Signs out this device only. Other devices and the website stay signed in.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func dangerCard(_ p: Palette) -> some View {
        Card(title: "Delete account") {
            Text("Removes your account, every sign-in session, any linked Apple or Google identity "
                 + "and your subscription records, and cancels an active subscription immediately.")
                .font(.dsLabelS).foregroundStyle(p.textDim)
                .fixedSize(horizontal: false, vertical: true)

            if let error = account.errorMessage {
                Text(error)
                    .font(.dsLabelS).foregroundStyle(p.bad)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account-delete-error")
            }

            Button {
                confirmingDelete = true
            } label: {
                Text("Delete account").frame(maxWidth: .infinity)
            }
            .buttonStyle(.plainHaptic)
            .font(.dsLabel)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .foregroundStyle(p.bad)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.r2))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.r2)
                .stroke(p.bad, lineWidth: DS.Stroke.control))
            .disabled(account.isWorking)
            .accessibilityIdentifier("account-delete")
        }
    }

    private func legalCard(_ p: Palette) -> some View {
        Card(title: "Legal") {
            Button("Privacy Policy") {
                openURL(URL(string: "https://obeliskaerospace.com/legal/privacy")!)
            }
            Button("Terms of Service") {
                openURL(URL(string: "https://obeliskaerospace.com/legal/terms")!)
            }
        }
        .font(.dsLabel)
        .foregroundStyle(p.accent)
        .buttonStyle(.plain)
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).day().year())
    }
}
