package cn.jingzhuan.lib.office;

import java.io.IOException;

final class NativeCore {
    static { System.loadLibrary("jz_office"); }
    static native String parse(String cachedPath) throws IOException;
    /** 首屏范围解析：只排版首页/首张幻灯片/首个工作表，用于封面缩略图 */
    static native String parseFirstViewport(String cachedPath) throws IOException;
    /** 轻量元数据速读：只读取格式与页数所需的部件 */
    static native String metadata(String cachedPath) throws IOException;
    /**
     * 可选地预热全文检索索引；默认解析不调用此方法，首次搜索会按需构建。
     * 调用方应仅在确认即将搜索且位于后台线程时调用。
     */
    static native void prewarmSearchIndex(String cachedPath) throws IOException;
    static native String search(String cachedPath, String query) throws IOException;
}
