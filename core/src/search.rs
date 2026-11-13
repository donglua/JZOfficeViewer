use crate::model::{
    Cell, CellRange, Document, Element, ElementType, Kind, Paragraph, SearchMatch, Sheet,
};
use crate::{Error, Result};
use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;

/// 单次全文检索返回的最大命中条数上限，防止超短词在巨型文档中产生过大 JSON 载荷
pub const MAX_SEARCH_MATCHES: usize = 1_000;

/// 进程内最多保留的全文检索索引数量。
pub const MAX_CACHED_SEARCH_INDEXES: usize = 4;
/// 进程内缓存的检索文本总字节上限，避免少量大型文档长期占用过多内存。
pub const MAX_CACHED_SEARCH_INDEX_BYTES: usize = 16 * 1024 * 1024;
/// 单份索引允许缓存的最大文本条目数，限制大量短文本产生的索引元数据开销。
pub const MAX_CACHED_SEARCH_INDEX_ENTRIES: usize = 100_000;
const SNIPPET_CONTEXT_CHARS: usize = 20;
const SNIPPET_MATCH_MAX_CHARS: usize = 60;

#[derive(Debug, Clone)]
struct SearchEntry {
    page_index: u32,
    element_index: u32,
    paragraph_index: u32,
    row: Option<u32>,
    column: Option<u32>,
    text: String,
}

/// 预提取的轻量级文档纯文本检索索引
#[derive(Debug, Clone, Default)]
pub struct SearchIndex {
    entries: Vec<SearchEntry>,
    text_bytes: usize,
}

struct CachedIndexEntry {
    path: PathBuf,
    len: u64,
    modified: Option<SystemTime>,
    index: Arc<SearchIndex>,
}

#[derive(Default)]
struct IndexCache {
    entries: VecDeque<Arc<CachedIndexEntry>>,
    text_bytes: usize,
}

static GLOBAL_INDEX_CACHE: OnceLock<Mutex<IndexCache>> = OnceLock::new();

fn get_cache() -> &'static Mutex<IndexCache> {
    GLOBAL_INDEX_CACHE.get_or_init(|| Mutex::new(IndexCache::default()))
}

pub(crate) fn clear_cache() {
    if let Ok(mut cache) = get_cache().lock() {
        cache.entries.clear();
        cache.text_bytes = 0;
    }
}

pub(crate) fn evict_cache(path: &Path) {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if let Ok(mut cache) = get_cache().lock() {
        let removed_bytes: usize = cache
            .entries
            .iter()
            .filter(|item| item.path == canonical || item.path == path)
            .map(|item| item.index.text_bytes)
            .sum();
        cache
            .entries
            .retain(|item| item.path != canonical && item.path != path);
        cache.text_bytes = cache.text_bytes.saturating_sub(removed_bytes);
    }
}

fn store_in_cache(
    canonical: PathBuf,
    len: u64,
    modified: Option<SystemTime>,
    index: Arc<SearchIndex>,
) {
    if index.text_bytes > MAX_CACHED_SEARCH_INDEX_BYTES
        || index.entries.len() > MAX_CACHED_SEARCH_INDEX_ENTRIES
    {
        return;
    }
    if let Ok(mut cache) = get_cache().lock() {
        let replaced_bytes: usize = cache
            .entries
            .iter()
            .filter(|item| item.path == canonical)
            .map(|item| item.index.text_bytes)
            .sum();
        cache.entries.retain(|item| item.path != canonical);
        cache.text_bytes = cache.text_bytes.saturating_sub(replaced_bytes);
        while cache.entries.len() >= MAX_CACHED_SEARCH_INDEXES
            || cache.text_bytes.saturating_add(index.text_bytes) > MAX_CACHED_SEARCH_INDEX_BYTES
        {
            let Some(item) = cache.entries.pop_front() else {
                break;
            };
            cache.text_bytes = cache.text_bytes.saturating_sub(item.index.text_bytes);
        }
        cache.text_bytes = cache.text_bytes.saturating_add(index.text_bytes);
        cache.entries.push_back(Arc::new(CachedIndexEntry {
            path: canonical,
            len,
            modified,
            index,
        }));
    }
}

