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
    ///
    /// 只读取判定格式与页数所需的少量 ZIP 部件，不构建正文、样式与几何模型；
    /// 结果按 路径 + 大小 + 修改时间 复用，连续读取同一文件不会重复解析。
    public static func read(from url: URL) throws -> OfficeMetadata {
        let json = try NativeCore.metadataJSON(at: url.path)
        return try decode(from: json)
    }

    /// core 元数据协议的解码结果，字段与 `metadata_path_to_json` 一一对应
    private struct Payload: Decodable {
        let schemaVersion: Int
        let kind: String
        let pageCount: Int
        let width: Double
        let height: Double
        let sheetNames: [String]
        let warnings: [String]
    }

    /// 解码元数据协议；元数据不含可绘制内容，因此不复用文档渲染模型
    static func decode(from json: String) throws -> OfficeMetadata {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: Data(json.utf8))
        } catch {
            throw OfficeError.parseFailed("Invalid core metadata: \(error)")
        }
        guard payload.schemaVersion == 9 else {
            throw OfficeError.parseFailed("Unsupported core model version: \(payload.schemaVersion)")
        }
        let kind: OfficeKind
        switch payload.kind {
        case "DOCX": kind = .docx
        case "PPTX": kind = .pptx
        case "XLSX": kind = .xlsx
        default: throw OfficeError.parseFailed("Unsupported document kind: \(payload.kind)")
        }
        return OfficeMetadata(
            format: kind,
            pageCount: payload.pageCount,
            width: CGFloat(payload.width),
            height: CGFloat(payload.height),
            sheetNames: payload.sheetNames,
            warnings: payload.warnings
        )
    }

    /// 异步读取本地文档 URL 的元数据
    public static func readAsync(from url: URL) async throws -> OfficeMetadata {
        try await Task.detached(priority: .userInitiated) {
            try read(from: url)
        }.value
    }
}
