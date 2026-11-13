pub mod support;

use jz_office_core::{
    clear_package_cache, metadata_path_to_json, model::Kind, parse_path_scoped_to_json,
    parse_reader_scoped, Scope,
};
use std::{
    fs,
    io::Cursor,
    path::PathBuf,
    sync::atomic::{AtomicUsize, Ordering},
};
use support::{
    docx,
    package::{archive, TestResult},
    pptx, xlsx,
};

#[test]
fn metadata_scan_reports_kind_pages_and_dimensions_without_full_parse() -> TestResult {
    for parts in [docx::parts(), pptx::parts(), xlsx::parts()] {
        let temporary = TemporaryFile::new("document.bin", &archive(&parts)?)?;
        let json: serde_json::Value =
            serde_json::from_str(&metadata_path_to_json(&temporary.path)?)?;
        assert_eq!(json["schemaVersion"], 9);
        // 元数据协议不携带任何可绘制内容，只描述格式、页数与尺寸
        assert!(json.get("blocks").is_none(), "Metadata carries no blocks");
        assert!(json.get("pages").is_none(), "Metadata carries no pages");
        assert!(
            json.get("sheets").is_none(),
            "Metadata carries no sheet data"
        );
        match json["kind"].as_str() {
            Some("DOCX") => {
                assert_eq!(json["pageCount"], 1);
                assert!(json["width"].as_f64().unwrap_or_default() > 0.0);
            }
            Some("PPTX") => {
                // sldIdLst 声明了两张幻灯片，元数据不读取任何幻灯片部件即可得到页数
                assert_eq!(json["pageCount"], 2);
                assert_eq!(json["width"], serde_json::json!(720.0));
                assert_eq!(json["height"], serde_json::json!(405.0));
            }
            Some("XLSX") => {
                let names = json["sheetNames"]
                    .as_array()
                    .map(|names| names.iter().filter_map(|n| n.as_str()).collect::<Vec<_>>())
                    .unwrap_or_default();
                assert_eq!(names, ["Overview", "Data"]);
                assert_eq!(json["pageCount"], 2);
            }
            other => panic!("Unexpected metadata kind: {other:?}"),
        }
    }
    Ok(())
}

#[test]
fn metadata_scan_matches_full_parse_page_counts() -> TestResult {
    for parts in [pptx::parts(), xlsx::parts()] {
        let bytes = archive(&parts)?;
        let full = parse_reader_scoped(Cursor::new(bytes.clone()), Scope::Full)?;
        let temporary = TemporaryFile::new("document.bin", &bytes)?;
        let json: serde_json::Value =
            serde_json::from_str(&metadata_path_to_json(&temporary.path)?)?;
        let full_pages = match full.kind {
            Kind::XLSX => full.sheets.len(),
            _ => full.pages.len(),
        };
        assert_eq!(
            json["pageCount"].as_u64(),
            Some(full_pages as u64),
            "Metadata page counts must match the full parse even though it skips content"
        );
    }
    Ok(())
}

#[test]
fn first_viewport_scope_limits_pages_sheets_and_blocks() -> TestResult {
    let pptx = parse_reader_scoped(Cursor::new(archive(&pptx::parts())?), Scope::FirstViewport)?;
    assert_eq!(pptx.pages.len(), 1, "PPTX renders only the first slide");
    assert!(
        !pptx.pages[0].elements.is_empty(),
        "First slide still carries its elements"
    );

    let xlsx = parse_reader_scoped(Cursor::new(archive(&xlsx::parts())?), Scope::FirstViewport)?;
    assert_eq!(xlsx.sheets.len(), 2, "Sheet names remain available");
    assert!(
        !xlsx.sheets[0].cells.is_empty(),
        "First sheet is parsed for the cover"
    );
    assert!(
        xlsx.sheets[1].cells.is_empty(),
        "Later sheets are names only"
    );

    let docx = parse_reader_scoped(Cursor::new(archive(&docx::parts())?), Scope::FirstViewport)?;
    let full = parse_reader_scoped(Cursor::new(archive(&docx::parts())?), Scope::Full)?;
    assert!(
        docx.blocks.len() <= full.blocks.len(),
        "Viewport scope never exceeds the full parse"
    );
    assert!(!docx.blocks.is_empty(), "Cover keeps leading blocks");
    assert_eq!(
        docx.header_blocks.len(),
        full.header_blocks.len(),
        "Headers are part of the cover and stay complete"
    );
    Ok(())
}

