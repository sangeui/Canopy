// 개발 빌드 아이콘. 원래 아이콘 아래쪽에 주황 "DEV" 띠를 얹어 설치한 앱과 Dock에서 구별한다.
//   swift scripts/make-dev-icon.swift <원래 AppIcon.png> <결과 png>
import AppKit

let source = NSImage(contentsOfFile: CommandLine.arguments[1])!
let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let canvas = NSRect(x: 0, y: 0, width: side, height: side)
source.draw(in: canvas)

// 아이콘 판(가운데 약 82%) 아래쪽에 걸친 알약 모양
let badge = NSRect(x: 262, y: 150, width: 500, height: 170)
NSColor(red: 0.96, green: 0.45, blue: 0.09, alpha: 1).setFill()
NSBezierPath(roundedRect: badge, xRadius: 85, yRadius: 85).fill()
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 118, weight: .heavy),
    .foregroundColor: NSColor.white,
    .kern: 6,
]
let text = "DEV" as NSString
let size = text.size(withAttributes: attributes)
text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attributes)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
