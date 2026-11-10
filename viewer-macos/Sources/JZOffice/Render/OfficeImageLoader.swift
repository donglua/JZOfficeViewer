import Foundation
import CoreGraphics
import ImageIO

/// 针对 macOS 视口虚拟化设计的异步图片按需加载与 LRU 缓存管理器
public final class OfficeImageLoader: @unchecked Sendable {
    public static let defaultMaxTotalPixels = 16_000_000
    public static let defaultMaxCachedImages = 48
    public static let defaultPerImageBudget = 4_000_000

    private let filePath: String
    private let maxTotalPixels: Int
    private let maxCachedImages: Int
    private let onImageDecoded: (@MainActor @Sendable () -> Void)?

    private let lock = NSLock()
    private var images: [String: CGImage] = [:]
    private var pixelCounts: [String: Int] = [:]
    private var accessOrder: [String] = []
    private var failedParts: Set<String> = []
    private var totalPixels: Int = 0

    private var wanted: [String] = []
    private var revision: Int = 0
    private var isLoading: Bool = false
    private var isClosed: Bool = false

    private let workerQueue = DispatchQueue(
        label: "cn.jingzhuan.office.images",
        qos: .userInitiated
    )

    public init(
        filePath: String,
        maxTotalPixels: Int = defaultMaxTotalPixels,
        maxCachedImages: Int = defaultMaxCachedImages,
        onImageDecoded: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.filePath = filePath
        self.maxTotalPixels = maxTotalPixels
        self.maxCachedImages = maxCachedImages
        self.onImageDecoded = onImageDecoded
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

    public func request(visibleParts: [String], prefetchParts: [String]) {
        var ordered: [String] = []
        var seen: Set<String> = []
        for part in visibleParts where !part.isEmpty {
            if seen.insert(part).inserted { ordered.append(part) }
        }
        for part in prefetchParts where !part.isEmpty {
            if seen.insert(part).inserted { ordered.append(part) }
        }

        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        if ordered == wanted {
            lock.unlock()
            return
        }
        revision += 1
        wanted = ordered
        trimLocked()
        lock.unlock()

        loadNext()
    }

    private func touchLocked(_ part: String) {
        accessOrder.removeAll { $0 == part }
        accessOrder.append(part)
    }

    private func trimLocked() {
        let wantedSet = Set(wanted)
        while images.count > maxCachedImages || totalPixels > maxTotalPixels {
            if let candidate = accessOrder.first(where: { !wantedSet.contains($0) }) {
                accessOrder.removeAll { $0 == candidate }
                if let _ = images.removeValue(forKey: candidate) {
                    let px = pixelCounts.removeValue(forKey: candidate) ?? 0
                    totalPixels = max(0, totalPixels - px)
                }
            } else {
                break
            }
        }
    }

    private func loadNext() {
        lock.lock()
        if isClosed || isLoading {
            lock.unlock()
            return
        }

        var nextPart: String? = nil
        for part in wanted {
            if images[part] == nil && !failedParts.contains(part) {
                nextPart = part
                break
            }
        }

        guard let part = nextPart else {
            lock.unlock()
            return
        }

        isLoading = true
        let currentRevision = revision
        let remainingBudget = max(1_000_000, maxTotalPixels - totalPixels)
        let visibleCount = max(1, wanted.count)
        let perImageBudget = min(Self.defaultPerImageBudget, max(1_000_000, remainingBudget / visibleCount))
        lock.unlock()

        workerQueue.async { [weak self] in
            guard let self = self else { return }
            self.decodeAndStore(part: part, token: currentRevision, budget: perImageBudget)
        }
    }

    private func decodeAndStore(part: String, token: Int, budget: Int) {
        let data = try? NativeCore.readPart(at: filePath, part: part)
        let decoded: CGImage?
        if let data = data, !data.isEmpty {
            decoded = ImageStore.decodeCGImage(from: data, maxPixels: budget)
        } else {
            decoded = nil
        }

        lock.lock()
        isLoading = false
        if isClosed {
            lock.unlock()
            return
        }

        if let decoded = decoded {
            let stillWanted = wanted.contains(part)
            if token == revision || stillWanted {
                let pixels = decoded.width * decoded.height
                if let old = images[part] {
                    totalPixels = max(0, totalPixels - (pixelCounts[part] ?? (old.width * old.height)))
                }
                images[part] = decoded
                pixelCounts[part] = pixels
                totalPixels += pixels
                touchLocked(part)
                trimLocked()

                DispatchQueue.main.async { [weak self] in
                    self?.onImageDecoded?()
                }
            }
        } else {
            failedParts.insert(part)
        }
        lock.unlock()

        loadNext()
    }

    public func close() {
        lock.lock()
        isClosed = true
        wanted.removeAll()
        images.removeAll()
        pixelCounts.removeAll()
        accessOrder.removeAll()
        failedParts.removeAll()
        totalPixels = 0
        lock.unlock()
    }

    // MARK: - Testing Support

    internal var currentTotalPixels: Int {
        lock.lock()
        defer { lock.unlock() }
        return totalPixels
    }

    internal var cachedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return images.count
    }

    internal var currentWanted: [String] {
        lock.lock()
        defer { lock.unlock() }
        return wanted
    }

    internal var currentAccessOrder: [String] {
        lock.lock()
        defer { lock.unlock() }
        return accessOrder
    }

    internal var failedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return failedParts.count
    }

    internal var isClosedState: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    internal func insertImageForTesting(part: String, image: CGImage) {
        lock.lock()
        defer { lock.unlock() }
        let pixels = image.width * image.height
        if let old = images[part] {
            totalPixels = max(0, totalPixels - (pixelCounts[part] ?? (old.width * old.height)))
        }
        images[part] = image
        pixelCounts[part] = pixels
        totalPixels += pixels
        touchLocked(part)
        trimLocked()
    }
}
