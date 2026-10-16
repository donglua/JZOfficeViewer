mod docx;
pub mod model;
mod package;
mod package_cache;
mod pptx;
pub mod spreadsheet;
mod xlsx;
mod xml;
mod zip_directory;

pub use package::Package;
use std::io::{Read, Seek};
use std::path::Path;

pub const MEDIA_PART_LIMIT: u64 = 16 * 1024 * 1024; // 16 MiB

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Io(#[from] std::io::Error),
    #[error("Invalid Office ZIP: {0}")]
    Zip(#[from] zip::result::ZipError),
    #[error("Invalid Office XML: {0}")]
    Xml(#[from] roxmltree::Error),
    #[error("{0}")]
    Invalid(&'static str),
    #[error("{0}")]
    Limit(&'static str),
    #[error("Missing package part: {0}")]
    MissingPart(String),
    #[error("Document serialization failed: {0}")]
    Json(#[from] serde_json::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

pub fn parse_path(path: &Path) -> Result<model::Document> {
    parse_reader(std::fs::File::open(path)?)
}

pub fn parse_path_to_json(path: &Path) -> Result<String> {
    let document = parse_path(path)?;
    let json = serde_json::to_string(&document)?;
    drop(document);
    Ok(json)
}

pub fn parse_reader(reader: impl Read + Seek + Send + 'static) -> Result<model::Document> {
    let mut package = Package::new(reader)?;
    parse_package(&mut package)
}

pub(crate) fn parse_package(package: &mut Package) -> Result<model::Document> {
    let part = package
        .related_by_type("", "officeDocument")?
        .ok_or(Error::Invalid(
            "Only DOCX, PPTX and XLSX packages are supported",
        ))?;
    let root = package.xml(&part)?;
    match root.name.as_str() {
        "document" => docx::parse(package, &part),
        "presentation" => pptx::parse(package, &part),
        "workbook" => xlsx::parse(package, &part),
        _ => Err(Error::Invalid("Only DOCX, PPTX and XLSX are supported")),
    }
}

/// 从指定文档包中安全读取指定部件（如内嵌图片等媒体资源），采用默认 16 MiB 单部件限制
pub fn read_part(path: &Path, part: &str) -> Result<Vec<u8>> {
    read_part_limited(path, part, MEDIA_PART_LIMIT)
}

/// 从指定文档包中受控读取指定部件，校验单部件上限并在全局 Package 缓存中累计跟踪 256 MiB 解压预算
pub fn read_part_limited(path: &Path, part: &str, limit: u64) -> Result<Vec<u8>> {
    package_cache::read_part(path, part, limit)
}

/// 清空当前已打开的文档包缓存及 ZIP 索引句柄
pub fn clear_package_cache() {
    package_cache::clear();
}
