import ImageIO
import SwiftUI
import UIKit

/// This week's 6 calm scenes for a child. The watch plays the next one each
/// calm session. Anchors (from the calm profile and what helped most) stay
/// every week; the rest rotate based on "Did it help?".
struct ScenesView: View {
    @Environment(AppModel.self) private var model
    let child: Child

    @State private var set: SceneSet?
    @State private var loading = true
    @State private var busy = false
    @State private var swapping: SceneSetItem?

    private var isParent: Bool { model.profile?.isTeacher != true }

    var body: some View {
        EbbScreen {
            if loading {
                ProgressView().tint(Ebb.teal).frame(maxWidth: .infinity).padding(.top, 40)
            } else if let set {
                HStack {
                    StatusChip(text: set.isApproved ? "Approved · On the watch" : "Draft · Review before sending")
                    Spacer()
                }
                PageTitle(text: "Week of \(Self.weekLabel(set.weekStart))",
                          subtitle: "The watch plays the next scene each time calm mode starts.")

                EbbCard(title: "This week's scenes", padding: 0) {
                    ForEach(set.items, id: \.position) { item in
                        sceneRow(item).padding(14)
                        if item.position != set.items.last?.position { Divider().overlay(Ebb.cardBorder) }
                    }
                }
                Footnote(text: "★ scenes stay every week; the others change based on the teacher's \"Did it help?\" ratings.")

                if isParent {
                    if set.isApproved {
                        InsetPanel {
                            Label("Approved. The watch has these within a few minutes.", systemImage: "checkmark.seal")
                                .foregroundStyle(Ebb.teal)
                        }
                        Button("Plan next week") { Task { await make() } }.buttonStyle(.ebbSecondary)
                    } else {
                        Button(busy ? "Approving..." : "Approve these scenes") {
                            Task {
                                busy = true
                                await model.approve(set)
                                await reload()
                                busy = false
                            }
                        }
                        .buttonStyle(.ebbPrimary)
                        Button("Pick again") { Task { await make() } }.buttonStyle(.ebbSecondary)
                    }
                }
            } else {
                PageTitle(text: "This week's scenes")
                EbbCard(title: "Getting started") {
                    Text(isParent ? "No scenes yet." : "The parent hasn't picked scenes yet.").foregroundStyle(Ebb.ink)
                    if isParent {
                        Button("Pick this week's scenes") { Task { await make() } }.buttonStyle(.ebbPrimary)
                    }
                }
            }
        }
        .ebbNavigation("\(child.nickname)'s scenes")
        .disabled(busy)
        .task {
            await model.loadSceneLibrary()
            await reload()
            if set == nil && isParent { await make() }  // first visit: suggest a set right away
        }
        .sheet(item: $swapping) { item in
            NavigationStack {
                EbbScreen {
                    PageTitle(text: "Swap scene \(item.position)")
                    ForEach(model.sceneLibrary) { scene in
                        Button {
                            Task {
                                if let set { await model.swap(set, position: item.position, to: scene) }
                                swapping = nil
                                await reload()
                            }
                        } label: {
                            HStack(spacing: 12) {
                                AnimatedGIF(url: scene.previewURL).frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(scene.title).foregroundStyle(Ebb.ink)
                                    Text(Self.soundLabel(scene.sound)).font(.caption).foregroundStyle(Ebb.inkSoft)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Ebb.teal)
                            }
                            .padding(12)
                            .background(Ebb.card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ebb.cardBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .ebbNavigation("Swap scene")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { swapping = nil } } }
            }
        }
    }

    private func sceneRow(_ item: SceneSetItem) -> some View {
        let scene = model.sceneLibrary.first { $0.id == item.sceneId }
        return HStack(spacing: 12) {
            if let scene {
                AnimatedGIF(url: scene.previewURL).frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(item.position). \(scene?.title ?? item.sceneId)\(item.isAnchor ? "  ★" : "")").foregroundStyle(Ebb.ink)
                Text(Self.soundLabel(scene?.sound ?? "none")).font(.caption).foregroundStyle(Ebb.inkSoft)
            }
            Spacer()
            if isParent && set?.isApproved != true {
                Button("Swap") { swapping = item }
                    .font(.subheadline)
                    .foregroundStyle(Ebb.teal)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Ebb.card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ebb.cardBorder, lineWidth: 1))
                    .buttonStyle(.plain)
            }
        }
    }

    private func reload() async {
        set = await model.sceneSet(for: child)
        loading = false
    }

    private func make() async {
        busy = true
        set = await model.makeSceneSet(for: child)
        loading = false
        busy = false
    }

    static func soundLabel(_ sound: String) -> String {
        switch sound {
        case "none": return "No sound"
        case "soft_piano": return "Soft piano"
        case "brown_noise": return "Quiet hum (brown noise)"
        default: return sound.prefix(1).uppercased() + sound.dropFirst()
        }
    }

    static func weekLabel(_ isoDate: String) -> String {
        let parse = DateFormatter()
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: isoDate) else { return isoDate }
        let show = DateFormatter()
        show.dateFormat = "MMM d"
        return show.string(from: d)
    }
}

extension SceneSetItem: Identifiable {
    var id: Int { position }
}

/// Plays a GIF (the same loop the watch shows). SwiftUI's AsyncImage only shows
/// the first frame, so this decodes every frame with ImageIO.
struct AnimatedGIF: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = UIColor(red: 0.86, green: 0.92, blue: 0.95, alpha: 1)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        load(into: view)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {}

    private func load(into view: UIImageView) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return }
            var frames: [UIImage] = []
            var duration = 0.0
            for i in 0 ..< CGImageSourceGetCount(source) {
                guard let cg = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                frames.append(UIImage(cgImage: cg))
                let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
                let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                duration += (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            }
            let image = UIImage.animatedImage(with: frames, duration: duration)
            DispatchQueue.main.async { view.image = image }
        }.resume()
    }
}
