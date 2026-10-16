mod docx;
pub mod model;
mod package;
mod pptx;
pub mod spreadsheet;
mod xlsx;
mod xml;
mod zip_directory;

pub use package::Package;
use std::io::{Read, Seek};
use std::path::Path;

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

pub fn parse_reader(reader: impl Read + Seek + 'static) -> Result<model::Document> {
    let mut package = Package::new(reader)?;
    let part = package
        .related_by_type("", "officeDocument")?
        .ok_or(Error::Invalid(
            "Only DOCX, PPTX and XLSX packages are supported",
        ))?;
    let root = package.xml(&part)?;
    match root.name.as_str() {
        "document" => docx::parse(&mut package, &part),
        "presentation" => pptx::parse(&mut package, &part),
        "workbook" => xlsx::parse(&mut package, &part),
        _ => Err(Error::Invalid("Only DOCX, PPTX and XLSX are supported")),
    }
}
