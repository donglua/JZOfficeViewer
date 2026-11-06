package cn.jingzhuan.lib.office.widget;

import android.content.Context;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.util.AttributeSet;
import android.view.Gravity;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import cn.jingzhuan.lib.office.OfficePreviewView;

/**
 * 标准化多工作表切换标签栏（XLSX Sheet Tabs）。
 * 支持通过 {@link #attachTo(OfficePreviewView)} 与文档预览视图双向联动绑定。
 */
public class OfficeSheetTabs extends HorizontalScrollView {

    private final LinearLayout tabsLayout;
    private OfficePreviewView attachedPreview;
    private OfficePreviewView.OnPageChangeListener pageChangeListener;
    private List<String> currentNames = Collections.emptyList();
    private int selectedIndex = -1;

    private int selectedTextColor = 0xff176b43;
    private int normalTextColor = 0xff4a5159;
    private int selectedTabBgColor = 0xffe0efe6;
    private int normalTabBgColor = 0xfff4f5f7;

    public OfficeSheetTabs(Context context) {
        this(context, null);
    }

    public OfficeSheetTabs(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public OfficeSheetTabs(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        setHorizontalScrollBarEnabled(false);
        setBackgroundColor(normalTabBgColor);
        tabsLayout = new LinearLayout(context);
        tabsLayout.setOrientation(LinearLayout.HORIZONTAL);
        addView(tabsLayout, new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.MATCH_PARENT));
        setVisibility(GONE);
    }

    /**
     * 将标签栏与 OfficePreviewView 双向绑定。
     * 当加载 XLSX 文档时自动显示标签栏，并监听切换动作；非 XLSX 时自动隐藏。
     */
    public void attachTo(OfficePreviewView preview) {
        if (this.attachedPreview == preview) {
            syncWithPreview();
            return;
        }
        detach();
        this.attachedPreview = preview;
        if (preview != null) {
            this.pageChangeListener = (pageNumber, pageCount) -> syncWithPreview();
            preview.addOnPageChangeListener(this.pageChangeListener);
            syncWithPreview();
        }
    }

    /**
     * 解绑当前关联的 OfficePreviewView 并清空标签。
     */
    public void detach() {
        if (attachedPreview != null && pageChangeListener != null) {
            attachedPreview.removeOnPageChangeListener(pageChangeListener);
        }
        attachedPreview = null;
        pageChangeListener = null;
        currentNames = Collections.emptyList();
        tabsLayout.removeAllViews();
        selectedIndex = -1;
        setVisibility(GONE);
    }

    @Override
    protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (attachedPreview != null && pageChangeListener != null) {
            attachedPreview.addOnPageChangeListener(pageChangeListener);
            syncWithPreview();
        }
    }

    @Override
    protected void onDetachedFromWindow() {
        super.onDetachedFromWindow();
        if (attachedPreview != null && pageChangeListener != null) {
            attachedPreview.removeOnPageChangeListener(pageChangeListener);
        }
    }

    private void syncWithPreview() {
        if (attachedPreview == null) return;
        List<String> names = attachedPreview.getSheetNames();
        if (names == null || names.isEmpty()) {
            setVisibility(GONE);
            currentNames = Collections.emptyList();
            tabsLayout.removeAllViews();
            selectedIndex = -1;
        } else {
            if (!names.equals(currentNames)) {
                bindSheetNames(names);
            }
            selectTab(attachedPreview.getCurrentPage() - 1);
        }
    }

    /**
     * 自定义标签选中与未选中的样式颜色。
     */
    public void setTabColors(int selectedTextColor, int normalTextColor, int selectedTabBgColor, int normalTabBgColor) {
        this.selectedTextColor = selectedTextColor;
        this.normalTextColor = normalTextColor;
        this.selectedTabBgColor = selectedTabBgColor;
        this.normalTabBgColor = normalTabBgColor;
        setBackgroundColor(normalTabBgColor);
        refreshTabStyles();
    }

    private void bindSheetNames(List<String> names) {
        this.currentNames = new ArrayList<>(names);
        tabsLayout.removeAllViews();
        setVisibility(names.isEmpty() ? GONE : VISIBLE);

        for (int i = 0; i < names.size(); i++) {
            final int number = i + 1;
            TextView tab = new TextView(getContext());
            tab.setText(names.get(i));
            tab.setTextSize(14);
            tab.setGravity(Gravity.CENTER);
            tab.setSingleLine(true);
            tab.setEllipsize(TextUtils.TruncateAt.END);
            tab.setMaxWidth(dp(180));
            tab.setMinWidth(dp(72));
            tab.setPadding(dp(16), 0, dp(16), 0);
            tab.setContentDescription(names.get(i));
            tab.setFocusable(true);
            tab.setOnClickListener(v -> {
                if (attachedPreview != null) {
                    attachedPreview.selectSheet(number);
                }
            });
            tabsLayout.addView(tab, new LinearLayout.LayoutParams(LayoutParams.WRAP_CONTENT, dp(48)));
        }
        refreshTabStyles();
    }

    private void selectTab(int index) {
        if (index == selectedIndex) return;
        selectedIndex = index;
        refreshTabStyles();
    }

    private void refreshTabStyles() {
        for (int i = 0; i < tabsLayout.getChildCount(); i++) {
            TextView tab = (TextView) tabsLayout.getChildAt(i);
            boolean active = i == selectedIndex;
            tab.setSelected(active);
            tab.setTextColor(active ? selectedTextColor : normalTextColor);
            tab.setTypeface(null, active ? Typeface.BOLD : Typeface.NORMAL);
            tab.setBackgroundColor(active ? selectedTabBgColor : normalTabBgColor);
            if (active) {
                tab.post(() -> smoothScrollTo(Math.max(0, tab.getLeft() - dp(16)), 0));
            }
        }
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }
}
