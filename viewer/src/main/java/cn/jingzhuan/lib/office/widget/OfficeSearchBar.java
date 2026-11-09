package cn.jingzhuan.lib.office.widget;

import android.content.Context;
import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.text.Editable;
import android.text.TextUtils;
import android.text.TextWatcher;
import android.util.AttributeSet;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import cn.jingzhuan.lib.office.OfficePreviewView;

/**
 * 标准化全文检索浮动工具栏（Office Search Bar）。
 * 支持通过 {@link #attachTo(OfficePreviewView)} 与文档预览视图双向联动绑定，
 * 提供搜索输入、实时命中计数、上一个/下一个遍历与关闭交互。
 */
public class OfficeSearchBar extends LinearLayout {

    private final EditText inputView;
    private final TextView countView;
    private final TextView prevButton;
    private final TextView nextButton;
    private final TextView closeButton;

    private OfficePreviewView attachedPreview;
    private OfficePreviewView.SearchListener searchListener;

    public OfficeSearchBar(Context context) {
        this(context, null);
    }

    public OfficeSearchBar(Context context, AttributeSet attrs) {
        this(context, attrs, 0);
    }

    public OfficeSearchBar(Context context, AttributeSet attrs, int defStyleAttr) {
        super(context, attrs, defStyleAttr);
        setOrientation(HORIZONTAL);
        setGravity(Gravity.CENTER_VERTICAL);
        int padH = dp(10);
        int padV = dp(6);
        setPadding(padH, padV, padH, padV);

        // 卡片圆角半透明拟物背景
        GradientDrawable bg = new GradientDrawable();
        bg.setColor(Color.WHITE);
        bg.setCornerRadius(dp(8));
        bg.setStroke(dp(1), 0x26000000);
        setBackground(bg);
        setElevation(dp(4));

        // 搜索图标
        TextView iconView = new TextView(context);
        iconView.setText("🔍");
        iconView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        iconView.setPadding(0, 0, dp(6), 0);
        addView(iconView, new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT));

        // 搜索输入框
        inputView = new EditText(context);
        inputView.setHint("搜索文档...");
        inputView.setSingleLine(true);
        inputView.setBackground(null);
        inputView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        inputView.setTextColor(0xff25282d);
        inputView.setHintTextColor(0xff8a94a6);
        inputView.setImeOptions(EditorInfo.IME_ACTION_SEARCH);
        LayoutParams inputLp = new LayoutParams(0, LayoutParams.WRAP_CONTENT, 1f);
        addView(inputView, inputLp);

        // 命中计数标签
        countView = new TextView(context);
        countView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        countView.setTextColor(0xff8a94a6);
        countView.setPadding(dp(4), 0, dp(8), 0);
        countView.setVisibility(GONE);
        addView(countView, new LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT));

        // 上一个按钮
        prevButton = createActionButton("▲", "上一个匹配项", v -> {
            if (attachedPreview != null) attachedPreview.findPrevious();
        });
        addView(prevButton);

        // 下一个按钮
        nextButton = createActionButton("▼", "下一个匹配项", v -> {
            if (attachedPreview != null) attachedPreview.findNext();
        });
        addView(nextButton);

        // 关闭按钮
        closeButton = createActionButton("✕", "关闭搜索", v -> hide());
        addView(closeButton);

        // 输入监听与回车响应
        inputView.addTextChangedListener(new TextWatcher() {
            @Override public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            @Override public void onTextChanged(CharSequence s, int start, int before, int count) {}
            @Override public void afterTextChanged(Editable s) {
                if (attachedPreview != null) {
                    attachedPreview.search(s != null ? s.toString() : "");
                }
            }
        });

        inputView.setOnEditorActionListener((v, actionId, event) -> {
            if (actionId == EditorInfo.IME_ACTION_SEARCH ||
                (event != null && event.getKeyCode() == KeyEvent.KEYCODE_ENTER && event.getAction() == KeyEvent.ACTION_DOWN)) {
                if (attachedPreview != null) {
                    attachedPreview.findNext();
                }
                return true;
            }
            return false;
        });

        setVisibility(GONE);
    }

    private TextView createActionButton(String text, String contentDescription, OnClickListener listener) {
        TextView btn = new TextView(getContext());
        btn.setText(text);
        btn.setContentDescription(contentDescription);
        btn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        btn.setTextColor(0xff4a5159);
        btn.setGravity(Gravity.CENTER);
        int pad = dp(8);
        btn.setPadding(pad, pad, pad, pad);
        btn.setOnClickListener(listener);
        return btn;
    }

    /**
     * 将搜索栏与指定的 OfficePreviewView 绑定联动。
     */
    public void attachTo(OfficePreviewView preview) {
        if (this.attachedPreview == preview) return;
        detach();
        this.attachedPreview = preview;
        if (preview != null) {
            searchListener = new OfficePreviewView.SearchListener() {
                @Override
                public void onSearchResults(String query, int matchCount) {
                    post(() -> updateStatus(query, matchCount, attachedPreview.getCurrentMatchIndex()));
                }

                @Override
                public void onCurrentMatchChanged(int currentIndex, int matchCount, OfficePreviewView.SearchMatch match) {
                    post(() -> updateStatus(inputView.getText().toString(), matchCount, currentIndex));
                }
            };
            preview.addSearchListener(searchListener);
        }
    }

    /**
     * 解除与当前 OfficePreviewView 的联动绑定。
     */
    public void detach() {
        if (attachedPreview != null && searchListener != null) {
            attachedPreview.removeSearchListener(searchListener);
            searchListener = null;
        }
        attachedPreview = null;
    }

    private void updateStatus(String query, int matchCount, int currentIndex) {
        if (TextUtils.isEmpty(query)) {
            countView.setVisibility(GONE);
            prevButton.setEnabled(false);
            nextButton.setEnabled(false);
            prevButton.setAlpha(0.35f);
            nextButton.setAlpha(0.35f);
            return;
        }
        countView.setVisibility(VISIBLE);
        if (matchCount == 0) {
            countView.setText("无结果");
            prevButton.setEnabled(false);
            nextButton.setEnabled(false);
            prevButton.setAlpha(0.35f);
            nextButton.setAlpha(0.35f);
        } else {
            countView.setText((currentIndex + 1) + "/" + matchCount);
            prevButton.setEnabled(true);
            nextButton.setEnabled(true);
            prevButton.setAlpha(1.0f);
            nextButton.setAlpha(1.0f);
        }
    }

    /**
     * 展开搜索工具栏并弹出输入键盘。
     */
    public void show() {
        setVisibility(VISIBLE);
        inputView.requestFocus();
        InputMethodManager imm = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) {
            imm.showSoftInput(inputView, InputMethodManager.SHOW_IMPLICIT);
        }
    }

    /**
     * 收起搜索工具栏，清空检索状态并收起软键盘。
     */
    public void hide() {
        setVisibility(GONE);
        inputView.setText("");
        InputMethodManager imm = (InputMethodManager) getContext().getSystemService(Context.INPUT_METHOD_SERVICE);
        if (imm != null) {
            imm.hideSoftInputFromWindow(inputView.getWindowToken(), 0);
        }
        if (attachedPreview != null) {
            attachedPreview.clearSearch();
        }
    }

    /**
     * 切换展示/隐藏状态。
     */
    public void toggle() {
        if (getVisibility() == VISIBLE) {
            hide();
        } else {
            show();
        }
    }

    private int dp(int value) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value, getResources().getDisplayMetrics()));
    }
}