#[test]
fn full_scope_is_unchanged_by_the_cache() -> TestResult {
    let temporary = TemporaryFile::new("document.bin", &archive(&docx::parts())?)?;
    let first = parse_path_scoped_to_json(&temporary.path, Scope::Full)?;
    let second = parse_path_scoped_to_json(&temporary.path, Scope::Full)?;
    assert_eq!(first, second, "Repeated full parses return identical JSON");
    // 更完整的结果可以服务更小的范围：先打开预览再生成封面不会重复解析
    let viewport = parse_path_scoped_to_json(&temporary.path, Scope::FirstViewport)?;
    assert_eq!(
        first, viewport,
        "A cached full result satisfies a viewport request"
    );
    Ok(())
}

#[test]
fn viewport_result_never_satisfies_a_full_request() -> TestResult {
    let temporary = TemporaryFile::new("document.bin", &archive(&pptx::parts())?)?;
    let viewport = parse_path_scoped_to_json(&temporary.path, Scope::FirstViewport)?;
    let viewport_json: serde_json::Value = serde_json::from_str(&viewport)?;
    assert_eq!(viewport_json["pages"].as_array().map(Vec::len), Some(1));
    let full = parse_path_scoped_to_json(&temporary.path, Scope::Full)?;
    let full_json: serde_json::Value = serde_json::from_str(&full)?;
    assert_eq!(
        full_json["pages"].as_array().map(Vec::len),
        Some(2),
        "A truncated viewport result must not be served for a full request"
    );
    Ok(())
}

#[test]
fn cache_invalidates_when_the_file_changes() -> TestResult {
    let temporary = TemporaryFile::new("document.bin", &archive(&docx::parts())?)?;
    let before = parse_path_scoped_to_json(&temporary.path, Scope::Full)?;
    // 同路径写入内容不同的包：大小与修改时间变化后必须重新解析
    fs::write(&temporary.path, archive(&pptx::parts())?)?;
    let after = parse_path_scoped_to_json(&temporary.path, Scope::Full)?;
    assert_ne!(before, after, "Changed files must not reuse stale results");
    let json: serde_json::Value = serde_json::from_str(&after)?;
    assert_eq!(json["kind"], "PPTX");
    Ok(())
}

#[test]
fn eviction_and_clear_drop_cached_results() -> TestResult {
    let temporary = TemporaryFile::new("document.bin", &archive(&docx::parts())?)?;
    parse_path_scoped_to_json(&temporary.path, Scope::Full)?;
    jz_office_core::evict_package_cache(&temporary.path);
    parse_path_scoped_to_json(&temporary.path, Scope::Full)?;
    clear_package_cache();
    parse_path_scoped_to_json(&temporary.path, Scope::Full)?;
    let json: serde_json::Value =
        serde_json::from_str(&parse_path_scoped_to_json(&temporary.path, Scope::Full)?)?;
    assert_eq!(json["kind"], "DOCX");
    Ok(())
}

struct TemporaryFile {
    directory: PathBuf,
    path: PathBuf,
}

impl TemporaryFile {
    fn new(name: &str, bytes: &[u8]) -> TestResult<Self> {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let directory = std::env::temp_dir().join(format!(
            "jz-office-scope-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed),
        ));
        fs::create_dir(&directory)?;
        let temporary = Self {
            path: directory.join(name),
            directory,
        };
        fs::write(&temporary.path, bytes)?;
        Ok(temporary)
    }
}

impl Drop for TemporaryFile {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.directory);
    }
}
