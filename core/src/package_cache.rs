use crate::package::Package;
use crate::{Error, Result};
use std::collections::VecDeque;
use std::fs::{self, File};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;

const MAX_CACHED_PACKAGES: usize = 4;

struct CacheEntry {
    path: PathBuf,
    len: u64,
    modified: Option<SystemTime>,
    package: Mutex<Package>,
}

#[derive(Default)]
struct Cache {
    entries: VecDeque<Arc<CacheEntry>>,
}

static GLOBAL_CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();

fn get_cache() -> &'static Mutex<Cache> {
    GLOBAL_CACHE.get_or_init(|| Mutex::new(Cache::default()))
}

pub(crate) fn clear() {
    if let Ok(mut cache) = get_cache().lock() {
        cache.entries.clear();
    }
}

pub(crate) fn evict(path: &Path) {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if let Ok(mut cache) = get_cache().lock() {
        cache
            .entries
            .retain(|item| item.path != canonical && item.path != path);
    }
}

pub(crate) fn read_part(path: &Path, part: &str, limit: u64) -> Result<Vec<u8>> {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let metadata = fs::metadata(&canonical)?;
    let len = metadata.len();
    let modified = metadata.modified().ok();

    let entry = {
        let mut cache = get_cache()
            .lock()
            .map_err(|_| Error::Invalid("Package cache lock poisoned"))?;

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
                cache.entries.push_back(Arc::clone(&item));
                item
            } else {
                return Err(Error::Invalid("Unexpected cache state"));
            }
        } else {
            cache.entries.retain(|item| item.path != canonical);
            while cache.entries.len() >= MAX_CACHED_PACKAGES {
                cache.entries.pop_front();
            }

            let file = File::open(&canonical)?;
            let package = Package::new(file)?;
            let new_entry = Arc::new(CacheEntry {
                path: canonical,
                len,
                modified,
                package: Mutex::new(package),
            });
            cache.entries.push_back(Arc::clone(&new_entry));
            new_entry
        }
    };

    let mut package = entry
        .package
        .lock()
        .map_err(|_| Error::Invalid("Package lock poisoned"))?;
    package.read(part, limit)
}
