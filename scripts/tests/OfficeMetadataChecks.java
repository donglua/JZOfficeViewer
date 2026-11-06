package cn.jingzhuan.lib.office;

import java.util.Arrays;

public final class OfficeMetadataChecks {
    private static int passed;

    public static void main(String[] args) throws Exception {
        checkDocxMetadata();
        checkPptxMetadata();
        checkXlsxMetadata();
        checkNullGuards();
        System.out.println("PASS OfficeMetadataChecks (" + passed + " assertions)");
    }

    private static void checkDocxMetadata() throws Exception {
        String json = "{\"schemaVersion\":9,\"kind\":\"DOCX\",\"width\":595.0,\"warnings\":[\"test warning\"],\"blocks\":[],\"pages\":[],\"sheets\":[],\"cellStyles\":[]}";
        OfficeDocument doc = DocumentDecoder.decode(json);
        OfficeMetadata meta = OfficeMetadata.fromDocument(doc);
        check("DOCX".equals(meta.format), "DOCX format matches");
        check(meta.pageCount == 1, "DOCX pageCount is 1");
        check(meta.sheetNames.isEmpty(), "DOCX has no sheet names");
        check(meta.width == 595.0f, "DOCX width matches");
        check(meta.warnings.size() == 1 && meta.warnings.get(0).equals("test warning"), "DOCX warnings match");
    }

    private static void checkPptxMetadata() throws Exception {
        String json = "{\"schemaVersion\":9,\"kind\":\"PPTX\",\"width\":960.0,\"warnings\":[],\"blocks\":[],"
            + "\"pages\":[{\"width\":960.0,\"height\":540.0,\"background\":-1,\"elements\":[]},"
            + "{\"width\":960.0,\"height\":540.0,\"background\":-1,\"elements\":[]}],"
            + "\"sheets\":[],\"cellStyles\":[]}";
        OfficeDocument doc = DocumentDecoder.decode(json);
        OfficeMetadata meta = OfficeMetadata.fromDocument(doc);
        check("PPTX".equals(meta.format), "PPTX format matches");
        check(meta.pageCount == 2, "PPTX pageCount is 2");
        check(meta.sheetNames.isEmpty(), "PPTX has no sheet names");
        check(meta.width == 960.0f, "PPTX width matches");
        check(meta.height == 540.0f, "PPTX height matches page 0");
    }

    private static void checkXlsxMetadata() throws Exception {
        String json = "{\"schemaVersion\":9,\"kind\":\"XLSX\",\"width\":1.0,\"warnings\":[],\"blocks\":[],\"pages\":[],"
            + "\"cellStyles\":[{\"fontSize\":11,\"bold\":false,\"italic\":false,\"underline\":false,\"color\":0,\"fill\":0,\"alignment\":3,\"verticalAlignment\":\"BOTTOM\",\"wrap\":false,\"borders\":[null,null,null,null]}],"
            + "\"sheets\":[{\"name\":\"Summary\",\"rowHeights\":[20],\"columnWidths\":[10],\"cells\":[],\"merges\":[]},"
            + "{\"name\":\"Details\",\"rowHeights\":[20],\"columnWidths\":[10],\"cells\":[],\"merges\":[]}]}";
        OfficeDocument doc = DocumentDecoder.decode(json);
        OfficeMetadata meta = OfficeMetadata.fromDocument(doc);
        check("XLSX".equals(meta.format), "XLSX format matches");
        check(meta.pageCount == 2, "XLSX pageCount is 2");
        check(meta.sheetNames.size() == 2, "XLSX has 2 sheets");
        check("Summary".equals(meta.sheetNames.get(0)), "First sheet is Summary");
        check("Details".equals(meta.sheetNames.get(1)), "Second sheet is Details");
    }

    private static void checkNullGuards() {
        try {
            OfficeMetadata.fromDocument(null);
            throw new AssertionError("fromDocument(null) should throw");
        } catch (IllegalArgumentException expected) {
            passed++;
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
        passed++;
    }
}
