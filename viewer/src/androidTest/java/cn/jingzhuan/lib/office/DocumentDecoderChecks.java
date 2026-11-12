package cn.jingzhuan.lib.office;

import java.io.IOException;
import java.util.Arrays;

public final class DocumentDecoderChecks {
    private static int passed;

    public static void main(String[] args) throws Exception {
        checkSpreadsheetDecodeAndValidation();
        checkPptxAndDocxWithOmittedFields();
        checkTypographyAndStyleFields();
        checkParagraphShadingAndBorders();
        checkGeometryAndPathValidation();
        checkEscapesAndOutOfOrderKeys();
        checkSheetGeometryValidation();
        checkLargeGeometryArrays();
        checkSearchMatchesDecodeAndValidation();
        System.out.println("PASS DocumentDecoderChecks (" + passed + " assertions)");
    }

    private static void checkSearchMatchesDecodeAndValidation() throws Exception {
        String json = "["
            + "{\"pageIndex\":0,\"elementIndex\":2,\"paragraphIndex\":1,\"startChar\":5,\"endChar\":9,\"snippet\":\"...2026财务报表...\"},"
            + "{\"pageIndex\":1,\"elementIndex\":4,\"paragraphIndex\":0,\"row\":3,\"column\":2,\"startChar\":0,\"endChar\":4,\"snippet\":\"Cell text\"}"
            + "]";
        java.util.List<OfficeDocument.SearchMatch> matches = DocumentDecoder.decodeSearchMatches(json);
        check(matches.size() == 2, "search matches count");
        OfficeDocument.SearchMatch m0 = matches.get(0);
        check(m0.pageIndex == 0 && m0.elementIndex == 2 && m0.paragraphIndex == 1, "m0 indices");
        check(m0.row == -1 && m0.column == -1, "m0 omitted row/column default to -1");
        check(m0.startChar == 5 && m0.endChar == 9 && "...2026财务报表...".equals(m0.snippet), "m0 offsets & snippet");
        OfficeDocument.SearchMatch m1 = matches.get(1);
        check(m1.row == 3 && m1.column == 2 && m1.startChar == 0 && m1.endChar == 4, "m1 row/column & offsets");

        check(DocumentDecoder.decodeSearchMatches("[]").isEmpty(), "empty search matches array");
        rejectSearch(null, "null search json");
        rejectSearch("[{\"pageIndex\":0}]", "missing required search match fields");
        rejectSearch("[{\"pageIndex\":0,\"elementIndex\":0,\"paragraphIndex\":0,\"startChar\":8,\"endChar\":4,\"snippet\":\"x\"}]",
            "endChar before startChar");
    }

    private static void rejectSearch(String json, String label) {
        try {
            DocumentDecoder.decodeSearchMatches(json);
        } catch (IOException expected) {
            check("Invalid core search result".equals(expected.getMessage()), label + " message: " + expected.getMessage());
            return;
        }
        throw new AssertionError("Expected search rejection for: " + label);
    }

