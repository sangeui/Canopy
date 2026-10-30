// 앱 아이콘(Icon Composer 형식, Packaging/AppIcon.icon)의 잎 레이어를 그린다. 보통은 scripts/make-app-icon.sh로 부른다.
// 바탕색·유리 효과·라이트/다크 구분은 icon.json에 있고, macOS가 그 위에 유리 질감을 입힌다.
//   swift scripts/make-app-icon.swift Packaging/AppIcon.icon/Assets
// 잎 모양은 CanopyLogo와 같은 좌표(아이콘 판 1024, 위가 0)를 쓴다.
import AppKit

let side: CGFloat = 1024

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: side - y) }

func quad(_ path: NSBezierPath, to: NSPoint, control: NSPoint) {
    let from = path.currentPoint
    path.curve(to: to,
               controlPoint1: NSPoint(x: from.x + 2 / 3 * (control.x - from.x), y: from.y + 2 / 3 * (control.y - from.y)),
               controlPoint2: NSPoint(x: to.x + 2 / 3 * (control.x - to.x), y: to.y + 2 / 3 * (control.y - to.y)))
}

func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> NSBezierPath {
    let c = pt(x, y)
    return NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}

/// 잎 둘레. 두 곡선이 만나는 양 끝을 그대로 두면 뾰족해서, 끝 가까이(`tip`만큼)에서 곡선을 잘라 내고
/// 그 사이를 끝점을 조절점으로 한 곡선으로 잇는다.
func leafOutline(tip: CGFloat = 0.045) -> NSBezierPath {
    let base = NSPoint(x: 300, y: 774), top = NSPoint(x: 740, y: 234)
    let left = NSPoint(x: 230, y: 264), right = NSPoint(x: 810, y: 744)
    // 2차 곡선의 t0~t1 부분: 양 끝점과 조절점(blossom)
    func point(_ a: NSPoint, _ c: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
        NSPoint(x: (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * c.x + t * t * b.x, y: (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * c.y + t * t * b.y)
    }
    func control(_ a: NSPoint, _ c: NSPoint, _ b: NSPoint, _ t0: CGFloat, _ t1: CGFloat) -> NSPoint {
        let wa = (1 - t0) * (1 - t1), wc = t0 * (1 - t1) + t1 * (1 - t0), wb = t0 * t1
        return NSPoint(x: wa * a.x + wc * c.x + wb * b.x, y: wa * a.y + wc * c.y + wb * b.y)
    }
    func p(_ q: NSPoint) -> NSPoint { pt(q.x, q.y) }
    let path = NSBezierPath()
    path.move(to: p(point(base, left, top, tip)))
    quad(path, to: p(point(base, left, top, 1 - tip)), control: p(control(base, left, top, tip, 1 - tip)))
    quad(path, to: p(point(top, right, base, tip)), control: p(top))
    quad(path, to: p(point(top, right, base, 1 - tip)), control: p(control(top, right, base, tip, 1 - tip)))
    quad(path, to: p(point(base, left, top, tip)), control: p(base))
    path.close()
    return path
}

let nodes: [(CGFloat, CGFloat)] = [(430, 619), (520, 524), (600, 414), (395, 384), (700, 584), (540, 264)]
let veins: [((CGFloat, CGFloat), (CGFloat, CGFloat), (CGFloat, CGFloat))] = [
    ((430, 619), (450, 464), (395, 384)),
    ((520, 524), (660, 504), (700, 584)),
    ((600, 414), (600, 304), (540, 264)),
]

/// 잎을 그라디언트로 칠하고 잎맥(브랜치)과 마디(커밋)를 비운다. 마디는 잎 색 테 안의 구멍이다.
func leaf(from top: UInt32, to bottom: UInt32) {
    let ctx = NSGraphicsContext.current!.cgContext
    let outline = leafOutline()
    let paint = { NSGradient(starting: rgb(top), ending: rgb(bottom))!.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: -60) }

    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    paint()
    NSGraphicsContext.restoreGraphicsState()

    ctx.setBlendMode(.destinationOut)
    NSColor.black.setStroke()
    let spine = NSBezierPath()
    spine.move(to: pt(330, 739))
    quad(spine, to: pt(705, 269), control: pt(520, 554))
    spine.lineWidth = 26
    spine.lineCapStyle = .round
    spine.stroke()
    for (from, control, to) in veins {
        let vein = NSBezierPath()
        vein.move(to: pt(from.0, from.1))
        quad(vein, to: pt(to.0, to.1), control: pt(control.0, control.1))
        vein.lineWidth = 20
        vein.lineCapStyle = .round
        vein.stroke()
    }

    // 마디 둘레의 테를 잎 색으로 다시 칠한 뒤 가운데를 비운다
    ctx.setBlendMode(.normal)
    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    let rings = NSBezierPath()
    for (x, y) in nodes { rings.append(dot(x, y, 40)) }
    rings.addClip()
    paint()
    NSGraphicsContext.restoreGraphicsState()
    ctx.setBlendMode(.destinationOut)
    NSColor.black.setFill()
    for (x, y) in nodes { dot(x, y, 28).fill() }
    ctx.endTransparencyLayer()
}

/// Icon Composer 캔버스는 아이콘 판 전체다. 판(가운데 824)에 맞춰 그린 잎을 1024로 키운다.
func writeLayer(top: UInt32, bottom: UInt32, to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let k: CGFloat = 1024 / 824
    ctx.translateBy(x: 512, y: 512)
    ctx.scaleBy(x: k, y: k)
    ctx.translateBy(x: -512, y: -512)
    leaf(from: top, to: bottom)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let out = CommandLine.arguments[1]
// 라이트: 맑은 민트 바탕 위 짙은 초록 잎. 다크: 짙은 초록 바탕 위 밝은 민트 잎.
writeLayer(top: 0x34D3A5, bottom: 0x0B8A69, to: out + "/leaf-light.png")
writeLayer(top: 0x8FF2CF, bottom: 0x14B58C, to: out + "/leaf-dark.png")
