import Foundation
import CoreGraphics

/// JZOffice 跨平台文档模型（严格对齐 `core/src/model.rs` 与 `core/src/spreadsheet.rs`，schemaVersion = 9）
public enum OfficeKind: String, Codable, Sendable {
    case docx = "DOCX"
    case pptx = "PPTX"
    case xlsx = "XLSX"
}

public enum OfficeElementType: String, Codable, Sendable {
    case text = "TEXT"
    case image = "IMAGE"
    case rect = "RECT"
    case ellipse = "ELLIPSE"
    case line = "LINE"
    case table = "TABLE"
    case path = "PATH"
}

public enum OfficeVerticalAlignment: String, Codable, Sendable {
    case top = "TOP"
    case center = "CENTER"
    case bottom = "BOTTOM"
}

public enum OfficeLineSpacingRule: String, Codable, Sendable {
    case auto = "AUTO"
    case exact = "EXACT"
    case atLeast = "AT_LEAST"
}

public enum OfficePathCommandOp: String, Codable, Sendable {
    case move = "MOVE"
    case line = "LINE"
    case quad = "QUAD"
    case cubic = "CUBIC"
    case close = "CLOSE"
}

public struct OfficePathCommand: Codable, Sendable {
    public let op: OfficePathCommandOp
    public let points: [CGFloat]

    enum CodingKeys: String, CodingKey {
        case op, points
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.op = try c.decode(OfficePathCommandOp.self, forKey: .op)
        self.points = try c.decodeIfPresent([CGFloat].self, forKey: .points) ?? []
    }
}

public struct OfficePath: Codable, Sendable {
    public let fill: Bool
    public let stroke: Bool
    public let commands: [OfficePathCommand]

    enum CodingKeys: String, CodingKey {
        case fill, stroke, commands
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.fill = try c.decodeIfPresent(Bool.self, forKey: .fill) ?? false
        self.stroke = try c.decodeIfPresent(Bool.self, forKey: .stroke) ?? false
        self.commands = try c.decodeIfPresent([OfficePathCommand].self, forKey: .commands) ?? []
    }
}

public struct OfficeGradientFill: Codable, Sendable {
    public let colors: [UInt32]
    public let positions: [CGFloat]
    public let points: [CGFloat]
    public let transform: [CGFloat]?
}

public struct OfficeRun: Codable, Sendable {
    public let text: String
    public let fontFace: String
    public let size: CGFloat
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let color: UInt32

    public init(
        text: String,
        fontFace: String = "",
        size: CGFloat = 12,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        color: UInt32 = 0xff202124
    ) {
        self.text = text
        self.fontFace = fontFace
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.color = color
    }

    enum CodingKeys: String, CodingKey {
        case text, fontFace, size, bold, italic, underline, color
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        self.fontFace = try c.decodeIfPresent(String.self, forKey: .fontFace) ?? ""
        self.size = try c.decodeIfPresent(CGFloat.self, forKey: .size) ?? 12
        self.bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        self.italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        self.underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        self.color = try c.decodeIfPresent(UInt32.self, forKey: .color) ?? 0xff202124
    }
}

public struct OfficeParagraph: Codable, Sendable {
    public let runs: [OfficeRun]
    public let alignment: Int
    public let before: CGFloat
    public let after: CGFloat
    public let indent: CGFloat
    public let rightIndent: CGFloat
    public let firstLineIndent: CGFloat
    public let lineSpacingRule: OfficeLineSpacingRule
    public let lineSpacing: CGFloat
    public let bullet: String

    enum CodingKeys: String, CodingKey {
        case runs, alignment, before, after, indent, rightIndent, firstLineIndent, lineSpacingRule, lineSpacing, bullet
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.runs = try c.decodeIfPresent([OfficeRun].self, forKey: .runs) ?? []
        self.alignment = try c.decodeIfPresent(Int.self, forKey: .alignment) ?? 0
        self.before = try c.decodeIfPresent(CGFloat.self, forKey: .before) ?? 0
        self.after = try c.decodeIfPresent(CGFloat.self, forKey: .after) ?? 0
        self.indent = try c.decodeIfPresent(CGFloat.self, forKey: .indent) ?? 0
        self.rightIndent = try c.decodeIfPresent(CGFloat.self, forKey: .rightIndent) ?? 0
        self.firstLineIndent = try c.decodeIfPresent(CGFloat.self, forKey: .firstLineIndent) ?? 0
        self.lineSpacingRule = try c.decodeIfPresent(OfficeLineSpacingRule.self, forKey: .lineSpacingRule) ?? .auto
        self.lineSpacing = try c.decodeIfPresent(CGFloat.self, forKey: .lineSpacing) ?? 1.0
        self.bullet = try c.decodeIfPresent(String.self, forKey: .bullet) ?? ""
    }
}