    private static void checkSheetGeometryValidation() throws Exception {
        String head = "{\"schemaVersion\":9,\"kind\":\"XLSX\",\"width\":1,\"warnings\":[],\"blocks\":[],\"pages\":[],"
            + "\"cellStyles\":[{\"fontSize\":11,\"bold\":false,\"italic\":false,\"underline\":false,\"color\":0,"
            + "\"fill\":0,\"alignment\":3,\"verticalAlignment\":\"BOTTOM\",\"wrap\":false,\"borders\":[null,null,null,null]}],"
            + "\"sheets\":[{\"name\":\"S\",\"rowHeights\":[20,20],\"columnWidths\":[10,10],"
            + "\"cells\":[{\"row\":0,\"column\":0,\"text\":\"a\",\"style\":0,\"numeric\":false}],"
            + "\"merges\":[{\"startRow\":0,\"startColumn\":0,\"endRow\":0,\"endColumn\":1}],";
        String good = "\"columnOffsets\":[0,10,20],\"rowOffsets\":[0,20,40],\"columnVisible\":[0,1],"
            + "\"rowVisible\":[0,1],\"rowStarts\":[0,1,1],\"mergedCells\":[true],"
            + "\"mergeRects\":[{\"left\":0,\"top\":0,\"right\":20,\"bottom\":20,\"anchor\":0,\"startRow\":0,\"endRow\":0}]";
        OfficeDocument decoded = DocumentDecoder.decode(head + "\"geometry\":{" + good + "}}]}");
        SpreadsheetDocument.Geometry geometry = decoded.sheets.get(0).geometry;
        check(geometry != null && geometry.rowStarts[2] == 1, "sheet geometry decoded");
        check(geometry.mergedCells.length == 1 && geometry.mergedCells[0], "geometry merge flags decoded");
        check(geometry.mergeRects.get(0).startRow == 0 && geometry.mergeRects.get(0).endRow == 0, "geometry merge rows decoded");

        OfficeDocument missingAnchor = DocumentDecoder.decode(
            head + "\"geometry\":{" + good.replace("\"anchor\":0", "\"anchor\":-1") + "}}]}");
        check(missingAnchor.sheets.get(0).geometry.mergeRects.get(0).anchor == -1, "missing merge anchor -1 decoded");
        OfficeDocument legacyMissingAnchor = DocumentDecoder.decode(
            head + "\"geometry\":{" + good.replace("\"anchor\":0", "\"anchor\":4294967295") + "}}]}");
        check(legacyMissingAnchor.sheets.get(0).geometry.mergeRects.get(0).anchor == -1,
            "legacy u32::MAX merge anchor normalized to -1");

        reject(head + "\"geometry\":{}" + "}]}", "Invalid core display model", "geometry without arrays");
        reject(head + "\"geometry\":{" + good.replace("[0,10,20]", "[]") + "}}]}",
            "Invalid core display model", "empty column offsets");
        reject(head + "\"geometry\":{" + good.replace("\"rowStarts\":[0,1,1]", "\"rowStarts\":[0,1]") + "}}]}",
            "Invalid core display model", "row starts length");
        reject(head + "\"geometry\":{" + good.replace("\"rowStarts\":[0,1,1]", "\"rowStarts\":[0,1,0]") + "}}]}",
            "Invalid core display model", "non-monotonic row starts");
        reject(head + "\"geometry\":{" + good.replace("[0,10,20]", "[0,20,10]") + "}}]}",
            "Invalid core display model", "non-monotonic offsets");
        reject(head + "\"geometry\":{" + good.replace("\"mergedCells\":[true]", "\"mergedCells\":[true,false]") + "}}]}",
            "Invalid core display model", "merge flag length");
        reject(head + "\"geometry\":{" + good.replace("\"columnVisible\":[0,1]", "\"columnVisible\":[0,2]") + "}}]}",
            "Invalid core display model", "visible index out of bounds");
        reject(head + "\"geometry\":{" + good.replace("\"anchor\":0", "\"anchor\":1") + "}}]}",
            "Invalid core display model", "merge anchor out of bounds");
        reject(head + "\"geometry\":{" + good.replace("\"anchor\":0", "\"anchor\":-2") + "}}]}",
            "Invalid core display model", "merge anchor below -1");
        reject(head + "\"geometry\":{" + good.replace("\"anchor\":0", "\"anchor\":0.5") + "}}]}",
            "Invalid core display model", "fractional merge anchor");
        reject(head + "\"geometry\":{" + good.replace("\"endRow\":0", "\"endRow\":2") + "}}]}",
            "Invalid core display model", "merge rect row out of bounds");
    }

