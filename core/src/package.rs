use crate::xml::{self, Node};
use crate::{Error, Result};
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use zip::ZipArchive;

const MAX_INPUT: u64 = 128 * 1024 * 1024;
const MAX_EXPANDED: u64 = 256 * 1024 * 1024;

trait ReadSeek: Read + Seek {}
impl<T: Read + Seek> ReadSeek for T {}

pub struct Package {
    archive: ZipArchive<Box<dyn ReadSeek>>,
    read_bytes: u64,
}

impl Package {
    pub fn new(mut reader: impl Read + Seek + 'static) -> Result<Self> {
        let length = reader.seek(SeekFrom::End(0))?;
        if length > MAX_INPUT {
            return Err(Error::Limit("Input exceeds 128 MiB"));
        }
        let count = crate::zip_directory::entry_count(&mut reader, length)?;
        reader.seek(SeekFrom::Start(0))?;
        let mut archive = ZipArchive::new(Box::new(reader) as Box<dyn ReadSeek>)?;
        if archive.len() != count {
            return Err(Error::Invalid("Duplicate package entry"));
        }
        let mut expanded = 0_u64;
        for i in 0..archive.len() {
            let entry = archive.by_index(i)?;
            expanded = expanded
                .checked_add(entry.size())
                .ok_or(Error::Limit("Expanded package is too large"))?;
            if expanded > MAX_EXPANDED {
                return Err(Error::Limit("Expanded package exceeds 256 MiB"));
            }
        }
        Ok(Self {
            archive,
            read_bytes: 0,
        })
    }

    pub fn has(&self, part: &str) -> bool {
        self.archive.index_for_name(part).is_some()
    }

    pub(crate) fn xml(&mut self, part: &str) -> Result<Node> {
        let bytes = self.read(part, 4 * 1024 * 1024)?;
        xml::parse(bytes)
    }

    pub(crate) fn optional_xml(&mut self, part: &str) -> Result<Option<Node>> {
        if self.has(part) {
            self.xml(part).map(Some)
        } else {
            Ok(None)
        }
    }

    pub fn read(&mut self, part: &str, limit: u64) -> Result<Vec<u8>> {
        if !self.has(part) {
            return Err(Error::MissingPart(part.to_owned()));
        }
        let entry = self.archive.by_name(part)?;
        if entry.size() > limit {
            return Err(Error::Limit("Package part is too large"));
        }
        let mut bytes = Vec::new();
        entry.take(limit + 1).read_to_end(&mut bytes)?;
        let length =
            u64::try_from(bytes.len()).map_err(|_| Error::Limit("Package part is too large"))?;
        self.read_bytes += length;
        if length > limit || self.read_bytes > MAX_EXPANDED {
            return Err(Error::Limit("Package read budget exceeded"));
        }
        Ok(bytes)
    }

    fn relation_nodes(&mut self, source: &str) -> Result<Option<Node>> {
        let (dir, name) = source
            .rsplit_once('/')
            .map_or(("", source), |(d, n)| (d, n));
        let path = if dir.is_empty() {
            format!("_rels/{name}.rels")
        } else {
            format!("{dir}/_rels/{name}.rels")
        };
        self.optional_xml(&path)
    }

    pub fn relationships(&mut self, source: &str) -> Result<HashMap<String, String>> {
        let mut result = HashMap::new();
        if let Some(root) = self.relation_nodes(source)? {
            for node in root.named("Relationship") {
                if !node.attr("TargetMode").eq_ignore_ascii_case("External") {
                    result.insert(
                        node.attr("Id").to_owned(),
                        resolve(source, node.attr("Target"))?,
                    );
                }
            }
        }
        Ok(result)
    }

    pub fn related_by_type(&mut self, source: &str, kind: &str) -> Result<Option<String>> {
        let suffix = format!("/{kind}");
        if let Some(root) = self.relation_nodes(source)? {
            for node in root.named("Relationship") {
                if node.attr("Type").ends_with(&suffix)
                    && !node.attr("TargetMode").eq_ignore_ascii_case("External")
                {
                    return resolve(source, node.attr("Target")).map(Some);
                }
            }
        }
        Ok(None)
    }
}

fn resolve(source: &str, target: &str) -> Result<String> {
    if target.contains([':', '\\', '?', '#', '\0']) || target.starts_with("//") {
        return Err(Error::Invalid("Invalid internal package relationship"));
    }
    let mut decoded = Vec::new();
    let mut bytes = target.bytes();
    while let Some(byte) = bytes.next() {
        if byte == b'%' {
            let first = bytes.next().and_then(|b| char::from(b).to_digit(16));
            let second = bytes.next().and_then(|b| char::from(b).to_digit(16));
            match (first, second) {
                (Some(a), Some(b)) => decoded.push(
                    u8::try_from(a * 16 + b).map_err(|_| Error::Invalid("Invalid escaped path"))?,
                ),
                _ => return Err(Error::Invalid("Invalid escaped path")),
            }
        } else {
            decoded.push(byte);
        }
    }
    let target =
        String::from_utf8(decoded).map_err(|_| Error::Invalid("Invalid relationship encoding"))?;
    if target.contains([':', '\\', '?', '#', '\0']) {
        return Err(Error::Invalid("Invalid escaped relationship"));
    }
    let mut parts: Vec<&str> = if target.starts_with('/') {
        Vec::new()
    } else {
        source
            .rsplit_once('/')
            .map_or(Vec::new(), |(dir, _)| dir.split('/').collect())
    };
    for part in target.split('/') {
        match part {
            "" | "." => (),
            ".." => {
                parts
                    .pop()
                    .ok_or(Error::Invalid("Relationship escapes package root"))?;
            }
            value => parts.push(value),
        }
    }
    if parts.is_empty() {
        return Err(Error::Invalid("Empty package target"));
    }
    Ok(parts.join("/"))
}
