import SwiftUI

/// The "ebb Desktop" welcome screen from the mockups: a sunny desktop with
/// the ebb window, a Launchpad of short info pages, and a taskbar. "Open ebb"
/// goes on to sign in (or home when already signed in).
struct DesktopView: View {
    let onOpen: () -> Void

    @State private var launchpadOpen = false
    @State private var page: DesktopPage?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                SkyAndHills()
                homeWindow
                    .padding(.horizontal, 24)
                if launchpadOpen {
                    launchpad
                        .padding(.horizontal, 12)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                if let page {
                    infoWindow(page)
                        .padding(.horizontal, 12)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
            }
            .clipped()
            taskbar
        }
        .background(Ebb.headerTop.ignoresSafeArea())
        .animation(.easeOut(duration: 0.18), value: launchpadOpen)
        .animation(.easeOut(duration: 0.18), value: page)
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            EbbOrb(size: 26)
            Text("ebb Desktop").font(.title3.weight(.semibold)).foregroundStyle(Ebb.ink)
            Spacer()
            Button(action: onOpen) {
                Image(systemName: "minus")
                    .foregroundStyle(Ebb.ink)
                    .frame(width: 40, height: 34)
                    .background(Ebb.headerGradient, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Ebb.headerBottom, lineWidth: 1))
            }
            .accessibilityLabel("Open ebb")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Ebb.headerGradient.ignoresSafeArea(edges: .top))
    }

    private var taskbar: some View {
        HStack(spacing: 10) {
            Button { page = nil; launchpadOpen.toggle() } label: {
                Label(launchpadOpen ? "Launchpad" : "Launchpad",
                      systemImage: launchpadOpen ? "xmark" : "rectangle.split.2x1")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ebb.ink)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(launchpadOpen ? AnyShapeStyle(Ebb.avatarGradient) : AnyShapeStyle(Ebb.headerGradient),
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ebb.headerBottom, lineWidth: 1))
                    .shadow(color: .black.opacity(launchpadOpen ? 0 : 0.12), radius: 2, y: 1)
            }
            .frame(width: 150)
            Button { page = nil; launchpadOpen = false } label: {
                Label("ebb Home", systemImage: "desktopcomputer")
                    .font(.subheadline)
                    .foregroundStyle(Ebb.ink)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(Ebb.headerTop, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ebb.cardBorder, lineWidth: 1))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Ebb.headerGradient.ignoresSafeArea(edges: .bottom))
    }

    // MARK: Windows

    private var homeWindow: some View {
        DesktopWindow(title: "ebb", icon: "desktopcomputer") {
            Image("EbbLogo")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0x3B5BA5), lineWidth: 1))
            Text("A quieter way to stay connected.")
                .font(.title2.weight(.bold))
                .foregroundStyle(Ebb.ink)
                .multilineTextAlignment(.center)
            Text("Early wearable concept").font(.subheadline).foregroundStyle(Ebb.inkSoft)
            openButton
        }
    }

    private var openButton: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Text("Open ebb").fontWeight(.semibold)
                Image(systemName: "arrow.up.right")
            }
        }
        .buttonStyle(.ebbPrimary)
    }

    private var launchpad: some View {
        DesktopWindow(title: "Launchpad", icon: "rectangle.split.2x1", alignment: .leading,
                      onClose: { launchpadOpen = false }) {
            openButton
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(DesktopPage.allCases) { p in
                    Button {
                        launchpadOpen = false
                        if p != .home { page = p }
                    } label: {
                        VStack(spacing: 10) {
                            GlossyTile(symbol: p.symbol, tint: p.tint)
                            Text(p.title).font(.subheadline.weight(.semibold)).foregroundStyle(Ebb.ink)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110)
                        .background(LinearGradient(colors: [.white, Ebb.headerTop], startPoint: .top, endPoint: .bottom),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ebb.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func infoWindow(_ p: DesktopPage) -> some View {
        DesktopWindow(title: p.title, icon: p.symbol, alignment: .leading, onClose: { page = nil }) {
            HStack(spacing: 12) {
                GlossyTile(symbol: p.symbol, tint: p.tint)
                Text(p.headline).font(.title3.weight(.semibold)).foregroundStyle(Ebb.ink)
            }
            ForEach(p.points, id: \.self) { point in
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Ebb.teal).frame(width: 6, height: 6).padding(.top, 8)
                    Text(point).foregroundStyle(Ebb.ink)
                }
            }
            openButton
        }
    }
}

// MARK: Pages

enum DesktopPage: String, CaseIterable, Identifiable {
    case home, watch, how, who, privacy, help
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "ebb Home"
        case .watch: "The Watch"
        case .how: "How It Works"
        case .who: "Who It's For"
        case .privacy: "Privacy & Safety"
        case .help: "Help"
        }
    }

    var symbol: String {
        switch self {
        case .home: "desktopcomputer"
        case .watch: "applewatch"
        case .how: "folder.fill"
        case .who: "person.2.fill"
        case .privacy: "checkmark.shield.fill"
        case .help: "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .home: Color(hex: 0x3D7BD9)
        case .watch: Color(hex: 0x4E8FB8)
        case .how: Color(hex: 0xE2B33C)
        case .who: Color(hex: 0x3FA45B)
        case .privacy: Color(hex: 0x2E6FC0)
        case .help: Color(hex: 0x2459B5)
        }
    }

    var headline: String {
        switch self {
        case .home: "A quieter way to stay connected."
        case .watch: "A calm corner on the wrist."
        case .how: "Start calm, breathe, check in."
        case .who: "For kids who need a calmer moment."
        case .privacy: "Only what helps, nothing more."
        case .help: "Getting set up."
        }
    }

    var points: [String] {
        switch self {
        case .home: []
        case .watch: [
            "Shows a calm scene, a breathing circle and gentle vibration.",
            "Plays short calming phrases in a calm AI voice, or a parent's own voice.",
            "Starts from the watch itself, or from a teacher or parent in this app.",
        ]
        case .how: [
            "A parent pairs the watch by scanning its QR code, then answers a short calm assessment.",
            "AI suggests a calm profile; the parent approves it before it reaches the watch.",
            "Each week the watch rotates through 6 scenes the parent approves.",
            "Teachers rate whether a calm moment helped and can add a journal note.",
        ]
        case .who: [
            "K-12 students with special needs, and the adults around them.",
            "Parents set up the watch, the profile and the voice.",
            "Teachers start calm mode in class and log what helped.",
        ]
        case .privacy: [
            "Children are known by a nickname only.",
            "The watch records when calm mode starts and ends, and what started it. Never audio.",
            "Only linked parents and teachers can see a child's moments.",
            "Parents can delete their voice and clips at any time.",
        ]
        case .help: [
            "Open ebb and create a parent or teacher account.",
            "Tap Pair watch and point the camera at the QR on the watch.",
            "Teachers scan the same QR while it is still showing to join.",
            "Keep the watch on Wi-Fi so commands reach it within a few seconds.",
        ]
        }
    }
}