    private static void checkLargeGeometryArrays() throws Exception {
        int rows = 300;
        StringBuilder rowHeights = new StringBuilder("[");
        StringBuilder rowOffsets = new StringBuilder("[0");
        StringBuilder rowVisible = new StringBuilder("[");
        StringBuilder rowStarts = new StringBuilder("[");
        StringBuilder mergedCells = new StringBuilder("[");
        StringBuilder cells = new StringBuilder("[");
        float total = 0;
        for (int row = 0; row < rows; row++) {
            String comma = row == 0 ? "" : ",";
            rowHeights.append(comma).append(20);
            rowVisible.append(comma).append(row);
            rowStarts.append(comma).append(row);
            mergedCells.append(comma).append(row == 0);
            cells.append(comma)
                .append("{\"row\":").append(row).append(",\"column\":0,\"text\":\"r\",\"style\":0,\"numeric\":false}");
            total += 20;
            rowOffsets.append(',').append(total);
        }
        rowHeights.append(']');
        rowOffsets.append(']');
        rowVisible.append(']');
        rowStarts.append(',').append(rows).append(']');
        mergedCells.append(']');
        cells.append(']');
        String json = "{\"schemaVersion\":9,\"kind\":\"XLSX\",\"width\":1,\"warnings\":[],\"blocks\":[],\"pages\":[],"
            + "\"cellStyles\":[{\"fontSize\":11,\"bold\":false,\"italic\":false,\"underline\":false,\"color\":0,"
            + "\"fill\":0,\"alignment\":3,\"verticalAlignment\":\"BOTTOM\",\"wrap\":false,\"borders\":[null,null,null,null]}],"
            + "\"sheets\":[{\"name\":\"S\",\"rowHeights\":" + rowHeights
            + ",\"columnWidths\":[10],\"cells\":" + cells + ",\"merges\":[],"
            + "\"geometry\":{\"columnOffsets\":[0,10],\"rowOffsets\":" + rowOffsets
            + ",\"columnVisible\":[0],\"rowVisible\":" + rowVisible
            + ",\"rowStarts\":" + rowStarts + ",\"mergedCells\":" + mergedCells + ",\"mergeRects\":[]}}]}";
        SpreadsheetDocument.Geometry geometry = DocumentDecoder.decode(json).sheets.get(0).geometry;
        check(geometry.rowOffsets.length == rows + 1 && geometry.rowOffsets[rows] == total, "large offsets array");
        check(geometry.rowStarts.length == rows + 1 && geometry.rowStarts[rows] == rows, "large row starts array");
        check(geometry.mergedCells.length == rows && geometry.mergedCells[0] && !geometry.mergedCells[rows - 1],
            "large merged flag array");
        check(geometry.rowVisible.length == rows && geometry.rowVisible[rows - 1] == rows - 1, "large visible index array");
        check(geometry.columnOffsets.length == 2 && geometry.columnVisible.length == 1, "small arrays stay exact");
    }

    private static void checkSpreadsheetDecodeAndValidation() throws Exception {
        String json = "{\"schemaVersion\":9,\"kind\":\"XLSX\",\"width\":595,\"warnings\":[\"w1\"],\"blocks\":[],\"pages\":[],"
            + "\"cellStyles\":[{\"fontSize\":13,\"bold\":true,\"italic\":true,\"underline\":true,\"color\":4279385946,"
            + "\"fill\":4294967295,\"alignment\":3,\"verticalAlignment\":\"BOTTOM\",\"wrap\":true,"
            + "\"borders\":[4278190335,null,4278190335,null]}],"
            + "\"sheets\":[{\"name\":\"Sheet 1\",\"rowHeights\":[28,0,36],\"columnWidths\":[80,0,100],"
            + "\"cells\":[{\"row\":0,\"column\":0,\"text\":\"123.45\",\"style\":0,\"numeric\":true}],"
            + "\"merges\":[{\"startRow\":0,\"startColumn\":0,\"endRow\":2,\"endColumn\":2}]}]}";
        OfficeDocument doc = DocumentDecoder.decode(json);
        SpreadsheetDocument.Sheet sheet = doc.sheets.get(0);
        SpreadsheetDocument.CellStyle style = doc.cellStyles.get(0);
        check(doc.kind == OfficeDocument.Kind.XLSX && "Sheet 1".equals(sheet.name), "XLSX kind & name");
        check(doc.warnings.size() == 1 && "w1".equals(doc.warnings.get(0)), "warnings decoded");
        check(sheet.rowHeights[1] == 0 && sheet.columnWidths[1] == 0, "hidden dimensions retained");
        check(sheet.cells.size() == 1 && sheet.cells.get(0).numeric && "123.45".equals(sheet.cells.get(0).text), "cell decoded");
        check(style.fill == 0xffffffff && style.bold && style.italic && style.underline && style.wrap, "cell style decoded");
        check(style.borders[0] != null && style.borders[0] == 0xff0000ff && style.borders[1] == null, "borders decoded");
        check(sheet.merges.get(0).endRow == 2 && sheet.merges.get(0).endColumn == 2, "merge decoded");

        reject(json.replace("\"schemaVersion\":9", "\"schemaVersion\":8"), "Unsupported core model version", "schema 8");
        reject(json.replace("\"schemaVersion\":9,", ""), "Invalid core display model", "missing schemaVersion");
        reject(json.replace("\"style\":0", "\"style\":1"), "Invalid core display model", "out of range style");
        reject(json.replace("\"row\":0", "\"row\":0.5"), "Invalid core display model", "fractional row");
        reject(json.replace("[28,0,36]", "[-1,0,36]"), "Invalid core display model", "negative dimension");
        reject(json.replace("\"endColumn\":2", "\"endColumn\":3"), "Invalid core display model", "out of range merge");
        reject(json.replace("\"sheets\":[{", "\"sheets\":[],\"extra\":[{"), "Invalid core display model", "XLSX without sheets");
    }

