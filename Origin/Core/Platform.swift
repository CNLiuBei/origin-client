import ImageIO
import SwiftUI

#if os(macOS)
import AppKit

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: NSImage) {
        self.init(nsImage: platformImage)
    }
}

extension NSImage {
    nonisolated convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    var cgImageRef: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

extension Color {
    static var appBackground: Color { Color(nsColor: .windowBackgroundColor) }
}

/// macOS 没有尺寸类别，窗口通常足够宽，按 regular 处理
enum UserInterfaceSizeClass: Sendable {
    case compact, regular
}

extension EnvironmentValues {
    var horizontalSizeClass: UserInterfaceSizeClass? { .regular }
}
#else
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: UIImage) {
        self.init(uiImage: platformImage)
    }
}

extension UIImage {
    var cgImageRef: CGImage? { cgImage }
}

extension Color {
    static var appBackground: Color { Color(uiColor: .systemBackground) }
}
#endif

/// 用 ImageIO 在后台线程完成解码（并限制最大像素），两端通用
enum ImageDecoding {
    @concurrent
    static func decode(_ data: Data, maxPixelSize: Int = 2000) async -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 把任意格式的图片数据转成 JPEG（系统播放器的封面元数据只接受 JPEG）
    @concurrent
    static func jpegData(from data: Data, maxPixelSize: Int = 1200) async -> Data? {
        guard let image = await decode(data, maxPixelSize: maxPixelSize) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

extension View {
    /// iOS 上使用行内标题，macOS 无此概念
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// 地址、账号等输入框：关闭自动大写与自动纠错
    func plainTextEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    /// 地址输入框使用 URL 键盘
    func urlKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }

    /// 在 iOS 详情页等全屏内容中隐藏标签栏
    func hidesTabBar() -> some View {
        #if os(iOS)
        toolbarVisibility(.hidden, for: .tabBar)
        #else
        self
        #endif
    }
}