fn get_or_build_index(path: &Path) -> Result<Arc<SearchIndex>> {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let metadata = fs::metadata(&canonical)?;
    let len = metadata.len();
    let modified = metadata.modified().ok();

    {
        let mut cache = get_cache()
            .lock()
            .map_err(|_| Error::Invalid("Search index cache lock poisoned"))?;
        let mut found_idx = None;
        for (i, item) in cache.entries.iter().enumerate() {
            if item.path == canonical {
                if item.len == len && item.modified == modified {
                    found_idx = Some(i);
                }
                break;
            }
        }
        if let Some(i) = found_idx {
            if let Some(item) = cache.entries.remove(i) {
                let index = Arc::clone(&item.index);
                cache.entries.push_back(item);
                return Ok(index);
            }
        }
    }

    let document = crate::parse_reader(fs::File::open(&canonical)?)?;
    let index = Arc::new(SearchIndex::from_document(&document));
    store_in_cache(canonical, len, modified, Arc::clone(&index));
    Ok(index)
}

/// 显式预热指定路径的全文检索索引。
///
/// 默认解析不会建立索引；调用方仅应在确认即将搜索且有空闲资源时调用本函数。
pub fn prewarm_search_index(path: &Path) -> Result<()> {
    let _ = get_or_build_index(path)?;
    Ok(())
}

/// 在已解析的 `Document` 内存模型中执行大小写不敏感的全文检索
#[must_use]
pub fn search_document(document: &Document, query: &str) -> Vec<SearchMatch> {
    if query.is_empty() {
        return Vec::new();
    }
    SearchIndex::from_document(document).search(query)
}

/// 在指定路径的文档中执行大小写不敏感的全文检索（首次检索时按需建立轻量文本索引）
pub fn search_path(path: &Path, query: &str) -> Result<Vec<SearchMatch>> {
    if query.is_empty() {
        return Ok(Vec::new());
    }
    let index = get_or_build_index(path)?;
    Ok(index.search(query))
}

/// 在指定路径的文档中执行全文检索并序列化为 JSON 数组字符串
pub fn search_path_to_json(path: &Path, query: &str) -> Result<String> {
    let matches = search_path(path, query)?;
    let json = serde_json::to_string(&matches)?;
    Ok(json)
}

impl SearchIndex {
    /// 从 `Document` 提取有序的可检索文本条目（自动过滤被合并覆盖的单元格与隐藏行列）
    #[must_use]
    pub fn from_document(document: &Document) -> Self {
        let mut entries = Vec::new();
        match document.kind {
            Kind::DOCX => {
                for (elem_idx, element) in document
                    .header_blocks
                    .iter()
                    .chain(&document.blocks)
                    .chain(&document.footer_blocks)
                    .enumerate()
                {
                    collect_element_entries(
                        &mut entries,
                        0,
                        u32::try_from(elem_idx).unwrap_or(u32::MAX),
                        element,
                    );
                }
            }
            Kind::PPTX => {
                for (page_idx, page) in document.pages.iter().enumerate() {
                    let page_u32 = u32::try_from(page_idx).unwrap_or(u32::MAX);
                    for (elem_idx, element) in page.elements.iter().enumerate() {
                        collect_element_entries(
                            &mut entries,
                            page_u32,
                            u32::try_from(elem_idx).unwrap_or(u32::MAX),
                            element,
                        );
                    }
                }
            }
            Kind::XLSX => {
                for (sheet_idx, sheet) in document.sheets.iter().enumerate() {
                    collect_sheet_entries(
                        &mut entries,
                        u32::try_from(sheet_idx).unwrap_or(u32::MAX),
                        sheet,
                    );
                }
            }
        }
        let text_bytes = entries.iter().map(|entry| entry.text.len()).sum();
        Self {
            entries,
            text_bytes,
        }
    }