    private static void checkPptxAndDocxWithOmittedFields() throws Exception {
        // Test omitted optional fields on Element, GradientFill, Paragraph, Run
        String pptx = "{\"schemaVersion\":9,\"kind\":\"PPTX\",\"width\":720,\"warnings\":[],\"blocks\":[],"
            + "\"cellStyles\":[],\"sheets\":[],"
            + "\"pages\":[{\"width\":720,\"height\":405,\"background\":4294967295,\"elements\":["
            + "{\"type\":\"TEXT\",\"x\":10,\"y\":20,\"width\":200,\"height\":50,\"padding\":4,"
            + "\"transform\":[1,0,0,1,10,20],\"fill\":0,\"stroke\":0,\"strokeWidth\":1,"
            + "\"verticalAlignment\":\"TOP\",\"textWrap\":true,"
            + "\"fillGradient\":{\"colors\":[4294901760,4278190335],\"positions\":[0,1],\"points\":[0,0,100,100]},"
            + "\"paragraphs\":[{\"alignment\":0,\"before\":0,\"after\":6,\"indent\":0,\"rightIndent\":0,"
            + "\"firstLineIndent\":0,\"lineSpacingRule\":\"AUTO\",\"lineSpacing\":1,"
            + "\"runs\":[{\"text\":\"Hello\",\"size\":14,\"bold\":false,\"italic\":false,\"underline\":false,\"color\":4278190080}]}]}"
            + "]}]}";
        OfficeDocument doc = DocumentDecoder.decode(pptx);
        OfficeDocument.Element el = doc.pages.get(0).elements.get(0);
        check(el.type == OfficeDocument.Type.TEXT, "PPTX element type");
        check(el.fillGradient != null && el.fillGradient.transform == null, "omitted gradient transform is null");
        check(el.imageBounds == null && el.image == null, "omitted imageBounds and image are null");
        check(el.rows.isEmpty() && el.columnWidths.isEmpty() && el.cellFills.isEmpty() && el.paths.isEmpty(), "omitted collections are empty");
        check("".equals(el.paragraphs.get(0).bullet), "omitted bullet defaults to empty string");
        OfficeDocument.Paragraph para0 = el.paragraphs.get(0);
        check(para0.background == 0, "omitted paragraph background defaults to 0");
        check(para0.borderTop == 0 && para0.borderBottom == 0 && para0.borderLeft == 0 && para0.borderRight == 0,
            "omitted borders default to 0");
        check(para0.borderWidth == 0f, "omitted borderWidth defaults to 0");
        OfficeDocument.Run run0 = el.paragraphs.get(0).runs.get(0);
        check("".equals(run0.fontFace), "omitted fontFace defaults to empty string");
        check(!run0.strike, "omitted strike defaults to false");
        check("".equals(run0.vertAlign), "omitted vertAlign defaults to empty string");
        check(run0.spacing == 0f, "omitted spacing defaults to 0");
        check(run0.weight == 0, "omitted weight defaults to 0");
        check(run0.background == 0, "omitted run background defaults to 0");
    }

