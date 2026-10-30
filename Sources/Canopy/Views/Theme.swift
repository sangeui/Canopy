import AppKit
import SwiftUI

/// 화면 전체가 같이 쓰는 색과 모양. 라이트/다크를 NSColor 동적 색으로 나눈다.
enum Theme {
    /// 사이드바와 상단 띠. 설정의 테마를 따른다.
    static var sidebar: Color { AppTheme.shared.palette.sidebarColor }
    /// 띠 안의 선택 배경. 띠가 진한 색이면 흰색을, 밝으면 검정을 살짝 얹는다.
    static var panelRaised: Color {
        switch AppTheme.shared.palette.sidebarScheme {
        case .dark: Color.white.opacity(0.2)
        case .light: Color.black.opacity(0.08)
        default: raised
        }
    }
    static var panelHover: Color {
        switch AppTheme.shared.palette.sidebarScheme {
        case .dark: Color.white.opacity(0.12)
        case .light: Color.black.opacity(0.04)
        default: hover
        }
    }
    static var panelBorder: Color {
        switch AppTheme.shared.palette.sidebarScheme {
        case .dark: Color.white.opacity(0.18)
        case .light: Color.black.opacity(0.1)
        default: border
        }
    }
    /// 본문 판. 대부분 테마는 흰색·#212121이고 Claude 테마만 크림색이다.
    static var surface: Color { AppTheme.shared.palette.surfaceColor }
    static let raised = dynamic(light: 0xEFEFEF, dark: 0x2F2F2F)
    static let hover = dynamic(light: 0xF4F4F4, dark: 0x2A2A2A)
    static let border = dynamic(light: 0xE5E5E5, dark: 0x3A3A3A)
    static let text = dynamic(light: 0x0D0D0D, dark: 0xECECEC)
    static let secondary = dynamic(light: 0x6E6E80, dark: 0x9B9B9B)
    static let tertiary = dynamic(light: 0xB4B4C0, dark: 0x6B6B6B)
    static let accent = dynamic(light: 0x0D0D0D, dark: 0xFFFFFF)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0D0D0D)
    static let codeBackground = dynamic(light: 0xF7F7F8, dark: 0x1B1B1B)
    static let addedBackground = dynamic(light: 0xE7F6F0, dark: 0x16302A)
    static let removedBackground = dynamic(light: 0xFDECEC, dark: 0x3A2222)

    /// 강조색. 설정의 테마를 따른다. 테마에 따라 빨간 계열일 수도 있어서 "더함·남음·깨끗함" 같은 뜻에는 쓰지 않는다.
    static var green: Color { AppTheme.shared.palette.tintColor }
    /// 더한 줄·새 파일·남는 것. 테마와 상관없이 늘 초록이라 빨간 "지움"과 헷갈리지 않는다.
    static let added = dynamic(light: 0x16A34A, dark: 0x22C55E)
    static let red = Color(nsColor: NSColor(hex: 0xEF4444))
    static let orange = Color(nsColor: NSColor(hex: 0xF59E0B))
    static let blue = Color(nsColor: NSColor(hex: 0x3B82F6))
    static let purple = Color(nsColor: NSColor(hex: 0xA855F7))

    static let cornerRadius: CGFloat = 10
    /// 칸·상세 전환 애니메이션 길이. git 작업은 이만큼 기다렸다가 시작한다.
    static let switchDuration: Double = 0.15
    static let switchDelayMilliseconds = 160
    /// 본문 판(가운데·오른쪽)의 모서리와 창 바탕과의 틈
    static let panelRadius: CGFloat = 10
    static let panelGap: CGFloat = 6

    /// 그래프에서 브랜치마다 돌려 쓰는 색. 0번은 현재 브랜치(테마 강조색).
    /// 나머지는 후보 중 강조색과 색조가 가까운 것을 빼고 고른다. 오베르진의 분홍 강조색 옆에 분홍 선이 서면 구분이 안 된다.
    /// 개수는 `CommitGraph.colorCount`와 같다.
    static var graphPalette: [Color] {
        let accent = AppTheme.shared.palette.tint
        // 줄마다 열마다 부르므로 테마가 바뀔 때만 다시 만든다
        if let cached = graphPaletteCache, cached.tint == accent { return cached.colors }
        let others = graphCandidates.filter { hueDistance($0, accent) > 0.07 }
        let colors = [green] + others.prefix(CommitGraph.colorCount - 1).map { Color(nsColor: NSColor(hex: $0)) }
        graphPaletteCache = (accent, colors)
        return colors
    }
    nonisolated(unsafe) private static var graphPaletteCache: (tint: UInt32, colors: [Color])?

    /// 선 색 후보. 서로 멀리 떨어진 색조부터 둔다.
    private static let graphCandidates: [UInt32] = [
        0x3B82F6, 0xF59E0B, 0xA855F7, 0x14B8A6, 0xEC4899, 0x84CC16,
        0x6366F1, 0xF97316, 0x0EA5E9, 0xA16207, 0x22C55E, 0xE11D48,
    ]

    private static func hueDistance(_ a: UInt32, _ b: UInt32) -> CGFloat {
        let ha = NSColor(hex: a).usingColorSpace(.deviceRGB)?.hueComponent ?? 0
        let hb = NSColor(hex: b).usingColorSpace(.deviceRGB)?.hueComponent ?? 0
        let d = abs(ha - hb)
        return min(d, 1 - d)
    }

    static func graphColor(_ index: Int) -> Color {
        index < 0 ? tertiary : graphPalette[index % graphPalette.count]
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: 버튼

/// 알약 모양 버튼. `prominent`면 검정 바탕에 흰 글자.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(configuration: configuration, prominent: prominent, compact: compact)
    }
}

