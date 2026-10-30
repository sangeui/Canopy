import SwiftUI

/// 앱 아이콘의 잎을 한 가지 색으로 그린 로고. 잎맥(브랜치)과 마디(커밋)는 비워서 바탕이 비친다.
/// 색은 테마 강조색을 따른다. 좌표는 아이콘을 그린 1024 판(위가 0)에서 잎 둘레만 잘라 온 것이다.
struct CanopyLogo: View {
    var size: CGFloat = 18
    var color: Color = Theme.green

    var body: some View {
        Canvas { context, canvas in
            // 잎이 든 600×600 칸을 그릴 크기에 맞춘다
            let scale = canvas.width / 600
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - 220) * scale, y: (y - 214) * scale) }

            // 양 끝은 둥글게: 끝 가까이에서 곡선을 잘라 내고 끝점을 조절점으로 잇는다(scripts/make-app-icon.swift와 같은 모양)
            let base = CGPoint(x: 300, y: 774), top = CGPoint(x: 740, y: 234)
            let left = CGPoint(x: 230, y: 264), right = CGPoint(x: 810, y: 744)
            let tip: CGFloat = 0.045
            func on(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
                p((1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * c.x + t * t * b.x, (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * c.y + t * t * b.y)
            }
            func between(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint) -> CGPoint {
                let wa = (1 - tip) * tip, wc = tip * tip + (1 - tip) * (1 - tip), wb = tip * (1 - tip)
                return p(wa * a.x + wc * c.x + wb * b.x, wa * a.y + wc * c.y + wb * b.y)
            }
            var leaf = Path()
            leaf.move(to: on(base, left, top, tip))
            leaf.addQuadCurve(to: on(base, left, top, 1 - tip), control: between(base, left, top))
            leaf.addQuadCurve(to: on(top, right, base, tip), control: p(top.x, top.y))
            leaf.addQuadCurve(to: on(top, right, base, 1 - tip), control: between(top, right, base))
            leaf.addQuadCurve(to: on(base, left, top, tip), control: p(base.x, base.y))
            leaf.closeSubpath()
            context.fill(leaf, with: .color(color))

            // 잎맥과 마디를 지운다
            context.blendMode = .destinationOut
            let line = StrokeStyle(lineWidth: 26 * scale, lineCap: .round, lineJoin: .round)
            var spine = Path()
            spine.move(to: p(330, 739))
            spine.addQuadCurve(to: p(705, 269), control: p(520, 554))
            context.stroke(spine, with: .color(.black), style: line)
            let branches: [(CGPoint, CGPoint, CGPoint)] = [
                (p(430, 619), p(450, 464), p(395, 384)),
                (p(520, 524), p(660, 504), p(700, 584)),
                (p(600, 414), p(600, 304), p(540, 264)),
            ]
            for (from, control, to) in branches {
                var vein = Path()
                vein.move(to: from)
                vein.addQuadCurve(to: to, control: control)
                context.stroke(vein, with: .color(.black), style: StrokeStyle(lineWidth: 20 * scale, lineCap: .round))
            }
            for (x, y) in [(430, 619), (520, 524), (600, 414), (395, 384), (700, 584), (540, 264)] as [(CGFloat, CGFloat)] {
                // 마디는 작게. 크면 17pt에서 잎이 구멍투성이로 보인다.
                let r = 22 * scale
                let c = p(x, y)
                context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(.black))
            }
        }
        // 지운 자리가 창 바탕까지 뚫리지 않고 로고 안에서만 비게 한다
        .compositingGroup()
        .frame(width: size, height: size)
        .accessibilityLabel("Canopy")
    }
}