public struct OfficeElement: Codable, Sendable {
    public let type: OfficeElementType
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    public var transform: [CGFloat]
    public var padding: CGFloat
    public var fill: UInt32
    public var stroke: UInt32
    public var strokeWidth: CGFloat
    public var image: String?
    public var imageBounds: [CGFloat]?
    public var verticalAlignment: OfficeVerticalAlignment
    public var textWrap: Bool
    public var paragraphs: [OfficeParagraph]
    public var rows: [[[OfficeParagraph]]]
    public var columnWidths: [CGFloat]
    public var cellFills: [[UInt32]]
    public var paths: [OfficePath]
    public var fillGradient: OfficeGradientFill?

    enum CodingKeys: String, CodingKey {
        case type, x, y, width, height, transform, padding, fill, stroke, strokeWidth
        case image, imageBounds, verticalAlignment, textWrap, paragraphs, rows, columnWidths, cellFills, paths, fillGradient
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decodeIfPresent(OfficeElementType.self, forKey: .type) ?? .text
        self.x = try c.decodeIfPresent(CGFloat.self, forKey: .x) ?? 0
        self.y = try c.decodeIfPresent(CGFloat.self, forKey: .y) ?? 0
        self.width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 0
        self.height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 0
        self.transform = try c.decodeIfPresent([CGFloat].self, forKey: .transform) ?? [1, 0, 0, 1, 0, 0]
        self.padding = try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 4
        self.fill = try c.decodeIfPresent(UInt32.self, forKey: .fill) ?? 0
        self.stroke = try c.decodeIfPresent(UInt32.self, forKey: .stroke) ?? 0
        self.strokeWidth = try c.decodeIfPresent(CGFloat.self, forKey: .strokeWidth) ?? 1
        self.image = try c.decodeIfPresent(String.self, forKey: .image)
        self.imageBounds = try c.decodeIfPresent([CGFloat].self, forKey: .imageBounds)
        self.verticalAlignment = try c.decodeIfPresent(OfficeVerticalAlignment.self, forKey: .verticalAlignment) ?? .top
        self.textWrap = try c.decodeIfPresent(Bool.self, forKey: .textWrap) ?? true
        self.paragraphs = try c.decodeIfPresent([OfficeParagraph].self, forKey: .paragraphs) ?? []
        self.rows = try c.decodeIfPresent([[[OfficeParagraph]]].self, forKey: .rows) ?? []
        self.columnWidths = try c.decodeIfPresent([CGFloat].self, forKey: .columnWidths) ?? []
        self.cellFills = try c.decodeIfPresent([[UInt32]].self, forKey: .cellFills) ?? []
        self.paths = try c.decodeIfPresent([OfficePath].self, forKey: .paths) ?? []
        self.fillGradient = try c.decodeIfPresent(OfficeGradientFill.self, forKey: .fillGradient)
    }
}

public struct OfficePage: Codable, Sendable {
    public let width: CGFloat
    public let height: CGFloat
    public let background: UInt32
    public let elements: [OfficeElement]

    enum CodingKeys: String, CodingKey {
        case width, height, background, elements
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 720
        self.height = try c.decodeIfPresent(CGFloat.self, forKey: .height) ?? 405
        self.background = try c.decodeIfPresent(UInt32.self, forKey: .background) ?? 0xffffffff
        self.elements = try c.decodeIfPresent([OfficeElement].self, forKey: .elements) ?? []
    }
}

public struct OfficeCellRange: Codable, Sendable {
    public let startRow: Int
    public let startColumn: Int
    public let endRow: Int
    public let endColumn: Int
}

public struct OfficeCellStyle: Codable, Sendable {
    public let fontSize: CGFloat
    public let bold: Bool
    public let italic: Bool
    public let underline: Bool
    public let color: UInt32
    public let fill: UInt32
    public let alignment: Int
    public let verticalAlignment: OfficeVerticalAlignment
    public let wrap: Bool
    public let borders: [UInt32?]
}

