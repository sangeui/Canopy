import AppKit
import SwiftUI

/// 설정에서 고르는 테마. 슬랙 테마처럼 사이드바와 상단 띠의 색, 강조색을 바꾼다. 본문은 그대로 밝거나 어둡다.
struct ThemePalette: Identifiable, Hashable {
    let id: String
    let name: String
    /// 사이드바·상단 띠 색. 라이트 모드, 다크 모드
    let sidebarLight: UInt32
    let sidebarDark: UInt32
    /// 사이드바 글자를 밝게(.dark) 또는 어둡게(.light) 고정한다. nil이면 시스템 모드를 따른다.
    let sidebarScheme: ColorScheme?
    /// 현재 브랜치, 그래프 첫 선, 아이콘에 쓰는 강조색
    let tint: UInt32
    /// 본문 판 색. 라이트 모드, 다크 모드. 대부분 테마는 흰색·#212121 그대로이고, Claude처럼 바탕까지 물든 앱의 테마만 바꾼다.
    var surfaceLight: UInt32 = 0xFFFFFF
    var surfaceDark: UInt32 = 0x212121

    var sidebarColor: Color { Theme.dynamic(light: sidebarLight, dark: sidebarDark) }
    var surfaceColor: Color { Theme.dynamic(light: surfaceLight, dark: surfaceDark) }
    var tintColor: Color { Color(nsColor: NSColor(hex: tint)) }

    static let all: [ThemePalette] = [
        ThemePalette(id: "canopy", name: "캐노피", sidebarLight: 0xF9F9F9, sidebarDark: 0x171717, sidebarScheme: nil, tint: 0x10A37F),
        // ChatGPT 앱의 색 값(gray-50·gray-900 사이드바, blue-400 강조색). 바탕은 캐노피와 같은 흰색·#212121이다.
        ThemePalette(id: "chatgpt", name: "ChatGPT", sidebarLight: 0xF9F9F9, sidebarDark: 0x181818, sidebarScheme: nil, tint: 0x0285FF),
        // Claude 앱의 색 값(bg-200 사이드바, bg-100 바탕, 브랜드 클레이 강조색)
        ThemePalette(id: "claude", name: "Claude", sidebarLight: 0xF5F4ED, sidebarDark: 0x1F1E1D, sidebarScheme: nil, tint: 0xD97757,
                     surfaceLight: 0xFAF9F5, surfaceDark: 0x262624),
        ThemePalette(id: "aubergine", name: "오베르진", sidebarLight: 0x3F0E40, sidebarDark: 0x3F0E40, sidebarScheme: .dark, tint: 0xE01E5A),
        ThemePalette(id: "ocean", name: "오션", sidebarLight: 0x0B2545, sidebarDark: 0x0B2545, sidebarScheme: .dark, tint: 0x38BDF8),
        ThemePalette(id: "forest", name: "숲", sidebarLight: 0x163A2B, sidebarDark: 0x163A2B, sidebarScheme: .dark, tint: 0x34D399),
        ThemePalette(id: "graphite", name: "그래파이트", sidebarLight: 0x1F1F23, sidebarDark: 0x1F1F23, sidebarScheme: .dark, tint: 0xF59E0B),
        ThemePalette(id: "mocha", name: "모카", sidebarLight: 0x3B2A24, sidebarDark: 0x3B2A24, sidebarScheme: .dark, tint: 0xF4A261),
        ThemePalette(id: "lavender", name: "라벤더", sidebarLight: 0xEDE9FE, sidebarDark: 0x2E1065, sidebarScheme: nil, tint: 0x7C3AED),
        ThemePalette(id: "sand", name: "모래", sidebarLight: 0xF5EFE6, sidebarDark: 0x2A241C, sidebarScheme: nil, tint: 0xC2410C),
    ]

    static let standard = all[0]
}

/// 창 전체를 밝게, 어둡게, 시스템대로
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "시스템"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// 지금 고른 테마와 화면 모드. 화면은 `Theme`의 색을 읽을 때 이 객체를 거치므로 바꾸면 바로 따라온다.
@Observable
final class AppTheme: @unchecked Sendable {
    static let shared = AppTheme()

    var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            Task { @MainActor in self.applyAppearance() }
        }
    }

    var paletteID: String {
        didSet { UserDefaults.standard.set(paletteID, forKey: "themePalette") }
    }

    var palette: ThemePalette {
        ThemePalette.all.first { $0.id == paletteID } ?? .standard
    }

    private init() {
        appearance = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
        paletteID = UserDefaults.standard.string(forKey: "themePalette") ?? ThemePalette.standard.id
    }

    @MainActor
    func applyAppearance() {
        NSApp.appearance = appearance.appearance
    }
}

/// 사이드바·상단 띠 안인지. 그 안에서는 선택·호버 배경을 띠 색 위에 얹는 반투명으로 그린다.
private struct OnPanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var onPanel: Bool {
        get { self[OnPanelKey.self] }
        set { self[OnPanelKey.self] = newValue }
    }
}

/// 사이드바와 상단 띠에 테마를 입힌다. 글자색 모드를 고정하고, 띠 안이라는 표시를 환경에 남긴다.
struct PanelStyle: ViewModifier {
    func body(content: Content) -> some View {
        let scheme = AppTheme.shared.palette.sidebarScheme
        content
            .environment(\.onPanel, true)
            .transformEnvironment(\.colorScheme) { current in
                if let scheme { current = scheme }
            }
    }
}

extension View {
    func panelStyle() -> some View { modifier(PanelStyle()) }
}
