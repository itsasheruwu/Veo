// Purpose: Decodes small attachment previews off the main actor and reuses them.

import Foundation
import ImageIO
import UniformTypeIdentifiers

actor DesktopAttachmentThumbnailCache {
    static let shared = DesktopAttachmentThumbnailCache()
    private let cache = NSCache<NSString, NSData>()

    init() {
        cache.countLimit = 64
        cache.totalCostLimit = 8 * 1_024 * 1_024
    }

    func thumbnail(at path: String) -> Data? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let size = values.fileSize, size > 0 else { return nil }
        let key = "\(path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(size)" as NSString
        if let data = cache.object(forKey: key) { return data as Data }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 96,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        cache.setObject(data, forKey: key, cost: data.length)
        return data as Data
    }
}
