package cn.jingzhuan.lib.office;

import android.accessibilityservice.AccessibilityService;
import android.view.accessibility.AccessibilityEvent;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;

/** 测试专用读屏探针：订阅与 TalkBack 完全相同的无障碍事件流，端到端验证播报送达 */
public final class AccessibilityEventProbe extends AccessibilityService {
    static final AtomicBoolean bound = new AtomicBoolean();
    static final List<String> announcements = new CopyOnWriteArrayList<>();

    @Override protected void onServiceConnected() {
        bound.set(true);
    }

    @Override public void onAccessibilityEvent(AccessibilityEvent event) {
        if (event.getEventType() != AccessibilityEvent.TYPE_ANNOUNCEMENT) return;
        StringBuilder text = new StringBuilder();
        for (CharSequence part : event.getText()) text.append(part);
        if (text.length() > 0) announcements.add(event.getPackageName() + "|" + text);
    }

    @Override public void onInterrupt() { }
}
