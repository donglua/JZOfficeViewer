import Foundation
import CJZOffice

public enum OfficeError: LocalizedError, Sendable {
    case parseFailed(String)
    case partReadFailed(String)
    case invalidArguments(String)
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let msg),
             .partReadFailed(let msg),
             .invalidArguments(let msg),
             .renderFailed(let msg):
            return msg
        }
    }
}

/// JZOffice macOS 原生桥接器（对齐 Android / HarmonyOS `NativeCore`）
public enum NativeCore {

    /// 同步解析本地文档路径为 `OfficeDocument` 模型
    public static func parseDocument(at path: String) throws -> OfficeDocument {
        let json = try parseJSON(at: path)
        return try decodeDocument(from: json)
    }

    /// 异步解析本地文档路径为 `OfficeDocument` 模型（在后台并发线程执行，不阻塞主线程）
    public static func parseDocumentAsync(at path: String) async throws -> OfficeDocument {
        try await Task.detached(priority: .userInitiated) {
            try parseDocument(at: path)
        }.value
    }

    /// 同步解析本地文档路径为原始 JSON 字符串
    public static func parseJSON(at path: String) throws -> String {
        guard !path.isEmpty else {
            throw OfficeError.invalidArguments("File path cannot be empty")
        }
        let result = path.withCString { cPath in
            jz_office_parse_path(cPath)
        }
        defer {
            if let dataPtr = result.data {
                jz_office_free_string(dataPtr)
            }
            if let errPtr = result.error {
                jz_office_free_string(errPtr)
            }
        }
        if let errPtr = result.error {
            let msg = String(cString: errPtr)
            throw OfficeError.parseFailed(msg)
        }
        guard let dataPtr = result.data else {
            throw OfficeError.parseFailed("Empty parser output")
        }
        return String(cString: dataPtr)
    }

    /// 从 JSON 字符串解码并校验 `OfficeDocument`（schemaVersion == 9）
    public static func decodeDocument(from json: String) throws -> OfficeDocument {
        guard let data = json.data(using: .utf8) else {
            throw OfficeError.parseFailed("Invalid UTF-8 JSON output")
        }
        do {
            return try JSONDecoder().decode(OfficeDocument.self, from: data)
        } catch {
            throw OfficeError.parseFailed("Document decode failed: \(error.localizedDescription)")
        }
    }

    /// 同步在指定本地文档路径中执行大小写不敏感的全文检索
    public static func searchDocument(at path: String, query: String) throws -> [OfficeSearchMatch] {
        guard !query.isEmpty else { return [] }
        let json = try searchJSON(at: path, query: query)
        return try decodeSearchMatches(from: json)
    }

    /// 异步在指定本地文档路径中执行全文检索（在后台并发线程执行，不阻塞主线程）
    public static func searchDocumentAsync(at path: String, query: String) async throws -> [OfficeSearchMatch] {
        guard !query.isEmpty else { return [] }
        return try await Task.detached(priority: .userInitiated) {
            try searchDocument(at: path, query: query)
        }.value
    }

    /// 同步在指定本地文档路径中执行全文检索并返回原始 JSON 字符串
    public static func searchJSON(at path: String, query: String) throws -> String {
        guard !path.isEmpty else {
            throw OfficeError.invalidArguments("File path cannot be empty")
        }
        let result = path.withCString { cPath in
            query.withCString { cQuery in
                jz_office_search_path(cPath, cQuery)
            }
        }
        defer {
            if let dataPtr = result.data {
                jz_office_free_string(dataPtr)
            }
            if let errPtr = result.error {
                jz_office_free_string(errPtr)
            }
        }
        if let errPtr = result.error {
            let msg = String(cString: errPtr)
            throw OfficeError.parseFailed(msg)
        }
        guard let dataPtr = result.data else {
            throw OfficeError.parseFailed("Empty search output")
        }
        return String(cString: dataPtr)
    }

    /// 从 JSON 字符串解码 `OfficeSearchMatch` 数组
    public static func decodeSearchMatches(from json: String) throws -> [OfficeSearchMatch] {
        guard let data = json.data(using: .utf8) else {
            throw OfficeError.parseFailed("Invalid UTF-8 search JSON output")
        }
        do {
            return try JSONDecoder().decode([OfficeSearchMatch].self, from: data)
        } catch {
            throw OfficeError.parseFailed("Search matches decode failed: \(error.localizedDescription)")
        }
    }

    /// 同步读取 ZIP 包内指定媒体部件字节（受 16 MiB 单部件与 256 MiB 整包预算限制）
    public static func readPart(at path: String, part: String) throws -> Data {
        guard !path.isEmpty, !part.isEmpty else {
            throw OfficeError.invalidArguments("Path and part name cannot be empty")
        }
        let result = path.withCString { cPath in
            part.withCString { cPart in
                jz_office_read_part(cPath, cPart)
            }
        }
        defer {
            if let dataPtr = result.data {
                jz_office_free_bytes(dataPtr, result.len)
            }
            if let errPtr = result.error {
                jz_office_free_string(errPtr)
            }
        }
        if let errPtr = result.error {
            let msg = String(cString: errPtr)
            throw OfficeError.partReadFailed(msg)
        }
        guard let dataPtr = result.data, result.len > 0 else {
            return Data()
        }
        return Data(bytes: dataPtr, count: result.len)
    }

    /// 异步读取 ZIP 包内指定媒体部件字节
    public static func readPartAsync(at path: String, part: String) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try readPart(at: path, part: part)
        }.value
    }

    /// 精准淘汰指定文档路径在 Rust 底层的包句柄缓存
    public static func evictCache(at path: String) {
        guard !path.isEmpty else { return }
        path.withCString { cPath in
            jz_office_evict_cache(cPath)
        }
    }

    /// 清空全部底层文档包缓存
    public static func clearCache() {
        jz_office_clear_cache()
    }
}