public struct OfficeCell: Codable, Sendable {
    public let row: Int
    public let column: Int
    public let text: String
    public let style: Int
    public let numeric: Bool
}

public struct OfficeMergeRect: Codable, Sendable {
    public let left: CGFloat
    public let top: CGFloat
    public let right: CGFloat
    public let bottom: CGFloat
    public let anchor: Int
    public let startRow: Int
    public let endRow: Int
}

public struct OfficeSheetGeometry: Codable, Sendable {
    public let columnOffsets: [CGFloat]
    public let rowOffsets: [CGFloat]
    public let columnVisible: [Int]
    public let rowVisible: [Int]
    public let rowStarts: [Int]
    public let mergedCells: [Bool]
    public let mergeRects: [OfficeMergeRect]
}

public struct OfficeSheet: Codable, Sendable {
    public let name: String
    public let rowHeights: [CGFloat]
    public let columnWidths: [CGFloat]
    public let cells: [OfficeCell]
    public let merges: [OfficeCellRange]
    public let geometry: OfficeSheetGeometry?

    enum CodingKeys: String, CodingKey {
        case name, rowHeights, columnWidths, cells, merges, geometry
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Sheet"
        self.rowHeights = try c.decodeIfPresent([CGFloat].self, forKey: .rowHeights) ?? []
        self.columnWidths = try c.decodeIfPresent([CGFloat].self, forKey: .columnWidths) ?? []
        self.cells = try c.decodeIfPresent([OfficeCell].self, forKey: .cells) ?? []
        self.merges = try c.decodeIfPresent([OfficeCellRange].self, forKey: .merges) ?? []
        self.geometry = try c.decodeIfPresent(OfficeSheetGeometry.self, forKey: .geometry)
    }
}

public struct OfficeDocument: Codable, Sendable {
    public static let expectedSchemaVersion: Int = 9

    public let schemaVersion: Int
    public let kind: OfficeKind
    public let width: CGFloat
    public let pages: [OfficePage]
    public let blocks: [OfficeElement]
    public let warnings: [String]
    public let sheets: [OfficeSheet]
    public let cellStyles: [OfficeCellStyle]
    public let headerBlocks: [OfficeElement]
    public let footerBlocks: [OfficeElement]
    public let headerDistance: CGFloat
    public let footerDistance: CGFloat
    public let marginTop: CGFloat
    public let marginBottom: CGFloat
    public let marginLeft: CGFloat
    public let marginRight: CGFloat

    enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, width, pages, blocks, warnings, sheets, cellStyles
        case headerBlocks, footerBlocks, headerDistance, footerDistance
        case marginTop, marginBottom, marginLeft, marginRight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.expectedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: c,
                debugDescription: "Unsupported Office schemaVersion \(version), expected \(Self.expectedSchemaVersion)"
            )
        }
        self.schemaVersion = version
        self.kind = try c.decode(OfficeKind.self, forKey: .kind)
        self.width = try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? 595
        self.pages = try c.decodeIfPresent([OfficePage].self, forKey: .pages) ?? []
        self.blocks = try c.decodeIfPresent([OfficeElement].self, forKey: .blocks) ?? []
        self.warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.sheets = try c.decodeIfPresent([OfficeSheet].self, forKey: .sheets) ?? []
        self.cellStyles = try c.decodeIfPresent([OfficeCellStyle].self, forKey: .cellStyles) ?? []
        self.headerBlocks = try c.decodeIfPresent([OfficeElement].self, forKey: .headerBlocks) ?? []
        self.footerBlocks = try c.decodeIfPresent([OfficeElement].self, forKey: .footerBlocks) ?? []
        self.headerDistance = try c.decodeIfPresent(CGFloat.self, forKey: .headerDistance) ?? 0
        self.footerDistance = try c.decodeIfPresent(CGFloat.self, forKey: .footerDistance) ?? 0
        self.marginTop = try c.decodeIfPresent(CGFloat.self, forKey: .marginTop) ?? 0
        self.marginBottom = try c.decodeIfPresent(CGFloat.self, forKey: .marginBottom) ?? 0
        self.marginLeft = try c.decodeIfPresent(CGFloat.self, forKey: .marginLeft) ?? 0
        self.marginRight = try c.decodeIfPresent(CGFloat.self, forKey: .marginRight) ?? 0
    }
}
