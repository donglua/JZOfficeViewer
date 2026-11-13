package cn.jingzhuan.lib.office;

public final class OfficeMetadataChecks {
    private static int passed;

    public static void main(String[] args) throws Exception {
        checkDocxMetadata();
        checkPptxMetadata();
        checkXlsxMetadata();
        checkProtocolGuards();
        checkNullGuards();
        System.out.println("PASS OfficeMetadataChecks (" + passed + " assertions)");
    }

    /** core 元数据协议：只携带元数据字段，不含行列与样式 */
    private static String metadataJson(String kind, int pageCount, float width, float height,
            String sheetNames, String warnings) {
        return "{\"schemaVersion\":9,\"kind\":\"" + kind + "\",\"pageCount\":" + pageCount
            + ",\"width\":" + width + ",\"height\":" + height
            + ",\"sheetNames\":" + sheetNames + ",\"warnings\":" + warnings + "}";
    }

    private static void checkProtocolGuards() {
        try {
            OfficeMetadata meta = MetadataDecoder.decode(metadataJson("DOCX", 1, 595, 0, "[]", "[]"));
            check(meta.pageCount == 1 && meta.width == 595f, "Protocol decodes required fields");
            check(meta.sheetNames.isEmpty() && meta.warnings.isEmpty(), "Protocol empty lists decode");
        } catch (Exception error) {
            throw new AssertionError("Valid metadata rejected: " + error, error);
        }
        reject("{\"schemaVersion\":8,\"kind\":\"DOCX\",\"pageCount\":1,\"width\":1,\"height\":0,"
            + "\"sheetNames\":[],\"warnings\":[]}", "Unsupported core model version");
        reject("{\"kind\":\"DOCX\",\"pageCount\":1,\"width\":1,\"height\":0,"
            + "\"sheetNames\":[],\"warnings\":[]}", null);
        reject(metadataJson("DOCX", 1, -5, 0, "[]", "[]"), null);
        reject(metadataJson("DOCX", -1, 5, 0, "[]", "[]"), null);
        reject(metadataJson("DOCX", 1, 5, 0, "[]", "[]").replace("\"height\":0", "\"height\":1e40"), null);
    }

    private static void reject(String json, String expectedMessage) {
        try {
            MetadataDecoder.decode(json);
            throw new AssertionError("Accepted invalid metadata: " + json);
        } catch (Exception error) {
            if (expectedMessage != null && !expectedMessage.equals(error.getMessage())) {
                throw new AssertionError("Unexpected rejection message: " + error.getMessage());
            }
            passed++;
        }
    }

    private static void checkDocxMetadata() throws Exception {
        OfficeMetadata meta = MetadataDecoder.decode(
            metadataJson("DOCX", 1, 595.0f, 0, "[]", "[\"test warning\"]"));
        check("DOCX".equals(meta.format), "DOCX format matches");
        check(meta.pageCount == 1, "DOCX pageCount is 1");
        check(meta.sheetNames.isEmpty(), "DOCX has no sheet names");
        check(meta.width == 595.0f, "DOCX width matches");
        check(meta.warnings.size() == 1 && meta.warnings.get(0).equals("test warning"), "DOCX warnings match");
    }

    private static void checkPptxMetadata() throws Exception {
        OfficeMetadata meta = MetadataDecoder.decode(metadataJson("PPTX", 2, 960.0f, 540.0f, "[]", "[]"));
        check("PPTX".equals(meta.format), "PPTX format matches");
        check(meta.pageCount == 2, "PPTX pageCount is 2");
        check(meta.sheetNames.isEmpty(), "PPTX has no sheet names");
        check(meta.width == 960.0f, "PPTX width matches");
        check(meta.height == 540.0f, "PPTX height matches page 0");
    }

    private static void checkXlsxMetadata() throws Exception {
        OfficeMetadata meta = MetadataDecoder.decode(
            metadataJson("XLSX", 2, 1.0f, 0, "[\"Summary\",\"Details\"]", "[]"));
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
