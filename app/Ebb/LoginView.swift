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
            Form {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(creatingAccount ? .newPassword : .password)
                }

                if creatingAccount {
                    Section("About you") {
                        TextField("Your name", text: $name)
                        Picker("I am a", selection: $role) {
                            Text("Parent").tag("parent")
                            Text("Teacher").tag("teacher")
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section {
                    Button(creatingAccount ? "Create account" : "Sign in") {
                        Task { await submit() }
                    }
                    .disabled(busy || email.isEmpty || password.count < 6)

                    Button(creatingAccount ? "I already have an account" : "Create an account") {
                        creatingAccount.toggle()
                        notice = nil
                    }
                    .font(.footnote)
                }

                if let notice {
                    Section { Text(notice).font(.footnote) }
                }
            }
            .navigationTitle("Ebb")
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