    private static void checkParagraphShadingAndBorders() throws Exception {
        String json = "{\"schemaVersion\":9,\"kind\":\"DOCX\",\"width\":595,\"warnings\":[],\"blocks\":["
            + "{\"type\":\"TEXT\",\"x\":0,\"y\":0,\"width\":500,\"height\":100,\"padding\":0,"
            + "\"transform\":[1,0,0,1,0,0],\"fill\":0,\"stroke\":0,\"strokeWidth\":0,"
            + "\"verticalAlignment\":\"TOP\",\"textWrap\":true,"
            + "\"paragraphs\":[{\"alignment\":0,\"before\":0,\"after\":0,\"indent\":0,\"rightIndent\":0,"
            + "\"firstLineIndent\":0,\"lineSpacingRule\":\"AUTO\",\"lineSpacing\":1,"
            + "\"background\":4294967040,\"borderTop\":4278190335,\"borderBottom\":4294901760,"
            + "\"borderLeft\":4278255360,\"borderRight\":4294967295,\"borderWidth\":1.5,"
            + "\"runs\":["
            + "{\"text\":\"Highlighted\",\"size\":12,\"bold\":false,\"italic\":false,\"underline\":false,\"color\":0,"
            + "\"background\":4294967040}"
            + "]}]}],\"pages\":[],\"cellStyles\":[],\"sheets\":[]}";
        OfficeDocument doc = DocumentDecoder.decode(json);
        OfficeDocument.Paragraph p = doc.blocks.get(0).paragraphs.get(0);
        check(p.background == (int) 4294967040L, "paragraph background decoded");
        check(p.borderTop == (int) 4278190335L, "paragraph borderTop decoded");
        check(p.borderBottom == (int) 4294901760L, "paragraph borderBottom decoded");
        check(p.borderLeft == (int) 4278255360L, "paragraph borderLeft decoded");
        check(p.borderRight == (int) 4294967295L, "paragraph borderRight decoded");
        check(p.borderWidth == 1.5f, "paragraph borderWidth decoded");

        OfficeDocument.Run r = p.runs.get(0);
        check(r.background == (int) 4294967040L, "run background decoded");

        OfficeDocument.Run copied = r.copy();
        check(copied.background == (int) 4294967040L, "run copy copies background");

        // Verify invalid borderWidth
        OfficeDocument boundary = DocumentDecoder.decode(json.replace("\"borderWidth\":1.5", "\"borderWidth\":1000"));
        check(boundary.blocks.get(0).paragraphs.get(0).borderWidth == 1000f, "borderWidth protocol boundary accepted");
        reject(json.replace("\"borderWidth\":1.5", "\"borderWidth\":-1.0"), "Invalid core display model", "negative borderWidth");
        reject(json.replace("\"borderWidth\":1.5", "\"borderWidth\":1500"), "Invalid core display model", "excessive borderWidth");
        reject(json.replace("\"borderWidth\":1.5", "\"borderWidth\":\"invalid\""), "Invalid core display model", "non-numeric borderWidth");
        reject(json.replace("\"borderWidth\":1.5", "\"borderWidth\":1e3000"), "Invalid core display model", "infinite borderWidth");
    }

