import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AttachmentImageDecoder {
    static let galleryThumbnailPixelSize = 256

    static func isImage(_ data: Data) -> Bool {
        imageSource(for: data) != nil
    }

    static func thumbnail(data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let source = imageSource(for: data) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func imageSource(for data: Data) -> CGImageSource? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let contentType = UTType(identifier as String),
              contentType.conforms(to: .image) else {
            return nil
        }
        return source
    }
}
