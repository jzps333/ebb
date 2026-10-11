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
            EbbScreen {
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
            .ebbNavigation("Pair watch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.foregroundStyle(Ebb.teal)
                }
            }
        }
    }

    @ViewBuilder private var scan: some View {
        PageTitle(text: "Bring the watch into view.",
                  subtitle: "Point the camera at the QR code on the watch.")

        ZStack {
            QRScannerView { scanned in
                if PairView.looksLikeCode(scanned) { code = scanned }
            }
            ScannerFrame()
        }
        .frame(height: 280)
        .background(Color(hex: 0x2F4636))
        .clipShape(RoundedRectangle(cornerRadius: 16))

        // For testing without a camera (e.g. a simulator): the code is the
        // 20 characters the QR holds; device-api logs it on the watch's serial.
        Text("Type the code instead").font(.title3).foregroundStyle(Ebb.ink)
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: "20-character code")
            TextField("2A3B4C5D6E7F8G9HJKMN", text: $typedCode)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .ebbField()
        }
        Button("Use") { code = typedCode.uppercased().trimmingCharacters(in: .whitespaces) }
            .buttonStyle(.ebbPrimary)
            .disabled(!PairView.looksLikeCode(typedCode.uppercased().trimmingCharacters(in: .whitespaces)))
        Footnote(text: "Codes expire after 15 minutes. Use the code currently shown on the watch.")
    }

    @ViewBuilder private func chooseChild(_ code: String) -> some View {
        PageTitle(text: "Which child wears this watch?",
                  subtitle: "Choose a child or add their nickname below.")

        let mine = model.children.filter { $0.ownerId == model.profile?.id }
        if !mine.isEmpty {
            EbbCard(title: "My children", padding: 0) {
                ForEach(mine) { child in
                    Button {
                        Task { await claim(code, child) }
                    } label: {
                        HStack(spacing: 14) {
                            Avatar(name: child.nickname)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(child.nickname).font(.title3).foregroundStyle(Ebb.ink)
                                Text("Age \(child.ageBand.replacingOccurrences(of: "-", with: "–"))")
                                    .font(.footnote).foregroundStyle(Ebb.inkSoft)
                            }
                            Spacer()
                            if busy && pairedChild?.id == child.id { ProgressView() }
                            else { Image(systemName: "chevron.right").foregroundStyle(Ebb.teal) }
                        }
                        .padding(16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    if child.id != mine.last?.id { Divider().overlay(Ebb.cardBorder) }
                }
            }
        }

        Button { addingChild = true } label: {
            HStack {
                Image(systemName: "plus")
                Spacer()
                Text("Add a child")
                Spacer()
                Image(systemName: "plus").hidden()
            }
            .padding(.horizontal, 18)
        }
        .buttonStyle(.ebbSecondary)

        if let result, !result.ok {
            ErrorCard(title: "Pairing failure", headline: "Could not pair.", message: result.error ?? "Please try again.", retryTitle: "Scan again") { self.code = nil; self.result = nil }
        }

        Color.clear.frame(height: 0)
            .sheet(isPresented: $addingChild) {
                AddChildView { child in Task { await claim(code, child) } }
            }
    }

    @ViewBuilder private func teacherJoin(_ code: String) -> some View {
        PageTitle(text: "Linking you to this student.")
        if busy {
            EbbCard(title: "Teacher linking") {
                ProgressView().tint(Ebb.teal)
                Text("Linking you to this student...").foregroundStyle(Ebb.ink)
            }
        }
        if let result, !result.ok {
            ErrorCard(title: "Teacher linking failure", headline: "Could not link.", message: result.error ?? "Please try again.", retryTitle: "Scan again") { self.code = nil; self.result = nil }
        }
        Color.clear.frame(height: 0)
            .task(id: code) {
                busy = true
                result = await model.joinWatch(code: code)
                busy = false
            }
    }

    @ViewBuilder private func done(_ result: PairResult) -> some View {
        Image(systemName: "checkmark")
            .font(.system(size: 40, weight: .light))
            .foregroundStyle(Ebb.teal)
            .frame(width: 104, height: 104)
            .background(Ebb.previewBlue, in: Circle())
            .overlay(Circle().stroke(Ebb.cardBorder, lineWidth: 1))
            .frame(maxWidth: .infinity)
            .padding(.top, 24)

        PageTitle(text: model.profile?.isTeacher == true
                  ? "You're linked to \(result.nickname ?? "the student")."
                  : "Watch paired with \(result.nickname ?? "your child").")

        if model.profile?.isTeacher != true {
            EbbCard(title: "A teacher can join, too") {
                Text("The watch keeps showing its QR for a few minutes so the teacher can scan it in their Ebb app.")
                    .foregroundStyle(Ebb.ink)
            }
        }
        if let child = pairedChild, model.calmProfiles[child.id] == nil {
            NavigationLink {
                AssessmentView(child: child)
            } label: {
                Text("Set up \(child.nickname)'s calm profile")
            }
            .buttonStyle(.ebbPrimary)
            Button("Later") { dismiss() }.buttonStyle(.ebbSecondary)
        } else {
            Button("Done") { dismiss() }.buttonStyle(.ebbPrimary)
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
            EbbScreen {
                PageTitle(text: "A nickname is enough.")
                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Nickname (not their full name)")
                    TextField("Nickname", text: $nickname).ebbField()
                }
                Text("Age").foregroundStyle(Ebb.ink)
                FlowLayout {
                    ForEach(AgeBand.allCases) { band in
                        CheckChip(title: band.rawValue, isOn: ageBand == band) { ageBand = band }
                    }
                }
                Button { consent.toggle() } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: consent ? "checkmark.square.fill" : "square")
                            .font(.title2)
                            .foregroundStyle(consent ? Ebb.selectedEdge : Ebb.inkSoft)
                        Text("I agree that the watch records when calm mode starts and ends, what started it, and loudness and movement scores. It never records audio or location. I can delete this data at any time.")
                            .font(.subheadline)
                            .foregroundStyle(Ebb.ink)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(consent ? Ebb.selected : Ebb.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(consent ? Ebb.selectedEdge : Ebb.cardBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(busy ? "Adding..." : "Add") {
                    Task {
                        busy = true
                        if let child = await model.addChild(nickname: nickname.trimmingCharacters(in: .whitespaces), ageBand: ageBand) {
                            dismiss()
                            onAdded(child)
                        }
                        busy = false
                    }
                }
                .buttonStyle(.ebbPrimary)
                .disabled(busy || !consent || nickname.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { dismiss() }.buttonStyle(.ebbSecondary)
            }
            .ebbNavigation("Add a child")
        }
    }
}

/// Corner brackets and a rounded target over the camera.
private struct ScannerFrame: View {
    var body: some View {
        let line = Color(hex: 0xE4F0C8)
        ZStack {
            RoundedRectangle(cornerRadius: 14).stroke(line, lineWidth: 1.5).padding(54)
            Corners().stroke(line, style: StrokeStyle(lineWidth: 3, lineCap: .round)).padding(40)
            VStack(spacing: 10) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 30, weight: .light))
                Text("Looking for a code...").font(.footnote)
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .allowsHitTesting(false)
    }

    private struct Corners: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path(); let l: CGFloat = 40
            for (x, y, dx, dy) in [(r.minX, r.minY, 1.0, 1.0), (r.maxX, r.minY, -1.0, 1.0),
                                   (r.minX, r.maxY, 1.0, -1.0), (r.maxX, r.maxY, -1.0, -1.0)] {
                p.move(to: CGPoint(x: x, y: y + dy * l)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + dx * l, y: y))
            }
            return p
        }
    }
}
