// 豁免 #[napi] 宏自动展开代码中的内部 unsafe 块注释检查，确保 workspace clippy 门禁通过
#![allow(clippy::undocumented_unsafe_blocks)]

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use napi_ohos::{Env, Error, Result, Task};
use std::fs::File;
use std::io::Read;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use zip::ZipArchive;

const MEDIA_PART_LIMIT: usize = 16 * 1024 * 1024; // 16 MiB

fn parse_path_to_json(path: &str) -> Result<String> {
    let result = catch_unwind(AssertUnwindSafe(
        || -> std::result::Result<String, String> {
            let document =
                jz_office_core::parse_path(Path::new(path)).map_err(|e| e.to_string())?;
            serde_json::to_string(&document).map_err(|e| e.to_string())
        },
    ));

    match result {
        Ok(Ok(json)) => Ok(json),
        Ok(Err(error)) => Err(Error::from_reason(error)),
        Err(_) => Err(Error::from_reason("Document parser failed".to_owned())),
    }
}

fn read_zip_part(path: &str, part: &str) -> Result<Buffer> {
    let result = catch_unwind(AssertUnwindSafe(
        || -> std::result::Result<Vec<u8>, String> {
            let file = File::open(path).map_err(|e| e.to_string())?;
            let mut archive = ZipArchive::new(file).map_err(|e| e.to_string())?;
            let entry = archive.by_name(part).map_err(|e| e.to_string())?;

            let size = entry.size();
            if size > MEDIA_PART_LIMIT as u64 {
                return Err("Document part exceeds 16 MiB limit".to_string());
            }

            let cap = usize::try_from(size).unwrap_or(0);
            let mut buf = Vec::with_capacity(cap);
            entry
                .take((MEDIA_PART_LIMIT as u64) + 1)
                .read_to_end(&mut buf)
                .map_err(|e| e.to_string())?;
            if buf.len() > MEDIA_PART_LIMIT {
                return Err("Document part exceeds 16 MiB limit".to_string());
            }
            Ok(buf)
        },
    ));

    match result {
        Ok(Ok(data)) => Ok(Buffer::from(data)),
        Ok(Err(error)) => Err(Error::from_reason(error)),
        Err(_) => Err(Error::from_reason(
            "Failed to read document part".to_owned(),
        )),
    }
}

/// 同步解析接口（对齐 Android NativeCore.parse）
#[napi]
pub fn parse(path: String) -> Result<String> {
    parse_path_to_json(&path)
}

pub struct ParseDocumentTask {
    path: String,
}

#[napi]
impl Task for ParseDocumentTask {
    type Output = String;
    type JsValue = String;

    fn compute(&mut self) -> Result<Self::Output> {
        parse_path_to_json(&self.path)
    }

    fn resolve(&mut self, _env: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output)
    }
}

/// 异步解析接口（使用鸿蒙底层 libuv Worker 线程池，不阻塞 ArkUI 主线程）
#[napi]
pub fn parse_async(
    path: String,
    abort_signal: Option<AbortSignal>,
) -> AsyncTask<ParseDocumentTask> {
    AsyncTask::with_optional_signal(ParseDocumentTask { path }, abort_signal)
}

pub struct ReadPartTask {
    path: String,
    part: String,
}

#[napi]
impl Task for ReadPartTask {
    type Output = Buffer;
    type JsValue = Buffer;

    fn compute(&mut self) -> Result<Self::Output> {
        read_zip_part(&self.path, &self.part)
    }

    fn resolve(&mut self, _env: Env, output: Self::Output) -> Result<Self::JsValue> {
        Ok(output)
    }
}

/// 异步读取文档 ZIP 包内指定部件字节流（用于按需加载内嵌图片）
#[napi]
pub fn read_part_async(
    path: String,
    part: String,
    abort_signal: Option<AbortSignal>,
) -> AsyncTask<ReadPartTask> {
    AsyncTask::with_optional_signal(ReadPartTask { path, part }, abort_signal)
}

/// 同步读取文档 ZIP 包内指定部件字节流
#[napi]
pub fn read_part(path: String, part: String) -> Result<Buffer> {
    read_zip_part(&path, &part)
}