    private static void checkTypographyAndStyleFields() throws Exception {
        String baseDoc = "{\"schemaVersion\":9,\"kind\":\"DOCX\",\"width\":595,\"warnings\":[],\"blocks\":["
            + "{\"type\":\"TEXT\",\"x\":0,\"y\":0,\"width\":500,\"height\":100,\"padding\":0,"
            + "\"transform\":[1,0,0,1,0,0],\"fill\":0,\"stroke\":0,\"strokeWidth\":0,"
            + "\"verticalAlignment\":\"TOP\",\"textWrap\":true,"
            + "\"paragraphs\":[{\"alignment\":0,\"before\":0,\"after\":0,\"indent\":0,\"rightIndent\":0,"
            + "\"firstLineIndent\":0,\"lineSpacingRule\":\"AUTO\",\"lineSpacing\":1,\"runs\":["
            + "{\"text\":\"T1\",\"size\":12,\"bold\":false,\"italic\":false,\"underline\":false,\"color\":0,"
            + "\"strike\":true,\"vertAlign\":\"superscript\",\"spacing\":2.5,\"weight\":600},"
            + "{\"text\":\"T2\",\"size\":12,\"bold\":false,\"italic\":false,\"underline\":false,\"color\":0,"
            + "\"strike\":false,\"vertAlign\":\"subscript\",\"spacing\":-1.0,\"weight\":300},"
            + "{\"text\":\"T3\",\"size\":12,\"bold\":false,\"italic\":false,\"underline\":false,\"color\":0,"
            + "\"strike\":false,\"vertAlign\":\"baseline\",\"spacing\":0,\"weight\":400}"
            + "]}]}],\"pages\":[],\"cellStyles\":[],\"sheets\":[]}";
        OfficeDocument doc = DocumentDecoder.decode(baseDoc);
        java.util.List<OfficeDocument.Run> runs = doc.blocks.get(0).paragraphs.get(0).runs;
        check(runs.size() == 3, "runs decoded count");
        check(runs.get(0).strike && "superscript".equals(runs.get(0).vertAlign)
            && runs.get(0).spacing == 2.5f && runs.get(0).weight == 600, "run 0 typography decoded");
        check(!runs.get(1).strike && "subscript".equals(runs.get(1).vertAlign)
            && runs.get(1).spacing == -1.0f && runs.get(1).weight == 300, "run 1 typography decoded");
        check(!runs.get(2).strike && "baseline".equals(runs.get(2).vertAlign)
            && runs.get(2).spacing == 0f && runs.get(2).weight == 400, "run 2 typography decoded");

        // CellStyle with fontFace, strike, vertAlign
        String baseSheet = "{\"schemaVersion\":9,\"kind\":\"XLSX\",\"width\":595,\"warnings\":[],\"blocks\":[],\"pages\":[],"
            + "\"cellStyles\":[{\"fontSize\":11,\"bold\":false,\"italic\":false,\"underline\":false,\"color\":0,"
            + "\"fill\":0,\"alignment\":3,\"verticalAlignment\":\"BOTTOM\",\"wrap\":false,\"borders\":[null,null,null,null],"
            + "\"fontFace\":\"Calibri\",\"strike\":true,\"vertAlign\":\"superscript\"}],"
            + "\"sheets\":[{\"name\":\"S\",\"rowHeights\":[20],\"columnWidths\":[50],"
            + "\"cells\":[{\"row\":0,\"column\":0,\"text\":\"test\",\"style\":0,\"numeric\":false}],\"merges\":[]}]}";
        OfficeDocument sheetDoc = DocumentDecoder.decode(baseSheet);
        SpreadsheetDocument.CellStyle cs = sheetDoc.cellStyles.get(0);
        check("Calibri".equals(cs.fontFace), "cell style fontFace decoded");
        check(cs.strike, "cell style strike decoded");
        check("superscript".equals(cs.vertAlign), "cell style vertAlign decoded");

        // Copy method verification
        OfficeDocument.Run original = runs.get(0);
        OfficeDocument.Run copied = original.copy();
        check(copied.strike == original.strike && copied.vertAlign.equals(original.vertAlign)
            && copied.spacing == original.spacing && copied.weight == original.weight, "run copy copies new fields");

        // Validation errors
        reject(baseDoc.replace("\"vertAlign\":\"superscript\"", "\"vertAlign\":\"invalid\""),
            "Invalid core display model", "invalid run vertAlign");
        reject(baseDoc.replace("\"spacing\":2.5", "\"spacing\":500"),
            "Invalid core display model", "spacing exceeding upper bound");
        reject(baseDoc.replace("\"spacing\":2.5", "\"spacing\":-150"),
            "Invalid core display model", "spacing below lower bound");
        reject(baseDoc.replace("\"weight\":600", "\"weight\":1500"),
            "Invalid core display model", "weight exceeding upper bound");
        reject(baseDoc.replace("\"weight\":600", "\"weight\":-10"),
            "Invalid core display model", "weight negative");
        reject(baseSheet.replace("\"vertAlign\":\"superscript\"", "\"vertAlign\":\"other\""),
            "Invalid core display model", "invalid cellStyle vertAlign");
        StringBuilder longFace = new StringBuilder();
        for (int i = 0; i < 300; i++) longFace.append('a');
        reject(baseSheet.replace("\"Calibri\"", "\"" + longFace + "\""),
            "Invalid core display model", "cellStyle fontFace too long");
    }

