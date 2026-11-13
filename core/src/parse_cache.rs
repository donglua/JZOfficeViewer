//! 解析结果复用缓存：按 文件路径 + 大小 + 修改时间 + 解析范围 命中，避免同一文件被重复解析。
//!
//! 典型场景是对同一文件连续执行「元数据 → 缩略图 → 打开预览」，或在列表与详情之间来回切换。
//! 缓存保存最终 JSON 字符串（跨语言协议），命中时连序列化一并省去。
//!
//! 复用遵循「更完整的结果可以服务更小的范围」：完整解析的结果可直接用于缩略图，因此先打开
//! 预览再生成封面不会再解析一次。反向不成立——首屏结果缺页数、元数据结果缺内容，都必须重算。
//! 元数据速读与文档解析是两个不同协议家族，互不复用，避免页数语义错配。

use crate::Scope;
use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;

/// 缓存条目数上限
const MAX_CACHED_RESULTS: usize = 4;
/// 单条结果上限：更大的文档缓存收益低于常驻内存成本，直接跳过缓存正常返回
const MAX_ENTRY_BYTES: usize = 4 * 1024 * 1024;
/// 全部条目总占用上限
const MAX_TOTAL_BYTES: usize = 8 * 1024 * 1024;

/// 缓存家族：元数据速读与文档解析的输出协议不同，按家族隔离，绝不互相复用
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Family {
    /// `metadata::read` 的空壳模型，页数语义与完整解析一致
    Metadata,
    /// 文档解析，按 `Scope` 区分完整程度
    Document(Scope),
}

impl Family {
    /// 该家族结果是否可以满足另一请求。文档解析按完整程度排序，完整结果覆盖首屏请求。
    fn serves(self, requested: Family) -> bool {
        match (self, requested) {
            (Self::Metadata, Self::Metadata) => true,
            (Self::Document(available), Self::Document(expected)) => match available {
                Scope::Full => true,
                Scope::FirstViewport => expected == Scope::FirstViewport,
            },
            _ => false,
        }
    }
}

struct CachedResult {
    path: PathBuf,
    len: u64,
    modified: Option<SystemTime>,
    family: Family,
    json: Arc<String>,
}

#[derive(Default)]
struct Cache {
    entries: VecDeque<CachedResult>,
    bytes: usize,
}

static GLOBAL_CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();

fn get_cache() -> &'static Mutex<Cache> {
    GLOBAL_CACHE.get_or_init(|| Mutex::new(Cache::default()))
}

/// 清空全部解析结果缓存
pub(crate) fn clear() {
    if let Ok(mut cache) = get_cache().lock() {
        cache.entries.clear();
        cache.bytes = 0;
    }
}

/// 淘汰指定路径的解析结果缓存（文件被替换或显式清理时调用）
pub(crate) fn evict(path: &Path) {
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    if let Ok(mut cache) = get_cache().lock() {
        let mut bytes = 0;
        cache.entries.retain(|entry| {
            let keep = entry.path != canonical && entry.path != path;
            if keep {
                bytes += entry.json.len();
            }
            keep
        });
        cache.bytes = bytes;
    }
}

/// 查询缓存；命中时把条目移到队尾以维持 LRU 顺序
fn lookup(
    path: &Path,
    len: u64,
    modified: Option<SystemTime>,
    requested: Family,
) -> Option<Arc<String>> {
    let mut cache = get_cache().lock().ok()?;
    let index = cache.entries.iter().position(|entry| {
        entry.path == path
            && entry.len == len
            && entry.modified == modified
            && entry.family.serves(requested)
    })?;
    let entry = cache.entries.remove(index)?;
    let json = Arc::clone(&entry.json);
    cache.entries.push_back(entry);
    Some(json)
}

fn store(
    path: PathBuf,
    len: u64,
    modified: Option<SystemTime>,
    family: Family,
    json: &Arc<String>,
) {
    if json.len() > MAX_ENTRY_BYTES {
        return;
    }
    let Ok(mut cache) = get_cache().lock() else {
        return;
    };
    // 同一路径同家族的旧结果不再保留：同键内容已变，或新结果至少同样完整
    let mut bytes = 0;
    cache.entries.retain(|entry| {
        let keep = entry.path != path || !entry.family.serves(family);
        if keep {
            bytes += entry.json.len();
        }
        keep
    });
    while !cache.entries.is_empty()
        && (cache.entries.len() >= MAX_CACHED_RESULTS || bytes + json.len() > MAX_TOTAL_BYTES)
    {
        match cache.entries.pop_front() {
            Some(dropped) => bytes = bytes.saturating_sub(dropped.json.len()),
            None => break,
        }
    }
    if bytes + json.len() > MAX_TOTAL_BYTES {
        cache.bytes = bytes;
        return;
    }
    cache.bytes = bytes + json.len();
    cache.entries.push_back(CachedResult {
        path,
        len,
        modified,
        family,
        json: Arc::clone(json),
    });
}

/// 带缓存的解析入口：同一文件与范围在内容未变化时直接返回上次的 JSON
pub(crate) fn cached_json<F>(path: &Path, family: Family, build: F) -> crate::Result<String>
where
    F: FnOnce() -> crate::Result<String>,
{
    let canonical = fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    // 文件元数据读取失败时不阻断主流程，交给 build 给出准确的错误
    let metadata = fs::metadata(&canonical).ok();
    let len = metadata.as_ref().map_or(0, fs::Metadata::len);
    let modified = metadata.as_ref().and_then(|m| m.modified().ok());
    if metadata.is_some() {
        if let Some(json) = lookup(&canonical, len, modified, family) {
            return Ok(json.as_str().to_owned());
        }
    }
    let json = build()?;
    if metadata.is_some() {
        let json = Arc::new(json);
        store(canonical, len, modified, family, &json);
        return Ok(json.as_str().to_owned());
    }
    Ok(json)
}
