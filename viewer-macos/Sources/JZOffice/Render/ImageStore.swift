import Foundation
import CoreGraphics
import ImageIO

/// 文档内嵌图片解码与缓存仓库（对齐鸿蒙 `ImageStore.ets` 与 Android `OfficeImages.java`）
/// 采用 ImageIO 按需下采样，限制单图最长边 4096 px 与总像素预算 8,000,000 像素
public final class ImageStore: @unchecked Sendable {
    public static let maxCachedImages = 32
    public static let maxTotalPixels = 8_000_000
    public static let maxSideLength = 4096

    private let filePath: String
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var pixelCounts: [String: Int] = [:]
    private var accessOrder: [String] = []
    private var failedParts: Set<String> = []
    private var totalPixels: Int = 0
    private var closed: Bool = false

    public init(filePath: String) {
        self.filePath = filePath
    }

    public func image(for part: String) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let img = images[part] else { return nil }
        touchLocked(part)
        return img
    }

    public var snapshot: [String: CGImage] {
        lock.lock()
        defer { lock.unlock() }
        return images
    }

    @discardableResult
    public func loadSync(part: String, maxPixelBudget: Int = 4_000_000) -> CGImage? {
        guard !part.isEmpty, !filePath.isEmpty else { return nil }
        lock.lock()
        if closed || failedParts.contains(part) {
            lock.unlock()
            return nil
        }
        if let cached = images[part] {
            touchLocked(part)
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let data = try? NativeCore.readPart(at: filePath, part: part), !data.isEmpty else {
            lock.lock()
            failedParts.insert(part)
            lock.unlock()
            return nil
        }

        guard let decoded = Self.decodeCGImage(from: data, maxPixels: maxPixelBudget) else {
            lock.lock()
            failedParts.insert(part)
            lock.unlock()
            return nil
        }

        let pixels = decoded.width * decoded.height
        lock.lock()
        defer { lock.unlock() }
        if closed { return nil }
        if let old = images[part] {
            totalPixels = max(0, totalPixels - (pixelCounts[part] ?? (old.width * old.height)))
        }
        images[part] = decoded
        pixelCounts[part] = pixels
        totalPixels += pixels
        touchLocked(part)
        trimLocked()
        return decoded
    }

    public func release() {
        lock.lock()
        let shouldEvict = !closed && !filePath.isEmpty
        closed = true
        images.removeAll()
        pixelCounts.removeAll()
        accessOrder.removeAll()
        failedParts.removeAll()
        totalPixels = 0
        lock.unlock()
        if shouldEvict {
            NativeCore.evictCache(at: filePath)
        }
    }

    private func touchLocked(_ part: String) {
        accessOrder.removeAll { $0 == part }
        accessOrder.append(part)
    }

    private func trimLocked() {
        while (images.count > Self.maxCachedImages || totalPixels > Self.maxTotalPixels),
              let oldest = accessOrder.first {
            accessOrder.removeFirst()
            if let _ = images.removeValue(forKey: oldest) {
                let px = pixelCounts.removeValue(forKey: oldest) ?? 0
                totalPixels = max(0, totalPixels - px)
            }
        }
    }

    public static func decodeCGImage(from data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let srcW = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let srcH = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0

        let maxDim: Int
        if srcW > 0 && srcH > 0 {
            let srcPixels = srcW * srcH
            if srcPixels > maxPixels && maxPixels > 0 {
                let ratio = sqrt(Double(maxPixels) / Double(srcPixels))
                let targetMax = Int(Double(max(srcW, srcH)) * ratio)
                maxDim = max(64, min(Self.maxSideLength, targetMax))
            } else {
                maxDim = min(Self.maxSideLength, max(srcW, srcH))
            }
        } else {
            maxDim = 2048
        }

        let thumbOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim
        ]
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) {
            return thumb
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
