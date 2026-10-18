package cn.jingzhuan.lib.office;

import java.io.IOException;
import java.util.Arrays;

public final class DocumentDecoderChecks {
    private static int passed;

    public static void main(String[] args) throws Exception {
        checkSpreadsheetDecodeAndValidation();
        checkPptxAndDocxWithOmittedFields();
        checkGeometryAndPathValidation();
        checkEscapesAndOutOfOrderKeys();
        System.out.println("PASS DocumentDecoderChecks (" + passed + " assertions)");
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
        check("".equals(el.paragraphs.get(0).runs.get(0).fontFace), "omitted fontFace defaults to empty string");
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
