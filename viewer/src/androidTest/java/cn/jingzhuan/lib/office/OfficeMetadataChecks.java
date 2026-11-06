package cn.jingzhuan.lib.office;

import android.content.Context;
import android.net.Uri;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

final class OfficeMetadataChecks {
    private static final String DOCUMENT = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        + "<w:body><w:p><w:r><w:t>Metadata test</w:t></w:r></w:p></w:body></w:document>";

    private OfficeMetadataChecks() { }

    static String run(Context context) throws Exception {
        File file = File.createTempFile("metadata-check-", ".docx", context.getCacheDir());
        try {
            byte[] data = docxFixture(DOCUMENT);
            try (FileOutputStream out = new FileOutputStream(file)) {
                out.write(data);
            }

            Uri uri = Uri.fromFile(file);
            // 1. 同步读取测试
            OfficeMetadata meta = OfficeMetadata.read(context, uri);
            if (!"DOCX".equals(meta.format)) {
                throw new AssertionError("Expected DOCX format, got " + meta.format);
            }
            if (meta.pageCount != 1) {
                throw new AssertionError("Expected pageCount == 1, got " + meta.pageCount);
            }
            if (!meta.sheetNames.isEmpty()) {
                throw new AssertionError("Expected empty sheet names for DOCX");
            }
            if (meta.width <= 0) {
                throw new AssertionError("Expected positive width");
            }

            // 2. 异步读取测试
            CountDownLatch latch = new CountDownLatch(1);
            AtomicReference<OfficeMetadata> asyncMeta = new AtomicReference<>();
            AtomicReference<Exception> asyncError = new AtomicReference<>();

            OfficeMetadata.readAsync(context, uri, new OfficeMetadata.Callback() {
                @Override
                public void onSuccess(OfficeMetadata metadata) {
                    asyncMeta.set(metadata);
                    latch.countDown();
                }

                @Override
                public void onError(Exception error) {
                    asyncError.set(error);
                    latch.countDown();
                }
            });

            if (!latch.await(5, TimeUnit.SECONDS)) {
                throw new AssertionError("OfficeMetadata.readAsync timed out");
            }
            if (asyncError.get() != null) {
                throw new AssertionError("OfficeMetadata.readAsync failed: " + asyncError.get().getMessage());
            }
            if (asyncMeta.get() == null || !"DOCX".equals(asyncMeta.get().format)) {
                throw new AssertionError("OfficeMetadata.readAsync returned unexpected metadata");
            }

            // 3. 空参数校验
            try {
                OfficeMetadata.read(null, uri);
                throw new AssertionError("read(null, uri) should throw IllegalArgumentException");
            } catch (IllegalArgumentException ignored) { }

            try {
                OfficeMetadata.read(context, null);
                throw new AssertionError("read(context, null) should throw IllegalArgumentException");
            } catch (IllegalArgumentException ignored) { }

            return "PASS OfficeMetadataChecks synchronous and asynchronous read passed\n";
        } finally {
            file.delete();
        }
    }

    private static byte[] docxFixture(String body) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(bytes)) {
            zip.putNextEntry(new ZipEntry("[Content_Types].xml"));
            zip.write(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">\n"
                + "  <Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>\n"
                + "  <Default Extension=\"xml\" ContentType=\"application/xml\"/>\n"
                + "  <Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>\n"
                + "</Types>").getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();

            zip.putNextEntry(new ZipEntry("_rels/.rels"));
            zip.write(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
                + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n"
                + "  <Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>\n"
                + "</Relationships>").getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();

            zip.putNextEntry(new ZipEntry("word/document.xml"));
            zip.write(body.getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();
        }
        return bytes.toByteArray();
    }
}