    /// 在索引中检索 `query`（忽略大小写），返回最多 `MAX_SEARCH_MATCHES` 条命中结果
    #[must_use]
    pub fn search(&self, query: &str) -> Vec<SearchMatch> {
        let needle_lower: Vec<char> = query.chars().flat_map(char::to_lowercase).collect();
        if needle_lower.is_empty() {
            return Vec::new();
        }
        let mut matches = Vec::new();
        for entry in &self.entries {
            search_in_entry(entry, &needle_lower, &mut matches);
            if matches.len() >= MAX_SEARCH_MATCHES {
                break;
            }
        }
        matches
    }
}

fn collect_element_entries(
    entries: &mut Vec<SearchEntry>,
    page_index: u32,
    element_index: u32,
    element: &Element,
) {
    if matches!(element.kind, ElementType::TABLE) || !element.rows.is_empty() {
        for (r, row) in element.rows.iter().enumerate() {
            let r_u32 = u32::try_from(r).unwrap_or(u32::MAX);
            for (c, cell_paragraphs) in row.iter().enumerate() {
                let c_u32 = u32::try_from(c).unwrap_or(u32::MAX);
                if is_covered_table_cell(&element.merges, r_u32, c_u32) {
                    continue;
                }
                for (p_idx, paragraph) in cell_paragraphs.iter().enumerate() {
                    let text = paragraph_rendered_text(paragraph);
                    if !text.is_empty() {
                        entries.push(SearchEntry {
                            page_index,
                            element_index,
                            paragraph_index: u32::try_from(p_idx).unwrap_or(u32::MAX),
                            row: Some(r_u32),
                            column: Some(c_u32),
                            text,
                        });
                    }
                }
            }
        }
    } else if !element.paragraphs.is_empty() {
        for (p_idx, paragraph) in element.paragraphs.iter().enumerate() {
            let text = paragraph_rendered_text(paragraph);
            if !text.is_empty() {
                entries.push(SearchEntry {
                    page_index,
                    element_index,
                    paragraph_index: u32::try_from(p_idx).unwrap_or(u32::MAX),
                    row: None,
                    column: None,
                    text,
                });
            }
        }
    }
}

fn collect_sheet_entries(entries: &mut Vec<SearchEntry>, sheet_index: u32, sheet: &Sheet) {
    for (cell_idx, cell) in sheet.cells.iter().enumerate() {
        if cell.text.is_empty() || !is_sheet_cell_visible(sheet, cell) {
            continue;
        }
        entries.push(SearchEntry {
            page_index: sheet_index,
            element_index: u32::try_from(cell_idx).unwrap_or(u32::MAX),
            paragraph_index: 0,
            row: Some(cell.row),
            column: Some(cell.column),
            text: cell.text.clone(),
        });
    }
}

fn is_covered_table_cell(merges: &[CellRange], row: u32, col: u32) -> bool {
    for m in merges {
        if row >= m.start_row && row <= m.end_row && col >= m.start_column && col <= m.end_column {
            return row != m.start_row || col != m.start_column;
        }
    }
    false
}

fn is_sheet_cell_visible(sheet: &Sheet, cell: &Cell) -> bool {
    for m in &sheet.merges {
        if cell.row >= m.start_row
            && cell.row <= m.end_row
            && cell.column >= m.start_column
            && cell.column <= m.end_column
        {
            if cell.row != m.start_row || cell.column != m.start_column {
                return false;
            }
            let has_visible_row = (m.start_row..=m.end_row)
                .any(|r| sheet.row_heights.get(r as usize).copied().unwrap_or(15.0) > 0.0);
            let has_visible_col = (m.start_column..=m.end_column)
                .any(|c| sheet.column_widths.get(c as usize).copied().unwrap_or(64.0) > 0.0);
            return has_visible_row && has_visible_col;
        }
    }
    let row_visible = sheet
        .row_heights
        .get(cell.row as usize)
        .copied()
        .unwrap_or(15.0)
        > 0.0;
    let col_visible = sheet
        .column_widths
        .get(cell.column as usize)
        .copied()
        .unwrap_or(64.0)
        > 0.0;
    row_visible && col_visible
}

