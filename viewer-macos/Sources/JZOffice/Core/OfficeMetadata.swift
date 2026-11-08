import Foundation
import CoreGraphics

/// 无头（Headless）Office 文档元数据快照，对齐 Android `OfficeMetadata` 与鸿蒙 `OfficeMetadataInfo`
public struct OfficeMetadata: Sendable, Equatable {
    public let format: OfficeKind
    public let pageCount: Int
    public let width: CGFloat
    public let height: CGFloat
    public let sheetNames: [String]
    public let warnings: [String]

    public var widthPt: CGFloat { width }
    public var heightPt: CGFloat { height }

    /// 从已解码的 `OfficeDocument` 提取元数据
    public static func fromDocument(_ doc: OfficeDocument) -> OfficeMetadata {
        switch doc.kind {
        case .xlsx:
            let names = doc.sheets.map(\.name)
            return OfficeMetadata(
                format: .xlsx,
                pageCount: doc.sheets.count,
                width: doc.width,
                height: 0,
                sheetNames: names,
                warnings: doc.warnings
            )
        case .pptx:
            let w = doc.pages.first?.width ?? doc.width
            let h = doc.pages.first?.height ?? 0
            return OfficeMetadata(
                format: .pptx,
                pageCount: doc.pages.count,
                width: w,
                height: h,
                sheetNames: [],
                warnings: doc.warnings
            )
        case .docx:
            return OfficeMetadata(
                format: .docx,
                pageCount: 1,
                width: doc.width,
                height: 0,
                sheetNames: [],
                warnings: doc.warnings
            )
        }
    }

    /// 同步读取本地文档 URL 的元数据
    public static func read(from url: URL) throws -> OfficeMetadata {
        let path = url.path
        defer { NativeCore.evictCache(at: path) }
        let doc = try NativeCore.parseDocument(at: path)
        return fromDocument(doc)
    }

    /// 异步读取本地文档 URL 的元数据
    public static func readAsync(from url: URL) async throws -> OfficeMetadata {
        try await Task.detached(priority: .userInitiated) {
            try read(from: url)
        }.value
    }
}
