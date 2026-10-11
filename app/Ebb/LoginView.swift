import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model

    @State private var creatingAccount = false
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var role = "parent"
    @State private var busy = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            EbbScreen {
                if creatingAccount { createAccount } else { signIn }
            }
            .ebbNavigation("Ebb")
            .toolbar {
                if creatingAccount {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { creatingAccount = false; notice = nil } label: { Image(systemName: "chevron.left") }
                    }
                }
            }
        }
    }

    // MARK: Sign in

    @ViewBuilder private var signIn: some View {
        Image("EbbLogo")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 302)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: 0x3B5BA5), lineWidth: 1))
            .frame(maxWidth: .infinity)

        PageTitle(text: "A little support, together.",
                  subtitle: "For the adults helping a child find a calmer moment.")

        if let notice {
            EbbCard(title: "Email confirmation") {
                Text("Check your email").font(.title3).foregroundStyle(Ebb.ink)
                Text(notice).foregroundStyle(Ebb.ink)
            }
        }

        EbbCard(title: "Sign in") {
            credentials
            Button(busy ? "Signing in..." : "Sign in") { Task { await submit() } }
                .buttonStyle(.ebbPrimary)
                .disabled(busy || email.isEmpty || password.count < 6)
        }

        Button("Create an account") { creatingAccount = true; notice = nil }
            .buttonStyle(.ebbSecondary)
    }

    // MARK: Create account

    @ViewBuilder private var createAccount: some View {
        PageTitle(text: "Create an account")
        credentials
        Footnote(text: "Use at least 6 characters.")

        EbbCard(title: "About you") {
            FieldLabel(text: "Your name")
            TextField("Your name", text: $name).ebbField()
            Text("I am a").foregroundStyle(Ebb.ink)
            SegmentChoice(options: [("parent", "Parent"), ("teacher", "Teacher")], selection: $role)
        }

        Button(busy ? "Creating..." : "Create account") { Task { await submit() } }
            .buttonStyle(.ebbPrimary)
            .disabled(busy || email.isEmpty || password.count < 6)
        Button("I already have an account") { creatingAccount = false; notice = nil }
            .buttonStyle(.ebbSecondary)
    }

    @ViewBuilder private var credentials: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Email")
            TextField(text: $email, prompt: Text(verbatim: "you@example.com")) { Text("Email") }
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .ebbField()
        }
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "Password")
            SecureField("Password", text: $password)
                .textContentType(creatingAccount ? .newPassword : .password)
                .ebbField()
        }
    }

    private func submit() async {
        busy = true
        defer { busy = false }
        if creatingAccount {
            let ready = await model.signUp(email: email, password: password, name: name, role: role)
            if !ready && model.errorMessage == nil {
                notice = "Check your email and tap the confirmation link, then sign in here."
                creatingAccount = false
            }
        } else {
            await model.signIn(email: email, password: password)
        }
        Notifier.requestPermission()
    }
}
