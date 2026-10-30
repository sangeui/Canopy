import AppKit
import SwiftUI

/// 세 칸 분할. HSplitView는 칸을 넣고 뺄 때 폭이 한 번에 바뀌어 튀므로, 폭을 상태로 들고 직접 그린다.
/// 접을 때는 폭이 연속으로 줄어들고, 구분선은 끌어서 조절한다.
struct SplitLayout<Sidebar: View, Content: View, Detail: View>: View {
    let showsSidebar: Bool
    let showsDetail: Bool
    /// 오른쪽 칸이 가운데 칸 자리까지 차지한다
    var expandsDetail = false
    /// 사이드바를 접어도 남는 왼쪽 아이콘 줄의 폭. 펼치면 그 오른쪽에 목록 칸(`sidebarWidth`)이 붙는다.
    let collapsedSidebarWidth: CGFloat
    @ViewBuilder let sidebar: () -> Sidebar
    @ViewBuilder let content: () -> Content
    @ViewBuilder let detail: () -> Detail

    /// 목록 칸의 폭. 아이콘 줄은 뺀 값이다.
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 260
    @AppStorage("detailWidth") private var detailWidth: Double = 480
    @State private var dragStartSidebar: Double?
    @State private var dragStartDetail: Double?

    private let sidebarRange: ClosedRange<Double> = 200...380
    private let detailMin: Double = 360
    private let contentMin: Double = 560

    var body: some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            let expandedSidebar = Double(collapsedSidebarWidth) + sidebarWidth
            let leftWidth = showsSidebar ? expandedSidebar : Double(collapsedSidebarWidth)
            let rightMax = max(detailMin, total - leftWidth - contentMin)
            let normalRight = showsDetail ? min(max(detailWidth, detailMin), rightMax) : 0
            let expanded = showsDetail && expandsDetail
            let rightWidth = expanded ? max(detailMin, total - leftWidth - SplitHandle.width * 2) : normalRight
            // 창이 좁으면 contentMin보다 작아질 수 있다. 바깥 칸은 남는 폭에 맞추고 넘치는 만큼만 잘라 낸다.
            // 넓게 보기에서는 안쪽을 원래 폭으로 그리고 바깥만 접어서, 돌아올 때 다시 배치하지 않는다.
            let normalContent = max(0, total - leftWidth - normalRight - SplitHandle.width * 2)
            let contentWidth = max(0, total - leftWidth - rightWidth - SplitHandle.width * 2)
            HStack(spacing: 0) {
                // 안쪽은 펼친 폭으로 그리고 바깥만 줄인다. 접히는 동안 글이 다시 줄바꿈되지 않는다.
                sidebar()
                    .frame(width: expandedSidebar, alignment: .leading)
                    .frame(width: leftWidth, alignment: .leading)
                    .clipped()
                SplitHandle(enabled: showsSidebar) { translation in
                    if dragStartSidebar == nil { dragStartSidebar = sidebarWidth }
                    sidebarWidth = min(max((dragStartSidebar ?? sidebarWidth) + translation, sidebarRange.lowerBound), sidebarRange.upperBound)
                } onEnd: {
                    dragStartSidebar = nil
                }
                content()
                    // 패널을 여닫을 때는 가운데 칸도 같이 줄고 늘어난다. 처음부터 최종 폭으로 그리면 오른쪽 끝의 버튼과 글이
                    // 먼저 제자리로 튀고 그 옆에 빈 틈이 생겼다가 패널이 채워서, 움직이는 방향이 거꾸로 보였다.
                    .frame(width: normalContent, alignment: .leading)
                    .frame(width: contentWidth, alignment: .leading)
                    .clipped()
                SplitHandle(enabled: showsDetail && !expanded) { translation in
                    if dragStartDetail == nil { dragStartDetail = detailWidth }
                    detailWidth = min(max((dragStartDetail ?? detailWidth) - translation, detailMin), rightMax)
                } onEnd: {
                    dragStartDetail = nil
                }
                // 오른쪽 패널은 오른쪽 끝에 붙여 둔다. 접으면 창 오른쪽 가장자리로 밀려 나가고, 펴면 거기서 들어온다.
                // 왼쪽에 붙이면 사이드바처럼 오른쪽부터 잘려 들어가 같은 방향으로 움직이는 것처럼 보인다.
                detail()
                    .frame(width: expanded ? rightWidth : min(max(detailWidth, detailMin), rightMax), alignment: .leading)
                    .frame(width: rightWidth, alignment: .trailing)
                    .clipped()
            }
            .background(Theme.sidebar)
            .animation(.easeOut(duration: 0.14), value: showsSidebar)
            .animation(.easeOut(duration: 0.14), value: showsDetail)
            .animation(.easeOut(duration: 0.16), value: expandsDetail)
        }
    }
}

/// 끌어서 폭을 바꾸는 틈. 선 대신 창 바탕색이 보이는 좁은 틈이고, 잡는 영역은 조금 더 넓다.
private struct SplitHandle: View {
    static let width: CGFloat = 6
    let enabled: Bool
    let onDrag: (Double) -> Void
    let onEnd: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Theme.sidebar).frame(width: Self.width)
            Color.clear.frame(width: 10)
                .contentShape(Rectangle())
                .onHover { inside in
                    hovering = inside
                    if enabled {
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in if enabled { onDrag(value.translation.width) } }
                        .onEnded { _ in onEnd() }
                )
        }
        .frame(width: Self.width)
    }
}
