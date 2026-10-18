package cn.jingzhuan.lib.office;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class DocumentDecoder {
    static OfficeDocument decode(String json) throws IOException {
        try {
            JSONObject root = new JSONObject(json);
            if (root.getInt("schemaVersion") != 9) throw new IOException("Unsupported core model version");
            OfficeDocument document = new OfficeDocument();
            document.kind = OfficeDocument.Kind.valueOf(root.getString("kind"));
            document.width = (float) root.getDouble("width");
            JSONArray warnings = root.getJSONArray("warnings");
            for (int i = 0; i < warnings.length(); i++) document.warn(warnings.getString(i));
            JSONArray blocks = root.getJSONArray("blocks");
            for (int i = 0; i < blocks.length(); i++) document.blocks.add(element(blocks.getJSONObject(i)));
            JSONArray pages = root.getJSONArray("pages");
            for (int i = 0; i < pages.length(); i++) {
                JSONObject p = pages.getJSONObject(i);
                OfficeDocument.Page page = new OfficeDocument.Page();
                page.width = (float) p.getDouble("width"); page.height = (float) p.getDouble("height");
                page.background = (int) p.getLong("background");
                JSONArray elements = p.getJSONArray("elements");
                for (int j = 0; j < elements.length(); j++) page.elements.add(element(elements.getJSONObject(j)));
                document.pages.add(page);
            }
            JSONArray styles = root.getJSONArray("cellStyles");
            if (styles.length() > 2048) throw new JSONException("Too many cell styles");
            for (int i = 0; i < styles.length(); i++) document.cellStyles.add(cellStyle(styles.getJSONObject(i)));
            JSONArray sheets = root.getJSONArray("sheets");
            if (sheets.length() > 32) throw new JSONException("Too many sheets");
            if (document.kind == OfficeDocument.Kind.XLSX && (sheets.length() == 0 || styles.length() == 0)) {
                throw new JSONException("Spreadsheet requires at least one sheet and cell style");
            }
            int cellCount = 0, mergeCount = 0;
            for (int i = 0; i < sheets.length(); i++) {
                SpreadsheetDocument.Sheet sheet = sheet(sheets.getJSONObject(i), document.cellStyles.size());
                cellCount += sheet.cells.size(); mergeCount += sheet.merges.size();
                if (cellCount > 50000 || mergeCount > 1000) throw new JSONException("Spreadsheet model exceeds limits");
                for (SpreadsheetDocument.Cell cell : sheet.cells) {
                    if (cell.text.length() > SpreadsheetDocument.Cell.MAX_PREVIEW_LENGTH) {
                        document.warn("Long spreadsheet cell text is truncated in the preview");
                        break;
                    }
                }
                document.sheets.add(sheet);
            }
            return document;
        } catch (JSONException | IllegalArgumentException e) { throw new IOException("Invalid core display model", e); }
    }

    private static SpreadsheetDocument.CellStyle cellStyle(JSONObject json) throws JSONException {
        SpreadsheetDocument.CellStyle style = new SpreadsheetDocument.CellStyle();
        style.fontSize = dimension(json.getDouble("fontSize"));
        if (style.fontSize == 0) throw new JSONException("Cell font size must be positive");
        style.bold = json.getBoolean("bold"); style.italic = json.getBoolean("italic");
        style.underline = json.getBoolean("underline"); style.wrap = json.getBoolean("wrap");
        style.color = (int) json.getLong("color"); style.fill = (int) json.getLong("fill");
        style.alignment = index(json, "alignment", 4);
        style.verticalAlignment = OfficeDocument.VerticalAlignment.valueOf(json.getString("verticalAlignment"));
        JSONArray borders = json.getJSONArray("borders");
        if (borders.length() != 4) throw new JSONException("Expected four cell borders");
        for (int i = 0; i < 4; i++) if (!borders.isNull(i)) style.borders[i] = (int) borders.getLong(i);
        return style;
    }

    private static SpreadsheetDocument.Sheet sheet(JSONObject json, int styleCount) throws JSONException {
        SpreadsheetDocument.Sheet sheet = new SpreadsheetDocument.Sheet();
        sheet.name = json.getString("name");
        sheet.rowHeights = dimensions(json.getJSONArray("rowHeights"), 10000);
        sheet.columnWidths = dimensions(json.getJSONArray("columnWidths"), 256);
        JSONArray cells = json.getJSONArray("cells");
        if (cells.length() > 50000) throw new JSONException("Too many cells");
        int previousRow = -1, previousColumn = -1;
        for (int i = 0; i < cells.length(); i++) {
            JSONObject source = cells.getJSONObject(i);
            SpreadsheetDocument.Cell cell = new SpreadsheetDocument.Cell();
            cell.row = index(source, "row", sheet.rowHeights.length);
            cell.column = index(source, "column", sheet.columnWidths.length);
            if (cell.row < previousRow || (cell.row == previousRow && cell.column <= previousColumn)) {
                throw new JSONException("Cells must have unique coordinates in row order");
            }
            previousRow = cell.row; previousColumn = cell.column;
            cell.style = index(source, "style", styleCount);
            cell.text = source.getString("text"); cell.numeric = source.getBoolean("numeric");
            sheet.cells.add(cell);
        }
        JSONArray merges = json.getJSONArray("merges");
        if (merges.length() > 1000) throw new JSONException("Too many merged cells");
        for (int i = 0; i < merges.length(); i++) {
            JSONObject source = merges.getJSONObject(i);
            SpreadsheetDocument.CellRange range = new SpreadsheetDocument.CellRange();
            range.startRow = index(source, "startRow", sheet.rowHeights.length);
            range.endRow = index(source, "endRow", sheet.rowHeights.length);
            range.startColumn = index(source, "startColumn", sheet.columnWidths.length);
            range.endColumn = index(source, "endColumn", sheet.columnWidths.length);
            if (range.endRow < range.startRow || range.endColumn < range.startColumn) {
                throw new JSONException("Invalid merged cell range");
            }
            for (SpreadsheetDocument.CellRange previous : sheet.merges) {
                if (range.startRow <= previous.endRow && range.endRow >= previous.startRow
                    && range.startColumn <= previous.endColumn && range.endColumn >= previous.startColumn) {
                    throw new JSONException("Overlapping merged cell ranges");
                }
            }
            sheet.merges.add(range);
        }
        return sheet;
    }

    private static int index(JSONObject json, String name, int limit) throws JSONException {
        double value = json.getDouble(name);
        if (value < 0 || value >= limit || value != Math.floor(value)) throw new JSONException("Invalid " + name);
        return (int) value;
    }

    private static float[] dimensions(JSONArray array, int limit) throws JSONException {
        if (array.length() == 0 || array.length() > limit) throw new JSONException("Invalid sheet dimensions");
        float[] result = new float[array.length()];
        double total = 0;
        for (int i = 0; i < result.length; i++) {
            result[i] = dimension(array.getDouble(i)); total += result[i];
        }
        if (total >= Float.MAX_VALUE) throw new JSONException("Sheet dimensions overflow");
        return result;
    }

    private static float dimension(double value) throws JSONException {
        float result = (float) value;
        if (result < 0 || Float.isNaN(result) || Float.isInfinite(result)) throw new JSONException("Invalid sheet dimension");
        return result;
    }

    private static OfficeDocument.Element element(JSONObject json) throws JSONException {
        OfficeDocument.Element e = new OfficeDocument.Element();
        e.type = OfficeDocument.Type.valueOf(json.getString("type"));
        e.x = (float) json.getDouble("x"); e.y = (float) json.getDouble("y");
        e.width = (float) json.getDouble("width"); e.height = (float) json.getDouble("height");
        e.padding = (float) json.getDouble("padding");
        e.transform = coordinates(json.getJSONArray("transform"), 6, 100000);
        e.fill = (int) json.getLong("fill"); e.stroke = (int) json.getLong("stroke");
        e.strokeWidth = (float) json.getDouble("strokeWidth");
        e.fillGradient = gradient(json.optJSONObject("fillGradient"));
        e.verticalAlignment = OfficeDocument.VerticalAlignment.valueOf(json.getString("verticalAlignment"));
        e.textWrap = json.getBoolean("textWrap");
        if (!json.isNull("imageBounds")) {
            e.imageBounds = coordinates(json.getJSONArray("imageBounds"), 4, 100000000);
            if (e.imageBounds[0] > e.imageBounds[2] || e.imageBounds[1] > e.imageBounds[3]) {
                throw new JSONException("Invalid image bounds");
            }
        }
        if (!json.isNull("image")) {
            e.image = json.getString("image");
        }
        if (!json.isNull("paragraphs")) {
            e.paragraphs.addAll(paragraphs(json.getJSONArray("paragraphs")));
        }
        if (!json.isNull("columnWidths")) {
            JSONArray widths = json.getJSONArray("columnWidths");
            for (int i = 0; i < widths.length(); i++) e.columnWidths.add((float) widths.getDouble(i));
        }
        if (!json.isNull("paths")) {
            JSONArray paths = json.getJSONArray("paths");
            if (paths.length() > 32) throw new JSONException("Too many custom paths");
            for (int i = 0; i < paths.length(); i++) e.paths.add(path(paths.getJSONObject(i)));
        }
        if (!json.isNull("rows")) {
            JSONArray rows = json.getJSONArray("rows");
            for (int i = 0; i < rows.length(); i++) {
                List<List<OfficeDocument.Paragraph>> row = new ArrayList<>();
                JSONArray cells = rows.getJSONArray(i);
                for (int j = 0; j < cells.length(); j++) row.add(paragraphs(cells.getJSONArray(j)));
                e.rows.add(row);
            }
        }
        if (!json.isNull("cellFills")) {
            JSONArray fills = json.getJSONArray("cellFills");
            if (fills.length() != 0 && fills.length() != e.rows.size()) throw new JSONException("Invalid table fill rows");
            for (int i = 0; i < fills.length(); i++) {
                JSONArray cells = fills.getJSONArray(i);
                if (cells.length() != e.rows.get(i).size()) throw new JSONException("Invalid table fill columns");
                List<Integer> row = new ArrayList<>();
                for (int j = 0; j < cells.length(); j++) row.add((int) cells.getLong(j));
                e.cellFills.add(row);
            }
        }
        return e;
    }

    private static OfficeDocument.Path path(JSONObject json) throws JSONException {
        OfficeDocument.Path path = new OfficeDocument.Path();
        path.fill = json.getBoolean("fill"); path.stroke = json.getBoolean("stroke");
        JSONArray commands = json.getJSONArray("commands");
        if (commands.length() == 0 || commands.length() > 10000) throw new JSONException("Invalid custom path commands");
        for (int i = 0; i < commands.length(); i++) {
            JSONObject source = commands.getJSONObject(i);
            OfficeDocument.Command command = new OfficeDocument.Command();
            command.op = source.getString("op");
            JSONArray points = source.optJSONArray("points");
            int expected = command.op.equals("MOVE") || command.op.equals("LINE") ? 2
                : command.op.equals("QUAD") ? 4 : command.op.equals("CUBIC") ? 6 : 0;
            if (expected == 0) {
                if (!command.op.equals("CLOSE") || points != null) throw new JSONException("Invalid custom path command");
            } else {
                if (points == null || points.length() != expected) throw new JSONException("Invalid custom path points");
                command.points = new float[expected];
                for (int j = 0; j < expected; j++) {
                    double value = points.getDouble(j);
                    if (Double.isNaN(value) || Double.isInfinite(value) || Math.abs(value) > 100000) throw new JSONException("Invalid custom path coordinate");
                    command.points[j] = (float) value;
                }
            }
            path.commands.add(command);
        }
        return path;
    }

    private static OfficeDocument.GradientFill gradient(JSONObject json) throws JSONException {
        if (json == null) return null;
        JSONArray colors = json.getJSONArray("colors");
        JSONArray positions = json.getJSONArray("positions");
        if (colors.length() < 2 || colors.length() != positions.length() || colors.length() > 16) {
            throw new JSONException("Invalid gradient stops");
        }
        OfficeDocument.GradientFill gradient = new OfficeDocument.GradientFill();
        gradient.colors = new int[colors.length()]; gradient.positions = new float[positions.length()];
        for (int i = 0; i < colors.length(); i++) {
            gradient.colors[i] = (int) colors.getLong(i);
            gradient.positions[i] = (float) positions.getDouble(i);
            if (Float.isNaN(gradient.positions[i]) || gradient.positions[i] < 0 || gradient.positions[i] > 1 || i > 0 && gradient.positions[i] < gradient.positions[i - 1]) {
                throw new JSONException("Invalid gradient position");
            }
        }
        gradient.points = coordinates(json.getJSONArray("points"), 4, 200000);
        if (!json.isNull("transform")) {
            gradient.transform = coordinates(json.getJSONArray("transform"), 6, Float.MAX_VALUE);
        }
        return gradient;
    }

    private static float[] coordinates(JSONArray array, int count, float limit) throws JSONException {
        if (array.length() != count) throw new JSONException("Invalid geometry coordinate count");
        float[] result = new float[count];
        for (int i = 0; i < count; i++) {
            double value = array.getDouble(i);
            if (Double.isNaN(value) || Double.isInfinite(value) || Math.abs(value) > limit) {
                throw new JSONException("Invalid geometry coordinate");
            }
            result[i] = (float) value;
        }
        return result;
    }

    private static List<OfficeDocument.Paragraph> paragraphs(JSONArray array) throws JSONException {
        List<OfficeDocument.Paragraph> paragraphs = new ArrayList<>();
        for (int i = 0; i < array.length(); i++) {
            JSONObject p = array.getJSONObject(i);
            OfficeDocument.Paragraph paragraph = new OfficeDocument.Paragraph();
            paragraph.alignment = p.getInt("alignment"); paragraph.before = (float) p.getDouble("before");
            paragraph.after = (float) p.getDouble("after"); paragraph.indent = (float) p.getDouble("indent");
            paragraph.rightIndent = (float) p.getDouble("rightIndent");
            paragraph.firstLineIndent = (float) p.getDouble("firstLineIndent");
            paragraph.lineSpacingRule = OfficeDocument.LineSpacingRule.valueOf(p.getString("lineSpacingRule"));
            paragraph.lineSpacing = (float) p.getDouble("lineSpacing");
            paragraph.bullet = p.isNull("bullet") ? "" : p.getString("bullet");
            JSONArray runs = p.getJSONArray("runs");
            for (int j = 0; j < runs.length(); j++) {
                JSONObject r = runs.getJSONObject(j);
                OfficeDocument.Run run = new OfficeDocument.Run();
                run.text = r.getString("text"); run.size = (float) r.getDouble("size");
                run.fontFace = r.optString("fontFace", "");
                run.bold = r.getBoolean("bold"); run.italic = r.getBoolean("italic");
                run.underline = r.getBoolean("underline"); run.color = (int) r.getLong("color");
                paragraph.runs.add(run);
            }
            paragraphs.add(paragraph);
        }
        return paragraphs;
    }
}
