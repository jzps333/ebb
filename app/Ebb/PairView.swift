import SwiftUI

/// Scan the QR on an unpaired watch. A parent then picks (or adds) the child it
/// belongs to; a teacher is linked to that child straight away.
struct PairView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var code: String?
    @State private var typedCode = ""
    @State private var busy = false
    @State private var result: PairResult?
    @State private var addingChild = false
    @State private var pairedChild: Child?

    var body: some View {
        NavigationStack {
            Group {
                if let result, result.ok {
                    done(result)
                } else if let code {
                    if model.profile?.isTeacher == true {
                        teacherJoin(code)
                    } else {
                        chooseChild(code)
                    }
                } else {
                    scan
                }
            }
            .navigationTitle("Pair watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
        }
    }

    private var scan: some View {
        VStack(spacing: 16) {
            QRScannerView { scanned in
                if PairView.looksLikeCode(scanned) { code = scanned }
            }
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text("Point the camera at the QR code on the watch.")
                .multilineTextAlignment(.center)

            // For testing without a camera (e.g. a simulator): the code is the
            // 20 characters the QR holds; device-api logs it on the watch's serial.
            DisclosureGroup("Type the code instead") {
                HStack {
                    TextField("20-character code", text: $typedCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Button("Use") { code = typedCode.uppercased().trimmingCharacters(in: .whitespaces) }
                        .disabled(!PairView.looksLikeCode(typedCode.uppercased()))
                }
            }
            .font(.footnote)
            Spacer()
        }
        .padding()
    }

    private func chooseChild(_ code: String) -> some View {
        List {
            Section("Which child wears this watch?") {
                ForEach(model.children.filter { $0.ownerId == model.profile?.id }) { child in
                    Button {
                        Task { await claim(code, child) }
                    } label: {
                        HStack {
                            Text(child.nickname)
                            Spacer()
                            Text(child.ageBand).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(busy)
                }
                Button { addingChild = true } label: { Label("Add a child", systemImage: "plus") }
            }
            errorSection
        }
        .sheet(isPresented: $addingChild) {
            AddChildView { child in Task { await claim(code, child) } }
        }
    }

    private func teacherJoin(_ code: String) -> some View {
        VStack(spacing: 16) {
            if busy { ProgressView("Linking you to this student...") }
            if let result, !result.ok { Text(result.error ?? "Could not link.").foregroundStyle(.red) }
            Button("Scan again") { self.code = nil; result = nil }
        }
        .padding()
        .task(id: code) {
            busy = true
            result = await model.joinWatch(code: code)
            busy = false
        }
    }

    private func done(_ result: PairResult) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
            Text(model.profile?.isTeacher == true
                 ? "You're linked to \(result.nickname ?? "the student")."
                 : "Watch paired with \(result.nickname ?? "your child").")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            if model.profile?.isTeacher != true {
                Text("The watch keeps showing its QR for a few minutes so the teacher can scan it in their Ebb app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let child = pairedChild, model.calmProfiles[child.id] == nil {
                NavigationLink {
                    AssessmentView(child: child)
                } label: {
                    Text("Set up \(child.nickname)'s calm profile").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Later") { dismiss() }
            } else {
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    @ViewBuilder private var errorSection: some View {
        if let result, !result.ok {
            Section {
                Text(result.error ?? "Could not pair.").foregroundStyle(.red)
                Button("Scan again") { code = nil; self.result = nil }
            }
        }
    }

    private func claim(_ code: String, _ child: Child) async {
        pairedChild = child
        busy = true
        result = await model.claimWatch(code: code, child: child)
        busy = false
    }

    /// pair/start codes: 20 chars from an alphabet without 0, O, 1, I, L.
    static func looksLikeCode(_ text: String) -> Bool {
        text.range(of: "^[2-9A-HJKMNP-Z]{20}$", options: .regularExpression) != nil
    }
}

struct AddChildView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onAdded: (Child) -> Void

    @State private var nickname = ""
    @State private var ageBand = AgeBand.sixToEight
    @State private var consent = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nickname (not their full name)", text: $nickname)
                    Picker("Age", selection: $ageBand) {
                        ForEach(AgeBand.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                Section {
                    Toggle(isOn: $consent) {
                        Text("I agree that the watch records when calm mode starts and ends, what started it, and loudness and movement scores. It never records audio or location. I can delete this data at any time.")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Add a child")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            busy = true
                            if let child = await model.addChild(nickname: nickname.trimmingCharacters(in: .whitespaces), ageBand: ageBand) {
                                dismiss()
                                onAdded(child)
                            }
                            busy = false
                        }
                    }
                    .disabled(busy || !consent || nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
