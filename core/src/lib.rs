mod docx;
mod metadata;
pub mod model;
pub(crate) mod numbering;
mod package;
mod package_cache;
mod parse_cache;
mod pptx;
pub mod search;
pub mod spreadsheet;
mod xlsx;
mod xml;
mod zip_directory;

pub use package::Package;
pub use search::{
    prewarm_search_index, search_document, search_path, search_path_to_json,
    MAX_CACHED_SEARCH_INDEXES, MAX_CACHED_SEARCH_INDEX_BYTES, MAX_CACHED_SEARCH_INDEX_ENTRIES,
    MAX_SEARCH_MATCHES,
};
use std::io::{Read, Seek};
use std::path::Path;

pub const MEDIA_PART_LIMIT: u64 = 16 * 1024 * 1024; // 16 MiB

/// 解析范围的粗粒度声明。完整解析用于打开预览，首屏/元数据范围用于列表与封面，
/// 避免「只读页数」或「只画第一页」承担整篇文档的解析成本。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Scope {
    /// 完整解析：全部幻灯片、全部工作表、DOCX 全部正文块
    Full,
    /// 首屏解析：PPTX 只渲染首张幻灯片，XLSX 只解析首个工作表，DOCX 只解析首屏块
    FirstViewport,
}

impl Scope {
    /// DOCX 首屏解析的正文块预算。按 14pt 行高与 6pt 段后距推算，约 40 块足以铺满一张 A4 首页，
    /// 再多不改变封面像素，只增加排版时间。
    const FIRST_VIEWPORT_BLOCKS: usize = 40;

    /// 该范围下 DOCX 允许解析的正文块数量；`None` 表示不设额外预算
    pub(crate) fn block_budget(self) -> Option<usize> {
        match self {
            Self::Full => None,
            Self::FirstViewport => Some(Self::FIRST_VIEWPORT_BLOCKS),
        }
    }
}

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

/// 解析完整文档模型。默认不构建全文检索索引；索引会在首次搜索时按需建立。
pub fn parse_path(path: &Path) -> Result<model::Document> {
    parse_reader(std::fs::File::open(path)?)
}

pub fn parse_path_to_json(path: &Path) -> Result<String> {
    let document = parse_path(path)?;
    let json = serde_json::to_string(&document)?;
    drop(document);
    Ok(json)
}

/// 按指定范围解析文件，并在解析结果缓存中复用上次结果。
///
/// 同一文件连续执行「元数据 → 缩略图 → 打开预览」时，缓存以 路径 + 大小 + 修改时间 + 范围
/// 作为键命中，跳过重复的 ZIP 解压、XML 解析与 JSON 序列化。
pub fn parse_path_scoped_to_json(path: &Path, scope: Scope) -> Result<String> {
    parse_cache::cached_json(path, parse_cache::Family::Document(scope), || {
        let document = parse_reader_scoped(std::fs::File::open(path)?, scope)?;
        let json = serde_json::to_string(&document)?;
        drop(document);
        Ok(json)
    })
}

/// 轻量元数据速读：只读取格式与页数所需的部件，输出与完整解析同形的空壳模型
pub fn metadata_path_to_json(path: &Path) -> Result<String> {
    parse_cache::cached_json(path, parse_cache::Family::Metadata, || {
        let mut package = Package::new(std::fs::File::open(path)?)?;
        let document = metadata::read(&mut package)?;
        Ok(serde_json::to_string(&document)?)
    })
}

pub fn parse_reader(reader: impl Read + Seek + Send + 'static) -> Result<model::Document> {
    parse_reader_scoped(reader, Scope::Full)
}

/// 按指定范围从 reader 解析，供测试与无文件场景使用
pub fn parse_reader_scoped(
    reader: impl Read + Seek + Send + 'static,
    scope: Scope,
) -> Result<model::Document> {
    let mut package = Package::new(reader)?;
    parse_package(&mut package, scope)
}

pub(crate) fn parse_package(package: &mut Package, scope: Scope) -> Result<model::Document> {
    let part = package
        .related_by_type("", "officeDocument")?
        .ok_or(Error::Invalid(
            "Only DOCX, PPTX and XLSX packages are supported",
        ))?;
    let root = package.xml(&part)?;
    match root.name.as_str() {
        "document" => docx::parse(package, &part, scope),
        "presentation" => pptx::parse(package, &part, scope),
        "workbook" => xlsx::parse(package, &part, scope),
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

/// 清空当前已打开的文档包缓存、ZIP 索引句柄、检索文本缓存与解析结果缓存
pub fn clear_package_cache() {
    package_cache::clear();
    search::clear_cache();
    parse_cache::clear();
}

/// 从全局 Package 缓存、检索文本缓存与解析结果缓存中精准淘汰指定路径
pub fn evict_package_cache(path: &Path) {
    package_cache::evict(path);
    search::evict_cache(path);
    parse_cache::evict(path);
}