    private static void checkGeometryAndPathValidation() throws Exception {
        String base = "{\"schemaVersion\":9,\"kind\":\"PPTX\",\"width\":720,\"warnings\":[],\"blocks\":[],"
            + "\"cellStyles\":[],\"sheets\":[],"
            + "\"pages\":[{\"width\":720,\"height\":405,\"background\":4294967295,\"elements\":["
            + "{\"type\":\"PATH\",\"x\":0,\"y\":0,\"width\":100,\"height\":100,\"padding\":4,"
            + "\"transform\":[1,0,0,1,0,0],\"fill\":0,\"stroke\":0,\"strokeWidth\":1,"
            + "\"verticalAlignment\":\"TOP\",\"textWrap\":true,"
            + "\"imageBounds\":[-20,-10,60,30],"
            + "\"paths\":[{\"fill\":true,\"stroke\":false,\"commands\":["
            + "{\"op\":\"MOVE\",\"points\":[0,0]},{\"op\":\"LINE\",\"points\":[100,50]},{\"op\":\"CLOSE\"}"
            + "]}]}]}]}";
        OfficeDocument doc = DocumentDecoder.decode(base);
        OfficeDocument.Element el = doc.pages.get(0).elements.get(0);
        check(Arrays.equals(el.imageBounds, new float[] {-20, -10, 60, 30}), "imageBounds decoded");
        check(el.paths.size() == 1 && el.paths.get(0).commands.size() == 3, "path commands decoded");

        reject(base.replace("[-20,-10,60,30]", "[10,0,0,10]"), "Invalid core display model", "reversed imageBounds X");
        reject(base.replace("[1,0,0,1,0,0]", "[1,0,0,1,100001,0]"), "Invalid core display model", "transform out of limit");
        reject(base.replace("{\"op\":\"CLOSE\"}", "{\"op\":\"CLOSE\",\"points\":[0,0]}"), "Invalid core display model", "CLOSE with points");
    }

    private static void checkEscapesAndOutOfOrderKeys() throws Exception {
        // Test JSON where sheets appear BEFORE cellStyles and cells appear BEFORE rowHeights/columnWidths
        String reordered = "{\"sheets\":[{\"cells\":[{\"numeric\":false,\"text\":\"Line 1\\n\\\"Quoted\\\" \\u4e2d\\u6587\",\"style\":0,\"column\":0,\"row\":0}],"
            + "\"merges\":[],\"columnWidths\":[100],\"rowHeights\":[24],\"name\":\"S1\"}],"
            + "\"cellStyles\":[{\"borders\":[null,null,null,null],\"wrap\":false,\"verticalAlignment\":\"CENTER\","
            + "\"alignment\":0,\"fill\":0,\"color\":4278190080,\"underline\":false,\"italic\":false,\"bold\":false,\"fontSize\":11}],"
            + "\"pages\":[],\"blocks\":[],\"warnings\":[],\"width\":595,\"kind\":\"XLSX\",\"schemaVersion\":9}";
        OfficeDocument doc = DocumentDecoder.decode(reordered);
        check("Line 1\n\"Quoted\" 中文".equals(doc.sheets.get(0).cells.get(0).text), "escaped string & reordered keys");
    }

    private static void reject(String json, String expectedMessage, String label) {
        try {
            DocumentDecoder.decode(json);
        } catch (IOException expected) {
            check(expectedMessage.equals(expected.getMessage()), label + " message: " + expected.getMessage());
            return;
        }
        throw new AssertionError("Expected rejection for: " + label);
    }

    private static void check(boolean condition, String label) {
        if (!condition) throw new AssertionError("Check failed: " + label);
        passed++;
    }
}