private struct PillButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.onPanel) private var onPanel
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let compact: Bool

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, compact ? 11 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.text)
            .background(prominent ? Theme.accent : (onPanel ? Theme.panelRaised : Theme.surface), in: Capsule())
            .overlay(Capsule().stroke(prominent || onPanel ? Color.clear : Theme.border, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// 둥근 아이콘 버튼. 마우스를 올리면 회색 바탕이 생긴다.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size)
    }
}

private struct IconButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.onPanel) private var onPanel
    @State private var hovering = false
    let configuration: ButtonStyle.Configuration
    let size: CGFloat

    var body: some View {
        configuration.label
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(Theme.text)
            .frame(width: size, height: size)
            .background(hovering || configuration.isPressed ? (onPanel ? Theme.panelRaised : Theme.raised) : Color.clear, in: Circle())
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
    }
}

/// 섹션 머리말 옆에 두는 작은 글자 버튼.
struct TextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextButtonBody(configuration: configuration)
    }
}

private struct TextButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyle.Configuration

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Theme.secondary)
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
    }
}

/// 커밋 버튼. ChatGPT의 보내기 버튼처럼 검정 원에 위 화살표.
struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SendButtonBody(configuration: configuration)
    }
}

private struct SendButtonBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyle.Configuration

    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(isEnabled ? Theme.onAccent : Theme.tertiary)
            .frame(width: 32, height: 32)
            .background(isEnabled ? Theme.accent : Theme.raised, in: Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 변경 사항/히스토리 전환 탭.
struct TabButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(selected ? Theme.surface : Color.clear, in: Capsule())
            .shadow(color: selected ? Color.black.opacity(0.06) : Color.clear, radius: 1, y: 1)
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeInOut(duration: 0.18), value: selected)
    }
}

/// 둘째 줄에 쓰는 밑줄 탭. 위 줄의 알약 탭과 구분된다. 밑줄은 `UnderlineTabs`가 그린다.
struct UnderlineTabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .padding(.horizontal, 2)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeInOut(duration: 0.18), value: selected)
    }
}

/// 둘째 줄 탭을 늘어놓는 줄. 아래에 얇은 선이 있다.
struct UnderlineTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var badge: ((Tab) -> String?)?
    @Namespace private var underline

    var body: some View {
        HStack(spacing: 14) {
            ForEach(tabs) { tab in
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 5) {
                        Text(title(tab))
                        if let badge, let text = badge(tab) {
                            Text(text)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                }
                .buttonStyle(UnderlineTabStyle(selected: selection == tab))
                // 밑줄은 하나만 두고 고른 탭으로 옮겨 간다
                .overlay(alignment: .bottom) {
                    if selection == tab {
                        Capsule()
                            .fill(Theme.accent)
                            .frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: selection)
    }
}

/// 네트워크를 기다리는 동안 위에 얇게 흐르는 진행 표시.
struct ThinProgressBar: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(Theme.accent.opacity(0.6))
                .frame(width: geometry.size.width * 0.3, height: 2)
                .offset(x: phase * geometry.size.width * 1.0 - geometry.size.width * 0.3)
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.3 }
                }
        }
        .frame(height: 2)
        .clipped()
    }
}

/// 배지 대신 쓰는 "색점 + 글자". 상태를 조용히 알린다.
struct StatusText: View {
    let text: String
    let color: Color
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: size))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
        }
    }
}

/// 제목 표시줄을 숨겼으니 머리글을 두 번 누르면 시스템 설정대로 창을 키우거나 최소화한다.
struct TitleBarDoubleClick: ViewModifier {
    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                switch action {
                case "Minimize": window.miniaturize(nil)
                case "None": break
                default: window.performZoom(nil)
                }
            }
    }
}

extension View {
    func titleBarDoubleClick() -> some View { modifier(TitleBarDoubleClick()) }
}

// MARK: 목록

/// 클릭하면 선택되는 행. 선택되면 회색, 마우스를 올리면 더 옅은 회색.
/// 고를 수 있는 줄의 위아래 여백. 사이드바는 조금 넉넉하게 쓴다.
private struct RowVerticalPaddingKey: EnvironmentKey {
    static let defaultValue: CGFloat = 6
}

