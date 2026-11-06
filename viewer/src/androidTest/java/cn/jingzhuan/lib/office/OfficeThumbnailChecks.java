package cn.jingzhuan.lib.office;

import android.content.Context;
import android.graphics.Bitmap;
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

final class OfficeThumbnailChecks {
    private static final String DOCUMENT = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        + "<w:body><w:p><w:r><w:t>Thumbnail test</w:t></w:r></w:p></w:body></w:document>";

    private OfficeThumbnailChecks() { }

    static String run(Context context) throws Exception {
        File file = File.createTempFile("thumbnail-check-", ".docx", context.getCacheDir());
        try {
            byte[] data = docxFixture(DOCUMENT);
            try (FileOutputStream out = new FileOutputStream(file)) {
                out.write(data);
            }

            Uri uri = Uri.fromFile(file);

            // 1. 同步解码测试
            Bitmap thumbnail = OfficeThumbnail.decode(context, uri, 200, 200);
            if (thumbnail == null) {
                throw new AssertionError("OfficeThumbnail.decode returned null");
            }
            if (thumbnail.getWidth() <= 0 || thumbnail.getHeight() <= 0) {
                throw new AssertionError("Thumbnail has invalid dimensions: " + thumbnail.getWidth() + "x" + thumbnail.getHeight());
            }
            if (thumbnail.getWidth() > 200 || thumbnail.getHeight() > 200) {
                throw new AssertionError("Thumbnail exceeded maximum boundary: " + thumbnail.getWidth() + "x" + thumbnail.getHeight());
            }
            thumbnail.recycle();

            // 2. 异步加载测试
            CountDownLatch latch = new CountDownLatch(1);
            AtomicReference<Bitmap> asyncBitmap = new AtomicReference<>();
            AtomicReference<Exception> asyncError = new AtomicReference<>();

            OfficeThumbnail.load(context, uri, 150, 150, new OfficeThumbnail.Callback() {
                @Override
                public void onSuccess(Bitmap bmp) {
                    asyncBitmap.set(bmp);
                    latch.countDown();
                }

                @Override
                public void onError(Exception error) {
                    asyncError.set(error);
                    latch.countDown();
                }
            });

            if (!latch.await(5, TimeUnit.SECONDS)) {
                throw new AssertionError("OfficeThumbnail.load timed out");
            }
            if (asyncError.get() != null) {
                throw new AssertionError("OfficeThumbnail.load failed: " + asyncError.get().getMessage());
            }
            Bitmap asyncResult = asyncBitmap.get();
            if (asyncResult == null || asyncResult.getWidth() <= 0) {
                throw new AssertionError("OfficeThumbnail.load returned invalid bitmap");
            }
            asyncResult.recycle();

            // 3. 非法参数校验
            try {
                OfficeThumbnail.decode(null, uri, 100, 100);
                throw new AssertionError("decode(null, uri) should throw IllegalArgumentException");
            } catch (IllegalArgumentException ignored) { }

            try {
                OfficeThumbnail.decode(context, null, 100, 100);
                throw new AssertionError("decode(context, null) should throw IllegalArgumentException");
            } catch (IllegalArgumentException ignored) { }

            try {
                OfficeThumbnail.decode(context, uri, 0, 100);
                throw new AssertionError("decode with targetWidth=0 should throw IllegalArgumentException");
            } catch (IllegalArgumentException ignored) { }

            try {
                OfficeThumbnail.decode(context, uri, 100, -1);
                throw new AssertionError("decode with targetHeight=-1 should throw IllegalArgumentException");
            } catch (IllegalArgumentException ignored) { }

            return "PASS OfficeThumbnailChecks synchronous and asynchronous thumbnail rendering passed\n";
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
