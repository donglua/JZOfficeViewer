import Foundation
import CoreGraphics
import ImageIO

/// 文档内嵌图片解码与缓存仓库（对齐鸿蒙 `ImageStore.ets` 与 Android `OfficeImages.java`）
/// 采用 ImageIO 按需下采样，限制单图最长边 4096 px 与总像素预算 8,000,000 像素
public final class ImageStore: @unchecked Sendable {
    public static let maxCachedImages = 32
    public static let maxTotalPixels = 8_000_000
    /// 整篇文档一次性渲染时（PPTX 连续页）工作集远大于单屏预算，预加载按此上限等比降采样，
    /// 保证需要的图片全部驻留，避免 LRU 把刚加载的图片淘汰成灰色占位块
    public static let maxDocumentPixels = 32_000_000
    public static let maxSideLength = 4096

    private let filePath: String
    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var pixelCounts: [String: Int] = [:]
    private var accessOrder: [String] = []
    private var failedParts: Set<String> = []
    private var totalPixels: Int = 0
    private var closed: Bool = false
    /// 淘汰阈值在预加载后按工作集放宽，默认取单屏预算
    private var pixelBudget: Int = ImageStore.maxTotalPixels
    private var imageLimit: Int = ImageStore.maxCachedImages

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
        return loadSync(part: part, data: data, maxPixelBudget: maxPixelBudget)
    }

    /// 复用已读出的包内数据解码入缓存，供批量预加载避免重复读包
    @discardableResult
    func loadSync(part: String, data: Data, maxPixelBudget: Int = 4_000_000) -> CGImage? {
        guard !part.isEmpty, !data.isEmpty else { return nil }
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
        while (images.count > imageLimit || totalPixels > pixelBudget),
              let oldest = accessOrder.first {
            accessOrder.removeFirst()
            if let _ = images.removeValue(forKey: oldest) {
                let px = pixelCounts.removeValue(forKey: oldest) ?? 0
                totalPixels = max(0, totalPixels - px)
            }
        }
    }

    /// 读取图片文件头的像素尺寸；不触发整图解码，用于预加载前估算预算
    private static func nativePixelCount(of data: Data) -> Int {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            return 0
        }
        return width * height
    }

    /// 预加载文档工作集：先按文件头估算每张的目标像素，合计超出上限时等比降采样，
    /// 期间不淘汰任何已加载图片。对齐 Android OfficeImages 的按需分配策略。
    @discardableResult
    public func preload(parts: [String], perImageBudget: Int = 2_000_000) -> [String: CGImage] {
        var ordered: [String] = []
        var seen: Set<String> = []
        for part in parts where !part.isEmpty {
            if seen.insert(part).inserted { ordered.append(part) }
        }
        guard !ordered.isEmpty, !filePath.isEmpty else { return snapshot }

        var dataByPart: [String: Data] = [:]
        var planned: [String: Int] = [:]
        var plannedTotal = 0
        for part in ordered {
            guard let data = try? NativeCore.readPart(at: filePath, part: part), !data.isEmpty else { continue }
            dataByPart[part] = data
            let native = Self.nativePixelCount(of: data)
            let target = native > 0 ? min(native, perImageBudget) : perImageBudget
            planned[part] = target
            plannedTotal += target
        }
        guard !planned.isEmpty else { return snapshot }

        if plannedTotal > Self.maxDocumentPixels {
            let ratio = Double(Self.maxDocumentPixels) / Double(plannedTotal)
            plannedTotal = 0
            for part in ordered {
                guard let target = planned[part] else { continue }
                let scaled = max(16_384, Int(Double(target) * ratio))
                planned[part] = scaled
                plannedTotal += scaled
            }
        }

        lock.lock()
        if closed {
            lock.unlock()
            return [:]
        }
        // 工作集整体驻留：阈值放宽到本次计划用量，避免加载过程中自我淘汰
        pixelBudget = max(Self.maxTotalPixels, plannedTotal)
        imageLimit = max(Self.maxCachedImages, ordered.count)
        lock.unlock()

        for part in ordered {
            guard let data = dataByPart[part], let budget = planned[part] else { continue }
            loadSync(part: part, data: data, maxPixelBudget: budget)
        }
        return snapshot
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