extension EnvironmentValues {
    var rowVerticalPadding: CGFloat {
        get { self[RowVerticalPaddingKey.self] }
        set { self[RowVerticalPaddingKey.self] = newValue }
    }
}

struct SelectableRow<Content: View>: View {
    let isSelected: Bool
    let action: () -> Void
    /// 더블 클릭. 브랜치 체크아웃처럼 "그 자리에서 바로 하는" 동작에 쓴다.
    var doubleTap: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @State private var hovering = false
    @Environment(\.onPanel) private var onPanel
    @Environment(\.rowVerticalPadding) private var verticalPadding

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? (onPanel ? Theme.panelRaised : Theme.raised) : (hovering ? (onPanel ? Theme.panelHover : Theme.hover) : Color.clear),
                in: RoundedRectangle(cornerRadius: Theme.cornerRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            // 한 번 누르면 바로 고른다. 두 번 누르기를 같은 줄에 그냥 걸면 macOS가 두 번째 클릭을 기다리느라
            // 한 번 누르기를 0.3~0.5초 늦게 전달한다. 그래서 두 번 누르기는 따로(동시에) 받는다.
            .onTapGesture(perform: action)
            .simultaneousGesture(TapGesture(count: 2).onEnded { doubleTap?() }, isEnabled: doubleTap != nil)
            // 호버 배경은 애니메이션 없이 바로 바꾼다. 애니메이션을 걸면 켜졌다 꺼지는 것처럼 보인다.
            .onHover { hovering = $0 }
    }
}

struct SectionTitle: View {
    let title: String
    var trailing: AnyView?

    init(_ title: String) {
        self.title = title
    }

    init<T: View>(_ title: String, @ViewBuilder trailing: () -> T) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer()
            trailing
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    var systemImage: String?

    var body: some View {
        VStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.tertiary)
            }
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HairlineDivider: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// `ViewThatFits`처럼 들어가는 첫 모양을 고르되, 모양이 바뀔 때 뚝 끊기지 않고 애니메이션으로 바뀐다.
/// 모양마다 원래 폭을 보이지 않게 재 두고, 받은 폭과 견줘 들어가는 첫 모양 하나만 그린다.
/// 재는 쪽도 같은 뷰를 그리므로 글 입력칸처럼 포커스를 받는 뷰는 넣지 않는다.
struct SmoothFit<Option: Hashable, Content: View>: View {
    let options: [Option]
    var animation: Animation = .easeInOut(duration: 0.2)
    /// 바뀌는 동안 잠깐 넘칠 때 어느 쪽을 붙여 둘지. 오른쪽에 버튼이 있는 줄은 `.trailing`으로 두면 버튼이 밀려나지 않는다.
    var alignment: Alignment = .leading
    @ViewBuilder let content: (Option) -> Content
    @State private var widths: [Option: CGFloat] = [:]
    @State private var available: CGFloat?
    @State private var chosen: Option?

    var body: some View {
        ZStack(alignment: .leading) {
            // 받은 폭은 내용과 상관없는 빈 칸으로 잰다. 보이는 줄로 재면 줄이 넘칠 때 넘친 폭이 잡힌다.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 0)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0; choose() }
                // 모양마다 원래 폭을 잰다. 높이 0인 칸 위에 얹어 바깥 배치에 끼어들지 않게 한다.
                .overlay(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        ForEach(options, id: \.self) { option in
                            content(option)
                                .fixedSize(horizontal: true, vertical: false)
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[option] = $0; choose() }
                        }
                    }
                    .hidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            // 바뀌는 동안 잠깐 넘쳐도 바깥에 받은 폭만큼만 차지한다고 알린다. 그래야 받은 폭을 재는 칸이 같이 커지지 않는다.
            content(chosen ?? options[0])
                .frame(minWidth: 0, maxWidth: .infinity, alignment: alignment)
        }
    }

    private func choose() {
        guard let available, widths.count == options.count else { return }
        let fitting = options.first { (widths[$0] ?? .infinity) <= available + 0.5 } ?? options[options.count - 1]
        guard fitting != chosen else { return }
        if chosen == nil {
            chosen = fitting
        } else {
            withAnimation(animation) { chosen = fitting }
        }
    }
}

/// 안쪽 뷰의 원래 폭에 `fraction`을 곱한 폭만 차지한다. `fraction`이 애니메이션되므로 폭이 부드럽게 줄고 는다.
struct RevealWidth: Layout {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(.unspecified)
        return CGSize(width: size.width * fraction, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(.unspecified)
        child.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
    }
}

extension View {
    /// 보이면 원래 폭, 아니면 폭 0. 넣고 빼는 대신 이것을 쓰면 옆 칸이 같이 미끄러져 겹쳐 보이지 않는다.
    func revealed(_ shown: Bool) -> some View {
        RevealWidth(fraction: shown ? 1 : 0) { self }
            .clipped()
            .opacity(shown ? 1 : 0)
            .allowsHitTesting(shown)
            .accessibilityHidden(!shown)
    }
}
