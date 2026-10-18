package cn.jingzhuan.lib.office.demo;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Bundle;
import android.provider.OpenableColumns;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.widget.EditText;
import android.widget.ImageButton;
import android.widget.LinearLayout;
import android.widget.PopupMenu;
import android.widget.TextView;
import android.widget.Toast;
import cn.jingzhuan.lib.office.OfficePreviewView;
import cn.jingzhuan.lib.office.online.RemoteOfficeDownloader;
import cn.jingzhuan.lib.office.online.RemoteOfficeLoader;
import cn.jingzhuan.lib.office.online.RemoteOfficeRequest;

public final class MainActivity extends Activity {
    private static final int PICK_DOCUMENT = 20;
    private OfficePreviewView preview;
    private TextView title, status;
    private ImageButton previous, next;
    private SheetTabs sheets;
    private OfficePreviewView.Info loadedInfo;
    private RemoteOfficeLoader remoteLoader;
    private RemoteOfficeLoader.Task remoteTask;
    private Uri current;
    private String currentRemoteUrl;

    @Override public void onCreate(Bundle saved) {
        super.onCreate(saved);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setBackgroundColor(0xfffafbfc);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(), insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets;
        });
        LinearLayout toolbar = new LinearLayout(this); toolbar.setGravity(Gravity.CENTER_VERTICAL); toolbar.setPadding(dp(12), 0, dp(8), 0);
        title = new TextView(this); title.setText("JZ Office"); title.setTextSize(18); title.setTextColor(0xff25282d); title.setSingleLine(true); title.setEllipsize(android.text.TextUtils.TruncateAt.END);
        toolbar.addView(title, new LinearLayout.LayoutParams(0, dp(56), 1)); title.setGravity(Gravity.CENTER_VERTICAL);
        toolbar.addView(button(R.drawable.ic_office_open, "Open document", v -> pick()));
        toolbar.addView(button(R.drawable.ic_office_more, "More", this::showMore));
        toolbar.addView(button(R.drawable.ic_office_samples, "Open sample", v -> showSamples()));
        toolbar.addView(button(R.drawable.ic_office_fit, "Reset zoom", v -> preview.resetZoom()));
        previous = button(R.drawable.ic_office_previous, "Previous slide", v -> preview.jumpToPage(preview.getCurrentPage() - 1));
        next = button(R.drawable.ic_office_next, "Next slide", v -> preview.jumpToPage(preview.getCurrentPage() + 1));
        toolbar.addView(previous); toolbar.addView(next);
        root.addView(toolbar);
        status = new TextView(this); status.setTextSize(12); status.setTextColor(0xff58616b); status.setPadding(dp(16), dp(4), dp(16), dp(8));
        status.setText("DOCX / PPTX / XLSX"); root.addView(status);
        preview = new OfficePreviewView(this); preview.setId(android.R.id.primary); root.addView(preview, new LinearLayout.LayoutParams(-1, 0, 1));
        sheets = new SheetTabs(this); root.addView(sheets, new LinearLayout.LayoutParams(-1, -2));
        remoteLoader = new RemoteOfficeLoader(this);
        preview.setOnPageChangeListener((page, count) -> updatePageState());
        setContentView(root);
        if (saved != null && saved.getString("remoteUrl") != null) openRemote(saved.getString("remoteUrl"));
        else if (saved != null && saved.getString("uri") != null) open(Uri.parse(saved.getString("uri")));
        else if (getIntent().getData() != null) open(getIntent().getData());
        else showSamples();
    }

    private ImageButton button(int icon, String label, View.OnClickListener action) {
        ImageButton button = new ImageButton(this); button.setImageResource(icon); button.setContentDescription(label);
        button.setImageTintList(getColorStateList(R.color.office_toolbar_icon));
        button.setScaleType(android.widget.ImageView.ScaleType.CENTER);
        android.util.TypedValue value = new android.util.TypedValue(); getTheme().resolveAttribute(android.R.attr.selectableItemBackgroundBorderless, value, true); button.setBackgroundResource(value.resourceId);
        button.setLayoutParams(new LinearLayout.LayoutParams(dp(48), dp(48))); button.setOnClickListener(action);
        if (android.os.Build.VERSION.SDK_INT >= 26) button.setTooltipText(label);
        return button;
    }

    private void pick() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE).setType("*/*");
        intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[] {
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        });
        startActivityForResult(intent, PICK_DOCUMENT);
    }

    private void showSamples() {
        try {
            String[] names = SampleProvider.names(this);
            new AlertDialog.Builder(this).setTitle("Samples")
                .setItems(names, (dialog, which) -> open(new Uri.Builder().scheme("content")
                    .authority(getPackageName() + ".samples").appendPath(names[which]).build()))
                .setNegativeButton(android.R.string.cancel, null).show();
        } catch (java.io.IOException error) {
            new AlertDialog.Builder(this).setTitle("Samples").setMessage(error.getMessage())
                .setPositiveButton(android.R.string.ok, null).show();
        }
    }

    private void showUrlDialog() {
        EditText input = new EditText(this);
        input.setSingleLine(true);
        input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        input.setHint("https://example.com/report.xlsx");
        int padding = dp(20);
        LinearLayout box = new LinearLayout(this);
        box.setPadding(padding, 0, padding, 0);
        box.addView(input, new LinearLayout.LayoutParams(-1, -2));
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Open URL").setView(box)
            .setPositiveButton(android.R.string.ok, null)
            .setNegativeButton(android.R.string.cancel, null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(view -> {
            String url = input.getText().toString().trim();
            try { RemoteOfficeRequest.builder(url).build(); }
            catch (IllegalArgumentException error) { input.setError(error.getMessage()); return; }
            dialog.dismiss();
            openRemote(url);
        }));
        dialog.show();
    }

    private void showMore(View anchor) {
        PopupMenu menu = new PopupMenu(this, anchor);
        menu.getMenu().add(0, 1, 0, "Open URL");
        menu.getMenu().add(0, 2, 1, "Cancel download").setEnabled(remoteTask != null && !remoteTask.isComplete());
        menu.getMenu().add(0, 3, 2, "Retry").setEnabled(currentRemoteUrl != null && (remoteTask == null || remoteTask.isComplete()));
        menu.getMenu().add(0, 4, 3, "Close document");
        menu.getMenu().add(0, 5, 4, "Clear cache");
        menu.setOnMenuItemClickListener(item -> {
            switch (item.getItemId()) {
                case 1: showUrlDialog(); break;
                case 2: cancelRemote(); status.setText("Cancelled"); break;
                case 3: openRemote(currentRemoteUrl); break;
                case 4:
                    cancelRemote(); preview.clear(); loadedInfo = null; current = null; currentRemoteUrl = null;
                    sheets.bind(java.util.Collections.emptyList(), preview); updatePageState();
                    title.setText("JZ Office"); status.setText("DOCX / PPTX / XLSX"); status.setOnClickListener(null);
                    break;
                case 5:
                    remoteLoader.clearCache(result -> {
                        if (isDestroyed()) return;
                        String message = "Cleared " + android.text.format.Formatter.formatFileSize(this, result.deletedBytes)
                            + " | " + result.skippedFiles + " in use | " + result.failedFiles + " failed";
                        Toast.makeText(this, message, Toast.LENGTH_LONG).show();
                    });
                    break;
                default: return false;
            }
            return true;
        });
        menu.show();
    }

    @Override protected void onActivityResult(int request, int result, Intent data) {
        super.onActivityResult(request, result, data);
        if (request != PICK_DOCUMENT || result != RESULT_OK || data == null || data.getData() == null) return;
        Uri uri = data.getData();
        if ((data.getFlags() & Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION) != 0) {
            try { getContentResolver().takePersistableUriPermission(uri, data.getFlags() & Intent.FLAG_GRANT_READ_URI_PERMISSION); }
            catch (SecurityException ignored) { }
        }
        open(uri);
    }

    private void open(Uri uri) {
        cancelRemote();
        loadedInfo = null; updatePageState();
        sheets.bind(java.util.Collections.emptyList(), preview);
        current = uri; currentRemoteUrl = null; status.setText("Loading..."); status.setOnClickListener(null);
        title.setText("Document");
        new Thread(() -> {
            String name = "Document";
            try (Cursor cursor = getContentResolver().query(uri, new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
                if (cursor != null && cursor.moveToFirst()) name = cursor.getString(0);
            } catch (RuntimeException ignored) { }
            final String displayName = name;
            runOnUiThread(() -> { if (!isDestroyed() && uri.equals(current)) title.setText(displayName); });
        }, "document-name").start();
        preview.open(uri, new OfficePreviewView.Listener() {
            @Override public void onLoaded(OfficePreviewView.Info info) {
                loadedInfo = info; sheets.bind(info.sheetNames, preview); updatePageState();
                if (!info.warnings.isEmpty()) status.setOnClickListener(v -> new AlertDialog.Builder(MainActivity.this).setTitle("Preview notices").setMessage(android.text.TextUtils.join("\n\n", info.warnings)).setPositiveButton(android.R.string.ok, null).show());
            }
            @Override public void onError(Exception error) { status.setText(error.getMessage()); }
        });
    }

    private void openRemote(String url) {
        if (url == null || url.isEmpty()) return;
        RemoteOfficeRequest request;
        try { request = RemoteOfficeRequest.builder(url).build(); }
        catch (IllegalArgumentException error) { status.setText(error.getMessage()); return; }
        cancelRemote();
        loadedInfo = null; updatePageState();
        sheets.bind(java.util.Collections.emptyList(), preview);
        current = null; currentRemoteUrl = url; status.setText("Downloading..."); status.setOnClickListener(null);
        title.setText(remoteTitle(url));
        remoteTask = remoteLoader.open(preview, request, new RemoteOfficeLoader.Listener() {
            @Override public void onProgress(long bytesRead, long totalBytes) {
                if (url.equals(currentRemoteUrl)) status.setText(progressText(bytesRead, totalBytes));
            }

            @Override public void onDownloaded(RemoteOfficeDownloader.Result result) {
                if (!url.equals(currentRemoteUrl)) return;
                title.setText(result.getDisplayName());
                status.setText("Opening...");
            }

            @Override public void onLoaded(OfficePreviewView.Info info) {
                if (!url.equals(currentRemoteUrl)) return;
                loadedInfo = info; sheets.bind(info.sheetNames, preview); updatePageState();
                if (!info.warnings.isEmpty()) status.setOnClickListener(v -> new AlertDialog.Builder(MainActivity.this).setTitle("Preview notices").setMessage(android.text.TextUtils.join("\n\n", info.warnings)).setPositiveButton(android.R.string.ok, null).show());
            }

            @Override public void onError(Exception error) {
                if (url.equals(currentRemoteUrl)) status.setText(error.getMessage());
            }
        });
    }

    private void updatePageState() {
        boolean slides = loadedInfo != null && loadedInfo.format.equals("PPTX");
        previous.setVisibility(slides ? View.VISIBLE : View.GONE);
        next.setVisibility(slides ? View.VISIBLE : View.GONE);
        if (loadedInfo == null) return;
        int page = preview.getCurrentPage();
        sheets.select(page);
        previous.setEnabled(page > 1);
        next.setEnabled(page > 0 && page < preview.getPageCount());
        boolean workbook = loadedInfo.format.equals("XLSX");
        status.setText(loadedInfo.format + (slides || workbook ? "  |  " + page + " / " + preview.getPageCount() : "  |  Continuous")
            + (loadedInfo.warnings.isEmpty() ? "" : "  |  " + loadedInfo.warnings.size() + " notices"));
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent); setIntent(intent);
        if (intent.getData() != null) open(intent.getData());
    }
    @Override protected void onSaveInstanceState(Bundle out) {
        super.onSaveInstanceState(out);
        if (currentRemoteUrl != null) out.putString("remoteUrl", currentRemoteUrl);
        else if (current != null) out.putString("uri", current.toString());
    }
    @Override protected void onDestroy() {
        cancelRemote();
        remoteLoader.close();
        preview.clear();
        super.onDestroy();
    }

    private void cancelRemote() {
        if (remoteTask != null) {
            remoteTask.cancel();
            remoteTask = null;
        }
    }

    private String progressText(long bytesRead, long totalBytes) {
        if (totalBytes > 0) return "Downloading... " + Math.min(100, Math.round(bytesRead * 100f / totalBytes)) + "%";
        return "Downloading... " + (bytesRead / 1024) + " KiB";
    }

    private String remoteTitle(String url) {
        String segment = Uri.parse(url).getLastPathSegment();
        return segment == null || segment.isEmpty() ? "Remote document" : segment;
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
}