fn paragraph_rendered_text(paragraph: &Paragraph) -> String {
    let runs_len: usize = paragraph.runs.iter().map(|r| r.text.len()).sum();
    let total_len = paragraph.bullet.len() + runs_len;
    if total_len == 0 {
        return String::new();
    }
    let mut text = String::with_capacity(total_len);
    text.push_str(&paragraph.bullet);
    for run in &paragraph.runs {
        text.push_str(&run.text);
    }
    text
}

fn search_in_entry(entry: &SearchEntry, needle_lower: &[char], matches: &mut Vec<SearchMatch>) {
    let text = entry.text.as_str();
    let mut byte_pos = 0_usize;
    let mut utf16_pos = 0_u32;

    while byte_pos < text.len() && matches.len() < MAX_SEARCH_MATCHES {
        let tail = &text[byte_pos..];
        if let Some((matched_bytes, matched_utf16)) =
            match_prefix_case_insensitive(tail, needle_lower)
        {
            let match_byte_end = byte_pos + matched_bytes;
            let start_char = utf16_pos;
            let end_char = utf16_pos + matched_utf16;
            matches.push(SearchMatch {
                page_index: entry.page_index,
                element_index: entry.element_index,
                paragraph_index: entry.paragraph_index,
                row: entry.row,
                column: entry.column,
                start_char,
                end_char,
                snippet: build_snippet(text, byte_pos, match_byte_end),
            });
            byte_pos = match_byte_end;
            utf16_pos = end_char;
        } else if let Some(ch) = tail.chars().next() {
            byte_pos += ch.len_utf8();
            utf16_pos += u32::try_from(ch.len_utf16()).unwrap_or(1);
        } else {
            break;
        }
    }
}

fn match_prefix_case_insensitive(tail: &str, needle_lower: &[char]) -> Option<(usize, u32)> {
    let mut n_idx = 0_usize;
    let mut byte_len = 0_usize;
    let mut utf16_len = 0_u32;

    for ch in tail.chars() {
        byte_len += ch.len_utf8();
        utf16_len += u32::try_from(ch.len_utf16()).unwrap_or(1);
        for lc in ch.to_lowercase() {
            if n_idx < needle_lower.len() {
                if lc != needle_lower[n_idx] {
                    return None;
                }
                n_idx += 1;
            } else {
                return None;
            }
        }
        if n_idx == needle_lower.len() {
            return Some((byte_len, utf16_len));
        }
    }
    None
}

fn build_snippet(text: &str, match_start: usize, match_end: usize) -> String {
    let before_str = &text[..match_start];
    let matched_str = &text[match_start..match_end];
    let after_str = &text[match_end..];

    let mut before_chars: Vec<char> = before_str
        .chars()
        .rev()
        .take(SNIPPET_CONTEXT_CHARS + 1)
        .collect();
    let has_leading_ellipsis = before_chars.len() > SNIPPET_CONTEXT_CHARS;
    if has_leading_ellipsis {
        before_chars.truncate(SNIPPET_CONTEXT_CHARS);
    }
    before_chars.reverse();

    let mut after_chars = after_str.chars();
    let mut after_collected = Vec::with_capacity(SNIPPET_CONTEXT_CHARS);
    for _ in 0..SNIPPET_CONTEXT_CHARS {
        if let Some(ch) = after_chars.next() {
            after_collected.push(ch);
        } else {
            break;
        }
    }
    let has_trailing_ellipsis = after_chars.next().is_some();

    let mut out = String::new();
    if has_leading_ellipsis {
        out.push_str("...");
    }
    for ch in before_chars {
        push_normalized_char(&mut out, ch);
    }
    let mut matched_chars = matched_str.chars();
    let mut matched_count = 0_usize;
    while matched_count < SNIPPET_MATCH_MAX_CHARS {
        if let Some(ch) = matched_chars.next() {
            push_normalized_char(&mut out, ch);
            matched_count += 1;
        } else {
            break;
        }
    }
    if matched_chars.next().is_some() {
        out.push_str("...");
    }
    for ch in after_collected {
        push_normalized_char(&mut out, ch);
    }
    if has_trailing_ellipsis {
        out.push_str("...");
    }
    out
}

