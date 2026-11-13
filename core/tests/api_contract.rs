pub mod support;

use jz_office_core::{
    clear_package_cache, evict_package_cache, model::Kind, parse_path, parse_path_to_json,
    parse_reader, prewarm_search_index, search_path, search_path_to_json, Package,
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
fn reader_detects_document_format_from_package_content() -> TestResult {
    for (parts, expected) in [
        (docx::parts(), "DOCX"),
        (pptx::parts(), "PPTX"),
        (xlsx::parts(), "XLSX"),
    ] {
        let bytes = archive(&parts)?;

        let document = parse_reader(Cursor::new(bytes))?;

        assert_eq!(serde_json::to_value(document.kind)?, expected);
    }
    Ok(())
}

#[test]
fn path_detection_ignores_wrong_or_missing_filename_extension() -> TestResult {
    for (parts, name, expected) in [
        (docx::parts(), "document.pptx", "DOCX"),
        (pptx::parts(), "presentation.docx", "PPTX"),
        (docx::parts(), "extensionless", "DOCX"),
        (pptx::parts(), "presentation.bin", "PPTX"),
        (xlsx::parts(), "workbook.docx", "XLSX"),
    ] {
        let temporary = TemporaryFile::new(name, &archive(&parts)?)?;

        let document = parse_path(&temporary.path)?;

        assert_eq!(serde_json::to_value(document.kind)?, expected);
    }
    Ok(())
}

#[test]
fn output_schema_version_and_serialized_field_names_are_stable() -> TestResult {
    for parts in [docx::parts(), pptx::parts()] {
        let document = parse_reader(Cursor::new(archive(&parts)?))?;

        let json = serde_json::to_value(&document)?;

        assert_eq!(document.schema_version, 9);
        assert_eq!(json["schemaVersion"], 9);
        assert!(json.get("schema_version").is_none());
        assert!(json["warnings"].is_array());
        assert_eq!(json["sheets"], serde_json::json!([]));
        assert_eq!(json["cellStyles"], serde_json::json!([]));
        let element = match document.kind {
            Kind::DOCX => &json["blocks"][0],
            Kind::PPTX => &json["pages"][0]["elements"][0],
            Kind::XLSX => panic!("This fixture is a paged document"),
        };
        assert_eq!(element["type"], "TEXT");
        assert!(element["strokeWidth"].is_number());
        let expected = match document.kind {
            Kind::DOCX => serde_json::json!([1.0, 0.0, 0.0, 1.0, 0.0, 0.0]),
            Kind::PPTX => serde_json::json!([1.0, 0.0, 0.0, 1.0, 36.0, 24.0]),
            Kind::XLSX => panic!("This fixture is a paged document"),
        };
        assert_eq!(element["transform"], expected);
        assert!(element.get("flipH").is_none());
        assert!(element.get("flipV").is_none());
        assert!(element.get("columnWidths").is_none());
        assert!(element.get("rows").is_none());
        assert!(element.get("cellFills").is_none());
        assert!(element.get("paths").is_none());
        assert_eq!(element["verticalAlignment"], "TOP");
        assert!(element.get("imageCrop").is_none());
        assert!(element.get("imageBounds").is_none());
        assert_eq!(element["paragraphs"][0]["lineSpacingRule"], "AUTO");
        assert_eq!(element["paragraphs"][0]["lineSpacing"], 1.0);
        assert_eq!(element["paragraphs"][0]["firstLineIndent"], 0.0);
        assert!(element["paragraphs"][0].get("bullet").is_none());
        assert!(element.get("kind").is_none());
        assert!(element["paragraphs"][0]["runs"][0]["text"].is_string());
    }
    Ok(())
}

#[test]
fn sample_deliverables_match_rust_generator_and_parse_through_path_api() -> TestResult {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../demo/src/main/assets/samples");
    let mut names = fs::read_dir(&root)?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<Result<Vec<_>, _>>()?;
    names.sort();
    assert_eq!(
        names,
        ["sample.docx", "sample.pptx", "sample.xlsx"].map(std::ffi::OsString::from)
    );
    for (name, bytes, expected) in [
        (
            "sample.docx",
            archive(&support::docx_showcase::parts())?,
            "DOCX",
        ),
        (
            "sample.pptx",
            archive(&support::pptx_showcase::parts()?)?,
            "PPTX",
        ),
        (
            "sample.xlsx",
            archive(&support::xlsx_showcase::parts())?,
            "XLSX",
        ),
    ] {
        let path = root.join(name);
        assert_eq!(
            fs::read(&path)?,
            bytes,
            "Regenerate {name} with the fixtures example"
        );

        let document = parse_path(&path)?;

        assert_eq!(serde_json::to_value(&document.kind)?, expected);
        match document.kind {
            Kind::DOCX => assert!(!document.blocks.is_empty()),
            Kind::PPTX => assert_eq!(document.pages.len(), support::pptx_showcase::PAGE_COUNT),
            Kind::XLSX => assert_eq!(document.sheets.len(), 2),
        }
    }
    Ok(())
}

#[test]
fn samples_have_well_formed_xml_content_types_and_resolvable_relationships() -> TestResult {
    for parts in [
        docx::parts(),
        support::docx_showcase::parts(),
        pptx::parts(),
        support::pptx_charts::parts(),
        support::pptx_colors::parts(),
        support::pptx_compat::parts(),
        support::pptx_typography::parts(),
        support::pptx_wrapping::parts(),
        support::pptx_backgrounds::parts(),
        xlsx::parts(),
        support::xlsx_showcase::parts(),
    ] {
        check_package(&parts)?;
    }
    check_package(&support::pptx_showcase::parts()?)?;
    Ok(())
}

#[test]
fn pptx_color_fixture_matches_solid_reference_through_path_api() -> TestResult {
    let source = TemporaryFile::new(
        "pptx-colors.pptx",
        &archive(&support::pptx_colors::parts())?,
    )?;

    let document = parse_path(&source.path)?;

    assert_eq!(document.pages.len(), 2);
    for page in &document.pages {
        assert_eq!(page.background, 0xffff0000);
        assert_eq!(page.elements.len(), 1);
        let title = &page.elements[0];
        assert_eq!(
            [title.x, title.y, title.width, title.height],
            [100.0, 100.0, 520.0, 140.0]
        );
        assert_eq!(title.paragraphs.len(), 1);
        assert_eq!(title.paragraphs[0].runs.len(), 1);
        let run = &title.paragraphs[0].runs[0];
        assert_eq!(run.text, "Gold title");
        assert_eq!(run.size, 64.0);
        assert_eq!(run.color, 0xfffff3dd);
    }
    Ok(())
}

#[test]
fn search_path_to_json_contract_and_cache_across_all_formats() -> TestResult {
    // 1. PPTX: 检索 "first"（忽略大小写）
    let pptx_file = TemporaryFile::new("search.pptx", &archive(&pptx::parts())?)?;
    // 打开/序列化文档不会预建搜索索引；首次搜索应自行按需建立。
    let _ = parse_path_to_json(&pptx_file.path)?;
    let raw_json = search_path_to_json(&pptx_file.path, "first")?;
    let parsed: serde_json::Value = serde_json::from_str(&raw_json)?;
    assert!(parsed.is_array());
    let first = &parsed[0];
    assert_eq!(first["pageIndex"], 0);
    assert_eq!(first["elementIndex"], 0);
    assert_eq!(first["paragraphIndex"], 0);
    assert!(first.get("row").is_none());
    assert!(first.get("column").is_none());
    assert_eq!(first["startChar"], 0);
    assert_eq!(first["endChar"], 5);
    assert_eq!(first["snippet"], "First 中文");

    // 空关键词返回空 JSON 数组
    assert_eq!(search_path_to_json(&pptx_file.path, "")?, "[]");

    // 2. XLSX: 显式预热是可选优化，不影响后续检索结果。
    let xlsx_file = TemporaryFile::new("search.xlsx", &archive(&support::xlsx_showcase::parts())?)?;
    prewarm_search_index(&xlsx_file.path)?;
    let xlsx_matches = search_path(&xlsx_file.path, "JZ")?;
    let xlsx_json: serde_json::Value =
        serde_json::from_str(&search_path_to_json(&xlsx_file.path, "JZ")?)?;
    assert_eq!(xlsx_json.as_array().map(Vec::len), Some(xlsx_matches.len()));
    if let Some(m) = xlsx_matches.first() {
        assert!(m.row.is_some());
        assert!(m.column.is_some());
        assert!(m.end_char > m.start_char);
        assert!(xlsx_json[0]["row"].is_number());
        assert!(xlsx_json[0]["column"].is_number());
    }

    // 3. 缓存驱逐与清空后仍能正常回退重算
    evict_package_cache(&pptx_file.path);
    let after_evict = search_path(&pptx_file.path, "ENGLISH")?;
    assert_eq!(after_evict.len(), 1);
    assert_eq!(after_evict[0].page_index, 1);
    assert_eq!(after_evict[0].start_char, 7);
    assert_eq!(after_evict[0].end_char, 14);
    clear_package_cache();
    Ok(())
}

fn check_package<S: AsRef<str>>(parts: &[(S, Vec<u8>)]) -> TestResult {
    let bytes = archive(parts)?;
    let mut package = Package::new(Cursor::new(bytes))?;
    let types = package.read("[Content_Types].xml", 64 * 1024)?;
    let types = roxmltree::Document::parse(std::str::from_utf8(&types)?)?;
    for (name, bytes) in parts {
        let name = name.as_ref();
        if name.ends_with(".xml") || name.ends_with(".rels") {
            roxmltree::Document::parse(std::str::from_utf8(bytes)?)?;
        }
        if name != "[Content_Types].xml" {
            let absolute = format!("/{name}");
            let extension = name.rsplit('.').next();
            assert!(
                types.root_element().children().any(|node| {
                    node.attribute("PartName") == Some(absolute.as_str())
                        || (node.has_tag_name("Default")
                            && node.attribute("Extension") == extension)
                }),
                "Missing content type for {name}"
            );
        }
        let source = if name == "_rels/.rels" {
            Some(String::new())
        } else {
            name.split_once("/_rels/").and_then(|(prefix, leaf)| {
                leaf.strip_suffix(".rels")
                    .map(|leaf| format!("{prefix}/{leaf}"))
            })
        };
        if let Some(source) = source {
            for target in package.relationships(&source)?.values() {
                assert!(
                    package.has(target),
                    "Unresolved target {target} from {source}"
                );
            }
        }
    }
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
            "jz-office-fixtures-{}-{}",
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
