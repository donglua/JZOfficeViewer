package cn.jingzhuan.lib.office;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.PopupWindow;
import android.widget.TextView;

/**
 * 选区浮动操作气泡（「复制」/「全选」）。
 *
 * 纯代码构建圆角白底阴影卡片，不依赖 ActionMode 或 AppCompat 主题；气泡不获取焦点、
 * 点击外部不自动关闭，避免抢占键盘焦点或干扰选区手柄拖拽。定位时优先置于选区上方，
 * 上方空间不足则翻转至选区下方，上下都不足（如已全选整屏）则固定在视口顶部安全内边距处。
 */
final class SelectionPopupMenu {
    /** 气泡按钮回调 */
    interface ActionHandler {
        /** 点击「复制」 */
        void onCopy();
        /** 点击「全选」 */
        void onSelectAll();
        /** 气泡展示/隐藏引起的可见性变化，供宿主重绘 */
        void onVisibilityChanged();
    }

    /** 气泡与选区之间的垂直间距 */
    private static final int GAP_DP = 10;
    /** 气泡与宿主视口边缘的最小安全边距 */
    private static final int MARGIN_DP = 8;
    /** 上下空间都不足时，气泡距宿主顶部的距离 */
    private static final int FALLBACK_TOP_DP = 12;

    private final View anchor;
    private final ActionHandler handler;
    private final PopupWindow popup;
    private final LinearLayout card;
    private final TextView copyButton;
    private final TextView selectAllButton;
    private final View divider;
    private final float density;
    private boolean shown;

    SelectionPopupMenu(View anchorView, ActionHandler actionHandler) {
        if (anchorView == null) throw new IllegalArgumentException("anchorView == null");
        if (actionHandler == null) throw new IllegalArgumentException("handler == null");
        anchor = anchorView;
        handler = actionHandler;
        density = anchor.getResources().getDisplayMetrics().density;

        card = new LinearLayout(anchor.getContext());
        card.setOrientation(LinearLayout.HORIZONTAL);
        card.setGravity(Gravity.CENTER_VERTICAL);
        card.setBackground(cardBackground());

        copyButton = button("复制", this::onCopyClicked);
        selectAllButton = button("全选", this::onSelectAllClicked);
        divider = new View(anchor.getContext());
        divider.setBackgroundColor(0xffe0e0e0);
        LinearLayout.LayoutParams dividerParams =
            new LinearLayout.LayoutParams(Math.max(1, dp(0.5f)), dp(20));
        dividerParams.gravity = Gravity.CENTER_VERTICAL;
        divider.setLayoutParams(dividerParams);

        card.addView(copyButton);
        card.addView(divider);
        card.addView(selectAllButton);

        popup = new PopupWindow(card, ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT, false);
        popup.setOutsideTouchable(false);
        popup.setFocusable(false);
        popup.setClippingEnabled(true);
        popup.setElevation(dp(6));
    }

    /** 当前气泡是否已展示 */
    boolean isShowing() {
        return shown;
    }

    /**
     * 依据选区整体屏幕包围框展示气泡。
     *
     * @param screenLeft   选区包围框左边界（宿主局部屏幕坐标）
     * @param screenTop    选区包围框上边界
     * @param screenRight  选区包围框右边界
     * @param screenBottom 选区包围框下边界
     * @param allSelected  已全选时隐藏「全选」按钮
     */
    void show(float screenLeft, float screenTop, float screenRight, float screenBottom,
              boolean allSelected) {
        copyButton.setVisibility(View.VISIBLE);
        selectAllButton.setVisibility(allSelected ? View.GONE : View.VISIBLE);
        divider.setVisibility(allSelected ? View.GONE : View.VISIBLE);

        card.measure(View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED));
        int width = card.getMeasuredWidth();
        int height = card.getMeasuredHeight();
        if (width <= 0 || height <= 0) return;

        int anchorWidth = anchor.getWidth();
        int anchorHeight = anchor.getHeight();
        if (anchorWidth <= 0 || anchorHeight <= 0) return;

        float centerX = (screenLeft + screenRight) / 2f;
        float x = centerX - width / 2f;
        float maxX = anchorWidth - width - dp(MARGIN_DP);
        if (maxX < dp(MARGIN_DP)) maxX = dp(MARGIN_DP);
        x = Math.max(dp(MARGIN_DP), Math.min(maxX, x));

        // 优先置于选区上方，空间不足则翻转到下方，上下都不足则固定在视口顶部
        float above = screenTop - dp(GAP_DP) - height;
        float below = screenBottom + dp(GAP_DP);
        float y;
        if (above >= dp(MARGIN_DP)) {
            y = above;
        } else if (below + height <= anchorHeight - dp(MARGIN_DP)) {
            y = below;
        } else {
            y = dp(FALLBACK_TOP_DP);
        }
        y = Math.max(0, Math.min(anchorHeight - height, y));

        int[] location = new int[2];
        anchor.getLocationInWindow(location);
        int windowX = location[0] + Math.round(x);
        int windowY = location[1] + Math.round(y);

        if (shown) {
            popup.update(windowX, windowY, -1, -1);
        } else {
            popup.showAtLocation(anchor, Gravity.NO_GRAVITY, windowX, windowY);
            shown = true;
            handler.onVisibilityChanged();
        }
    }

    /** 隐藏并释放气泡；重复调用安全 */
    void dismiss() {
        if (popup.isShowing()) popup.dismiss();
        if (!shown) return;
        shown = false;
        handler.onVisibilityChanged();
    }

    /** 宿主销毁时彻底释放，避免窗口泄漏 */
    void release() {
        dismiss();
        popup.setContentView(null);
    }

    private void onCopyClicked() {
        handler.onCopy();
    }

    private void onSelectAllClicked() {
        handler.onSelectAll();
    }

    private TextView button(String label, Runnable action) {
        TextView view = new TextView(anchor.getContext());
        view.setText(label);
        view.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        view.setTextColor(0xff202124);
        view.setContentDescription(label);
        view.setGravity(Gravity.CENTER);
        view.setPadding(dp(16), dp(10), dp(16), dp(10));
        view.setClickable(true);
        view.setFocusable(true);
        view.setOnClickListener(v -> action.run());
        return view;
    }

    private GradientDrawable cardBackground() {
        GradientDrawable background = new GradientDrawable();
        background.setColor(Color.WHITE);
        background.setCornerRadius(dp(20));
        background.setStroke(Math.max(1, dp(1)), 0xffdadce0);
        return background;
    }

    private int dp(float value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value,
            anchor.getResources().getDisplayMetrics()));
    }
}
