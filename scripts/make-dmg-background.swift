// DMG 창 배경을 그린다. 문구나 배치를 바꾸면 다시 실행하고 결과를 커밋한다.
//   swift scripts/make-dmg-background.swift Packaging/dmg-background.tiff
// 아이콘 자리(가운데 좌표)는 make-dmg.sh의 ICON_*와 맞춘다.
import AppKit

let size = NSSize(width: 640, height: 400)
let output = CommandLine.arguments[1]

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()

    // AppKit은 아래가 0이다. Finder 좌표(위가 0)로 적은 y를 뒤집어 쓴다.
    func centered(_ text: String, font: NSFont, color: NSColor, top: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let measured = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (size.width - measured.width) / 2, y: size.height - top - measured.height), withAttributes: attributes)
    }
    centered("Canopy 설치", font: .systemFont(ofSize: 30, weight: .bold), color: NSColor(white: 0.13, alpha: 1), top: 64)
    centered("Canopy를 응용 프로그램 폴더로 끌어다 놓으세요", font: .systemFont(ofSize: 15), color: NSColor(white: 0.5, alpha: 1), top: 112)

    // 두 아이콘 사이 화살표. 아이콘 가운데 y는 250이다.
    let arrow = NSBezierPath()
    let y = size.height - 238
    arrow.move(to: NSPoint(x: 296, y: y))
    arrow.line(to: NSPoint(x: 344, y: y))
    arrow.move(to: NSPoint(x: 334, y: y + 9))
    arrow.line(to: NSPoint(x: 344, y: y))
    arrow.line(to: NSPoint(x: 334, y: y - 9))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(white: 0.78, alpha: 1).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// 1배와 2배를 한 TIFF에 담으면 Finder가 화면 배율에 맞는 쪽을 쓴다
let data = NSBitmapImageRep.tiffRepresentationOfImageReps(in: [render(scale: 1), render(scale: 2)], using: .lzw, factor: 0)!
try! data.write(to: URL(fileURLWithPath: output))