// MARK: Parts

/// Window with a green title bar, used for every desktop window.
private struct DesktopWindow<Content: View>: View {
    let title: String
    let icon: String
    var alignment: HorizontalAlignment = .center
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if onClose != nil {
                    Image(systemName: icon).foregroundStyle(Ebb.ink)
                }
                Text(title).font(onClose == nil ? .subheadline.weight(.semibold) : .title3.weight(.semibold))
                    .foregroundStyle(Ebb.ink)
                Spacer()
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .foregroundStyle(Ebb.ink)
                            .frame(width: 40, height: 36)
                            .background(Ebb.card, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Ebb.cardBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                } else {
                    Image(systemName: icon).foregroundStyle(Ebb.ink)
                }
            }
            .padding(.horizontal, 14)
            .frame(minHeight: onClose == nil ? 36 : 54)
            .background(Ebb.headerGradient)

            VStack(alignment: alignment, spacing: 14) { content }
                .padding(18)
                .frame(maxWidth: .infinity)
        }
        .background(Ebb.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ebb.headerBottom, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

/// Glossy rounded icon tile in the desktop style.
private struct GlossyTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.white.opacity(0.55), .clear], startPoint: .top, endPoint: .center))
                .padding(2)
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        }
        .frame(width: 54, height: 54)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.8), lineWidth: 1))
    }
}

/// Small glossy blue orb used as the desktop's logo mark.
struct EbbOrb: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(hex: 0x8FD3F4), Color(hex: 0x1F6FB8)],
                                         center: .init(x: 0.35, y: 0.3), startRadius: 1, endRadius: size * 0.7))
            Image(systemName: "water.waves").font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(.white)
            Circle().stroke(.white.opacity(0.7), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
    }
}

/// Original drawn sky with clouds over rolling green hills.
private struct SkyAndHills: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: [Color(hex: 0x1F5FC4), Color(hex: 0x4D8FE0), Color(hex: 0x9CC6F0)],
                               startPoint: .top, endPoint: .bottom)
                cloud(w * 0.15, h * 0.28, w * 0.6)
                cloud(w * 0.85, h * 0.12, w * 0.55)
                cloud(w * 0.75, h * 0.52, w * 0.5)
                cloud(w * 0.05, h * 0.62, w * 0.45)
                Hill(peak: 0.62, rise: 0.08)
                    .fill(LinearGradient(colors: [Color(hex: 0x6FB43A), Color(hex: 0x2F7A1E)], startPoint: .top, endPoint: .bottom))
                Hill(peak: 0.3, rise: 0.04)
                    .fill(LinearGradient(colors: [Color(hex: 0x5DA52E), Color(hex: 0x23661A)], startPoint: .top, endPoint: .bottom))
                    .offset(y: h * 0.08)
            }
        }
    }

    private func cloud(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> some View {
        ZStack {
            Ellipse().frame(width: width, height: width * 0.32)
            Ellipse().frame(width: width * 0.55, height: width * 0.38).offset(x: -width * 0.12, y: -width * 0.1)
            Ellipse().frame(width: width * 0.45, height: width * 0.3).offset(x: width * 0.18, y: -width * 0.07)
        }
        .foregroundStyle(.white.opacity(0.85))
        .blur(radius: 10)
        .position(x: x, y: y)
    }

    private struct Hill: Shape {
        var peak: CGFloat   // where the crest sits, 0...1 across
        var rise: CGFloat   // how high the crest rises above the base line

        func path(in r: CGRect) -> Path {
            var p = Path()
            let base = r.height * 0.78
            p.move(to: CGPoint(x: r.minX, y: base))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: base + r.height * 0.02),
                           control: CGPoint(x: r.width * peak, y: base - r.height * rise * 2))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
            return p
        }
    }
}
