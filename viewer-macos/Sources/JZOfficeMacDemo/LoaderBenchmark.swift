import Foundation
import CoreGraphics
import JZOffice

/// 供演示与诊断使用的 OfficeImageLoader 视口加载性能与预算基准测试
public struct LoaderBenchmark {
    public struct BenchmarkResult: Sendable {
        public let totalRequested: Int
        public let finalCachedCount: Int
        public let finalTotalPixels: Int
        public let elapsedSeconds: Double
    }

    /// 模拟视口滚动并执行按需图片加载基准测试
    public static func runBenchmark(
        filePath: String,
        sampleParts: [String],
        maxTotalPixels: Int = OfficeImageLoader.defaultMaxTotalPixels,
        maxCachedImages: Int = OfficeImageLoader.defaultMaxCachedImages
    ) async -> BenchmarkResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let loader = OfficeImageLoader(
            filePath: filePath,
            maxTotalPixels: maxTotalPixels,
            maxCachedImages: maxCachedImages
        )
        defer { loader.close() }

        // 模拟视口滚动：每次请求两张图片（一张可见、一张预取）
        for i in 0..<sampleParts.count {
            let visible = [sampleParts[i]]
            let prefetch = (i + 1 < sampleParts.count) ? [sampleParts[i + 1]] : []
            loader.request(visibleParts: visible, prefetchParts: prefetch)
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms 模拟滚动停留
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let snap = loader.snapshot
        var totalPx = 0
        for img in snap.values {
            totalPx += img.width * img.height
        }

        return BenchmarkResult(
            totalRequested: sampleParts.count,
            finalCachedCount: snap.count,
            finalTotalPixels: totalPx,
            elapsedSeconds: elapsed
        )
    }
}
