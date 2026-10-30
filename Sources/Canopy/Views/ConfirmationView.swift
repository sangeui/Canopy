import SwiftUI

/// 확인 창. 시스템 알림 창은 본문을 모두 같은 글꼴로 그려서 대상과 결과가 뒤섞였다.
/// 제목 · 대상 · 결과 · 버튼을 칸으로 나눠 그린다.
struct ConfirmationOverlay: View {
    @Environment(RepositoryStore.self) private var store
    let confirmation: RepositoryStore.Confirmation
    /// 선택(`choice`)을 켰는지
    @State private var choiceOn = false

    private var facts: [RepositoryStore.Confirmation.Fact] {
        choiceOn ? confirmation.choice?.facts ?? confirmation.facts : confirmation.facts
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { store.confirmation = nil }
            card
                .frame(width: width)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        }
    }

    /// 대상 이름이 한 줄에 다 들어가도록 창을 넓힌다. 고정폭 13pt 글자 하나는 약 7.9pt.
    private var width: CGFloat {
        let chars = CGFloat(confirmation.target?.count ?? 0)
        return min(640, max(440, chars * 7.9 + 72))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 제목: 동작만
            Text(confirmation.title)
                .font(.system(size: 16, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, confirmation.target == nil ? 14 : 12)

            // 대상: 줄이지 않는다. 길면 옆으로 민다.
            if let target = confirmation.target {
                VStack(alignment: .leading, spacing: 4) {
                    // 아주 긴 이름만 옆으로 민다. 처음에는 앞부분이 보이게 둔다.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(target)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .fixedSize()
                            .textSelection(.enabled)
                    }
                    .defaultScrollAnchor(.leading)
                    if let detail = confirmation.targetDetail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 14)
            }

            // 결과: 한 줄에 하나
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                        FactRow(fact: fact)
                    }
                }
                .padding(.bottom, 18)
                .animation(.easeInOut(duration: 0.15), value: choiceOn)
            }

            // 선택: 켜면 위 결과 줄과 버튼이 바뀐다
            if let choice = confirmation.choice {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(choice.title)
                            .font(.system(size: 13, weight: .medium))
                        if let detail = choice.detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: $choiceOn)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                        .tint(Theme.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Theme.codeBackground, in: RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 18)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("취소") { store.confirmation = nil }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                confirmButton
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var confirmButton: some View {
        let button = Button(choiceOn ? confirmation.choice?.buttonTitle ?? confirmation.buttonTitle : confirmation.buttonTitle) { run() }
        if confirmation.tone == .destructive {
            // 되돌리기 어려운 동작은 엔터로 실수하지 않게 기본 버튼으로 두지 않는다.
            button.buttonStyle(DestructiveButtonStyle())
        } else {
            button
                .buttonStyle(PillButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
        }
    }

    private func run() {
        let action = choiceOn ? confirmation.choice?.action ?? confirmation.action : confirmation.action
        store.confirmation = nil
        Task { await action() }
    }
}

private struct FactRow: View {
    let fact: RepositoryStore.Confirmation.Fact

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch fact.kind {
            case .item:
                Color.clear.frame(width: 14, height: 1)
                Text(fact.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            default:
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 14)
                Text(fact.text)
                    .font(.system(size: 13))
                    .foregroundStyle(fact.kind == .note ? Theme.secondary : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var symbol: String {
        switch fact.kind {
        case .keeps: "checkmark.circle.fill"
        case .loses, .warns: "exclamationmark.triangle.fill"
        case .note, .item: "info.circle"
        }
    }

    private var color: Color {
        switch fact.kind {
        case .keeps: Theme.added
        case .loses, .warns: Theme.orange
        case .note, .item: Theme.tertiary
        }
    }
}

/// 되돌리기 어려운 동작의 버튼. 빨간 바탕.
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(.white)
            .background(Theme.red.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
    }
}
