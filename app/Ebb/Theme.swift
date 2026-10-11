import SwiftUI

/// Ebb's design system, from the team's mockups (docs: "hacknc app ui"):
/// cream background, cards with a soft green title bar, glossy teal primary
/// buttons, cream outlined secondary buttons, pale blue chips.
enum Ebb {
    static let background   = Color(hex: 0xEFF2E5)
    static let card         = Color(hex: 0xFAFAF2)
    static let cardBorder   = Color(hex: 0xC9CFB9)
    static let panel        = Color(hex: 0xEBEEE2)   // inset panel inside cards
    static let headerTop    = Color(hex: 0xF0F6DD)
    static let headerBottom = Color(hex: 0xABBF8D)
    static let ink          = Color(hex: 0x2B3A2C)   // titles and body text
    static let inkSoft      = Color(hex: 0x6B7366)   // secondary text
    static let teal         = Color(hex: 0x21657A)   // links, accents
    static let tealTop      = Color(hex: 0x52A0B3)
    static let tealBottom   = Color(hex: 0x194C60)
    static let chip         = Color(hex: 0xE1F0F2)
    static let chipText     = Color(hex: 0x24596B)
    static let selected     = Color(hex: 0xDCEDF2)
    static let selectedEdge = Color(hex: 0x3B7C8E)
    static let disabled     = Color(hex: 0xDFE3D6)
    static let disabledText = Color(hex: 0x8C9486)
    static let previewBlue  = Color(hex: 0xDCEBF1)

    static let headerGradient = LinearGradient(colors: [headerTop, headerBottom], startPoint: .top, endPoint: .bottom)
    static let tealGradient = LinearGradient(colors: [tealTop, teal, tealBottom], startPoint: .top, endPoint: .bottom)
    static let avatarGradient = LinearGradient(colors: [headerTop, Color(hex: 0xB1C493)], startPoint: .top, endPoint: .bottom)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Screen and navigation

/// Cream page with the content in a padded scroll view.
struct EbbScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ebb.background.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }
}

extension View {
    /// The green gradient navigation bar with a bold inline title.
    func ebbNavigation(_ title: String) -> some View {
        self
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .tint(Ebb.teal)
    }
}

/// Big light page heading ("My children", "A nickname is enough.").
struct PageTitle: View {
    let text: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.system(size: 30, weight: .regular)).foregroundStyle(Ebb.ink)
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(Ebb.inkSoft) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Cards

/// White-cream card; with a title it gets the green gradient title bar.
struct EbbCard<Content: View>: View {
    var title: String?
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Ebb.ink)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    .background(Ebb.headerGradient)
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ebb.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Ebb.cardBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
    }
}

/// Slightly darker inset panel inside a card (today's summary).
struct InsetPanel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ebb.panel, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: Buttons

/// Glossy teal button with white text.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(enabled ? .white : Ebb.disabledText)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(enabled ? AnyShapeStyle(Ebb.tealGradient) : AnyShapeStyle(Ebb.disabled))
            }
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(enabled ? Ebb.tealBottom : Ebb.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(enabled ? 0.15 : 0), radius: 3, y: 2)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Cream outlined button with teal text.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(enabled ? Ebb.teal : Ebb.disabledText)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(enabled ? Ebb.card : Ebb.disabled, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ebb.cardBorder, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle { static var ebbPrimary: PrimaryButtonStyle { .init() } }
extension ButtonStyle where Self == SecondaryButtonStyle { static var ebbSecondary: SecondaryButtonStyle { .init() } }

// MARK: Small parts

/// Pale blue pill with a dot ("Watch online", "Draft · Review before sending").
struct StatusChip: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Circle().frame(width: 5, height: 5)
            Text(text).font(.footnote.weight(.semibold))
        }
        .foregroundStyle(Ebb.chipText)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Ebb.chip, in: Capsule())
    }
}

/// Rounded-square initial in the green gradient ("S").
struct Avatar: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 26, weight: .medium))
            .foregroundStyle(Ebb.chipText)
            .frame(width: 56, height: 56)
            .background(Ebb.avatarGradient, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ebb.cardBorder, lineWidth: 1))
    }
}

/// Teal text row with a chevron, for navigation inside cards.
struct LinkRow<Destination: View>: View {
    let title: String
    var systemImage: String = "chevron.right"
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink { destination } label: {
            HStack {
                Text(title).foregroundStyle(Ebb.teal)
                Spacer()
                Image(systemName: systemImage).foregroundStyle(Ebb.teal)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Bold field label above a text field.
struct FieldLabel: View {
    let text: String
    var body: some View { Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Ebb.ink) }
}

/// White rounded text field.
struct EbbFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ebb.cardBorder, lineWidth: 1))
            .foregroundStyle(Ebb.ink)
    }
}

extension View {
    func ebbField() -> some View { modifier(EbbFieldStyle()) }
}

/// Checkbox chip for multiple choice (Loud places, Transitions, ...).
struct CheckChip: View {
    let title: String
    let isOn: Bool
    var swatch: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let swatch {
                    Circle().fill(swatch).frame(width: 16, height: 16)
                } else {
                    Image(systemName: isOn ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isOn ? Ebb.selectedEdge : Ebb.cardBorder)
                }
                Text(title).font(.subheadline.weight(isOn ? .semibold : .regular))
            }
            .foregroundStyle(isOn ? Ebb.chipText : Ebb.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(isOn ? Ebb.selected : Ebb.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isOn ? Ebb.selectedEdge : Ebb.cardBorder, lineWidth: isOn ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }
}

/// Equal-width single choice (Very / A little / No).
struct SegmentChoice: View {
    let options: [(String, String)]   // (value, label)
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options, id: \.0) { value, label in
                let on = selection == value
                Button { selection = value } label: {
                    Text(label)
                        .font(.subheadline.weight(on ? .semibold : .regular))
                        .foregroundStyle(on ? Ebb.chipText : Ebb.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(on ? Ebb.selected : Ebb.card, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Ebb.selectedEdge : Ebb.cardBorder, lineWidth: on ? 1.5 : 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

/// Small grey footnote under a section.
struct Footnote: View {
    let text: String
    var body: some View { Text(text).font(.footnote).foregroundStyle(Ebb.inkSoft).frame(maxWidth: .infinity, alignment: .leading) }
}

/// Problem card from "Supporting states": headline, detail, primary retry.
struct ErrorCard: View {
    var title = "Something went wrong"
    var headline: String?
    let message: String
    var retryTitle = "Try again"
    var retry: (() -> Void)?

    var body: some View {
        EbbCard(title: title) {
            if let headline { Text(headline).font(.title3).foregroundStyle(Ebb.ink) }
            Text(message).foregroundStyle(headline == nil ? Ebb.ink : Ebb.inkSoft)
            if let retry { Button(retryTitle, action: retry).buttonStyle(.ebbPrimary) }
        }
    }
}

/// SwiftUI draws a gradient toolbar background as one flat colour, so the
/// green bar is set once through UIKit (call from the app's init).
enum EbbAppearance {
    static func apply() {
        let size = CGSize(width: 1, height: 120)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(Ebb.headerTop).cgColor, UIColor(Ebb.headerBottom).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundImage = image.resizableImage(withCapInsets: .zero, resizingMode: .stretch)
        bar.shadowColor = UIColor(Ebb.cardBorder)
        bar.titleTextAttributes = [.foregroundColor: UIColor(Ebb.ink), .font: UIFont.systemFont(ofSize: 17, weight: .bold)]
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
    }
}
