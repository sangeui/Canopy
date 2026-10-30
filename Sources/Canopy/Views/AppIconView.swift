import ImageIO
import SwiftUI

/// 앱 아이콘. 원본이 1024픽셀이라 그대로 48pt로 줄여 그리면 잎맥과 테두리가 계단처럼 깨진다.
/// 그릴 크기에 맞춰 ImageIO로 한 번 곱게 줄인 이미지를 크기별로 남겨 두고 쓴다.
struct AppIconView: View {
    let size: CGFloat
    @Environment(\.displayScale) private var scale

    var body: some View {
        if let image = Self.image(pixels: Int((size * scale).rounded())) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        }
    }

    @MainActor private static var cache: [Int: NSImage] = [:]

    @MainActor private static func image(pixels: Int) -> NSImage? {
        if let cached = cache[pixels] { return cached }
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let resized = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: pixels,
              ] as CFDictionary)
        else { return nil }
        let image = NSImage(cgImage: resized, size: NSSize(width: pixels, height: pixels))
        cache[pixels] = image
        return image
    }
}