fn push_normalized_char(out: &mut String, ch: char) {
    if ch == '\n' || ch == '\r' || ch == '\t' {
        out.push(' ');
    } else {
        out.push(ch);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Page, Run};

    fn make_run(text: &str) -> Run {
        Run {
            text: text.to_owned(),
            ..Run::default()
        }
    }

    fn make_paragraph(bullet: &str, texts: &[&str]) -> Paragraph {
        Paragraph {
            bullet: bullet.to_owned(),
            runs: texts.iter().map(|t| make_run(t)).collect(),
            ..Paragraph::default()
        }
    }

    #[test]
    fn docx_searches_headers_body_footers_tables_and_cross_run_text() {
        let mut doc = Document::new(Kind::DOCX);

        let mut header_el = Element::default();
        header_el
            .paragraphs
            .push(make_paragraph("", &["机密文档 - ", "2026年度报告"]));
        doc.header_blocks.push(header_el);

        let mut body_el = Element::default();
        body_el
            .paragraphs
            .push(make_paragraph("1. ", &["第一部分：财务", "报表总览"]));
        doc.blocks.push(body_el);

        let mut table_el = Element {
            kind: ElementType::TABLE,
            rows: vec![
                vec![
                    vec![make_paragraph("", &["单元格A1 报表"])],
                    vec![make_paragraph("", &["被横向合并覆盖的报表"])],
                ],
                vec![
                    vec![make_paragraph("", &["单元格A2"])],
                    vec![make_paragraph("", &["单元格B2 报表"])],
                ],
            ],
            merges: vec![CellRange {
                start_row: 0,
                start_column: 0,
                end_row: 0,
                end_column: 1,
            }],
            ..Element::default()
        };
        table_el.column_widths = vec![100.0, 100.0];
        doc.blocks.push(table_el);

        let mut footer_el = Element::default();
        footer_el
            .paragraphs
            .push(make_paragraph("", &["页脚：内部报表"]));
        doc.footer_blocks.push(footer_el);

        let matches = doc.search("报表");
        assert_eq!(matches.len(), 4);

        // 1. 正文段落（element_index = 1，含 "1. " 共 3 个 UTF-16 码元 + "第一部分：财务" 7 个码元 = 偏移 10..12）
        assert_eq!(matches[0].page_index, 0);
        assert_eq!(matches[0].element_index, 1);
        assert_eq!(matches[0].paragraph_index, 0);
        assert_eq!(matches[0].row, None);
        assert_eq!(matches[0].column, None);
        assert_eq!(matches[0].start_char, 10);
        assert_eq!(matches[0].end_char, 12);

        // 2. 表格 (0, 0) 单元格，跳过被合并覆盖的 (0, 1)
        assert_eq!(matches[1].element_index, 2);
        assert_eq!(matches[1].row, Some(0));
        assert_eq!(matches[1].column, Some(0));
        assert_eq!(matches[1].start_char, 6);
        assert_eq!(matches[1].end_char, 8);

        // 3. 表格 (1, 1) 单元格
        assert_eq!(matches[2].element_index, 2);
        assert_eq!(matches[2].row, Some(1));
        assert_eq!(matches[2].column, Some(1));

        // 4. 页脚块（element_index = 3）
        assert_eq!(matches[3].element_index, 3);
        assert_eq!(matches[3].start_char, 5);
        assert_eq!(matches[3].end_char, 7);
    }

    #[test]
    fn utf16_offsets_are_exact_with_emoji_and_case_insensitive_queries() {
        let mut doc = Document::new(Kind::PPTX);
        let mut el = Element::default();
        // "Hi 😀 " -> 'H'(1) + 'i'(1) + ' '(1) + '😀'(2 UTF-16 units) + ' '(1) = 6 UTF-16 units
        el.paragraphs
            .push(make_paragraph("", &["Hi 😀 ", "Office Viewer office"]));
        doc.pages.push(Page {
            width: 720.0,
            height: 405.0,
            background: 0xffffffff,
            elements: vec![el],
        });

        let matches = doc.search("OFFICE");
        assert_eq!(matches.len(), 2);
        assert_eq!(matches[0].page_index, 0);
        assert_eq!(matches[0].element_index, 0);
        assert_eq!(matches[0].start_char, 6);
        assert_eq!(matches[0].end_char, 12);
        assert_eq!(matches[1].start_char, 20);
        assert_eq!(matches[1].end_char, 26);
    }

    #[test]
    fn search_index_tracks_retained_text_bytes() {
        let mut doc = Document::new(Kind::XLSX);
        doc.sheets.push(Sheet {
            name: "Sheet1".to_owned(),
            row_heights: vec![20.0],
            column_widths: vec![64.0],
            cells: vec![Cell {
                row: 0,
                column: 0,
                text: "检索文本".to_owned(),
                style: 0,
                numeric: false,
            }],
            merges: Vec::new(),
            geometry: None,
        });

        let index = SearchIndex::from_document(&doc);
        assert_eq!(index.text_bytes, "检索文本".len());
    }

    #[test]
    fn oversized_indexes_are_not_retained_in_the_cache() {
        let mut doc = Document::new(Kind::XLSX);
        doc.sheets.push(Sheet {
            name: "Sheet1".to_owned(),
            row_heights: vec![20.0],
            column_widths: vec![64.0],
            cells: vec![Cell {
                row: 0,
                column: 0,
                text: "x".repeat(MAX_CACHED_SEARCH_INDEX_BYTES + 1),
                style: 0,
                numeric: false,
            }],
            merges: Vec::new(),
            geometry: None,
        });
        let index = Arc::new(SearchIndex::from_document(&doc));
        let path = PathBuf::from("oversized-search-index.xlsx");

        clear_cache();
        store_in_cache(path.clone(), 1, None, Arc::clone(&index));
        let cache = get_cache()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        assert!(cache.entries.is_empty());
        assert_eq!(cache.text_bytes, 0);
        drop(cache);
        assert_eq!(index.search("xxx").len(), MAX_SEARCH_MATCHES);
    }

    #[test]
    fn xlsx_search_skips_hidden_rows_and_covered_merged_cells() {
        let mut doc = Document::new(Kind::XLSX);
        doc.sheets.push(Sheet {
            name: "Sheet1".to_owned(),
            row_heights: vec![20.0, 0.0, 20.0],
            column_widths: vec![64.0, 64.0],
            cells: vec![
                Cell {
                    row: 0,
                    column: 0,
                    text: "Target Anchor".to_owned(),
                    style: 0,
                    numeric: false,
                },
                Cell {
                    row: 0,
                    column: 1,
                    text: "Target Covered".to_owned(),
                    style: 0,
                    numeric: false,
                },
                Cell {
                    row: 1,
                    column: 0,
                    text: "Target Hidden Row".to_owned(),
                    style: 0,
                    numeric: false,
                },
                Cell {
                    row: 2,
                    column: 1,
                    text: "Target Visible".to_owned(),
                    style: 0,
                    numeric: false,
                },
            ],
            merges: vec![CellRange {
                start_row: 0,
                start_column: 0,
                end_row: 0,
                end_column: 1,
            }],
            geometry: None,
        });

        let matches = doc.search("target");
        assert_eq!(matches.len(), 2);
        assert_eq!(matches[0].element_index, 0);
        assert_eq!(matches[0].row, Some(0));
        assert_eq!(matches[0].column, Some(0));
        assert_eq!(matches[1].element_index, 3);
        assert_eq!(matches[1].row, Some(2));
        assert_eq!(matches[1].column, Some(1));
    }
}
