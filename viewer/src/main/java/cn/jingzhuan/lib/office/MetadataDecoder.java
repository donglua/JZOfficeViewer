package cn.jingzhuan.lib.office;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/**
 * 轻量元数据协议解码器，对应 core 的 {@code metadata_path_to_json} 输出。
 *
 * 元数据不含任何可绘制内容，因此不复用渲染模型解码器：后者会校验行列、样式与几何，
 * 而元数据协议刻意不携带这些字段。这里只校验自身协议必需的部分。
 */
final class MetadataDecoder {

    private MetadataDecoder() { }

    static OfficeMetadata decode(String json) throws IOException {
        if (json == null) throw new IOException("Invalid core metadata");
        try {
            DocumentDecoder.Cursor c = new DocumentDecoder.Cursor(json);
            boolean hasVersion = false, hasKind = false, hasPages = false;
            boolean hasWidth = false, hasNames = false, hasWarnings = false, hasHeight = false;
            int schemaVersion = 0, pageCount = 0;
            String format = null;
            float width = 0, height = 0;
            List<String> names = new ArrayList<>();
            List<String> warnings = new ArrayList<>();
            c.beginObject();
            while (c.hasNext()) {
                switch (c.nextName()) {
                    case "schemaVersion":
                        schemaVersion = c.nextInt();
                        hasVersion = true;
                        break;
                    case "kind":
                        format = c.nextString();
                        hasKind = true;
                        break;
                    case "pageCount":
                        pageCount = nonNegativeInt(c.nextDouble(), "pageCount");
                        hasPages = true;
                        break;
                    case "width":
                        width = measurement(c.nextDouble(), "width");
                        hasWidth = true;
                        break;
                    case "height":
                        height = measurement(c.nextDouble(), "height");
                        hasHeight = true;
                        break;
                    case "sheetNames":
                        c.beginArray();
                        while (c.hasNext()) {
                            if (names.size() >= 32) throw new IllegalArgumentException("Too many sheet names");
                            names.add(c.nextString());
                        }
                        c.endArray();
                        hasNames = true;
                        break;
                    case "warnings":
                        c.beginArray();
                        while (c.hasNext()) {
                            if (warnings.size() >= 100) throw new IllegalArgumentException("Too many warnings");
                            warnings.add(c.nextString());
                        }
                        c.endArray();
                        hasWarnings = true;
                        break;
                    default:
                        c.skipValue();
                        break;
                }
            }
            c.endObject();
            c.requireEnd();
            if (!hasVersion) throw new IllegalArgumentException("Missing schemaVersion");
            if (schemaVersion != 9) throw new IOException("Unsupported core model version");
            if (!hasKind || !hasPages || !hasWidth || !hasHeight || !hasNames || !hasWarnings) {
                throw new IllegalArgumentException("Missing required metadata fields");
            }
            return new OfficeMetadata(
                format,
                pageCount,
                Collections.unmodifiableList(names),
                Collections.unmodifiableList(warnings),
                width,
                height
            );
        } catch (IOException e) {
            throw e;
        } catch (RuntimeException e) {
            throw new IOException("Invalid core metadata", e);
        }
    }

    /** 尺寸必须有限且非负；上界与渲染模型的坐标上限保持一致 */
    private static float measurement(double value, String name) {
        float result = (float) value;
        if (result < 0 || Float.isNaN(result) || Float.isInfinite(result)) {
            throw new IllegalArgumentException("Invalid metadata " + name);
        }
        return result;
    }

    private static int nonNegativeInt(double value, String name) {
        if (value < 0 || value != Math.rint(value) || value > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("Invalid metadata " + name);
        }
        return (int) value;
    }
}
