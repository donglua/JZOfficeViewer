// 豁免 #[napi] 宏自动展开代码中的内部 unsafe 块注释检查，确保 workspace clippy 门禁通过
#![allow(clippy::undocumented_unsafe_blocks)]

use napi_derive_ohos::napi;
use napi_ohos::bindgen_prelude::*;
use napi_ohos::{Env, Error, Result, Task};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

fn parse_path_to_json(path: &str) -> Result<String> {
    let result = catch_unwind(AssertUnwindSafe(
        || -> std::result::Result<String, String> {
            jz_office_core::parse_path_to_json(Path::new(path)).map_err(|e| e.to_string())
        },
    ));

    match result {
        Ok(Ok(json)) => Ok(json),
        Ok(Err(error)) => Err(Error::from_reason(error)),
        Err(_) => Err(Error::from_reason("Document parser failed".to_owned())),
    }
}

fn create_arraybuffer_from_vec(env: &Env, data: Vec<u8>) -> Result<ArrayBuffer<'static>> {
    let mut raw_value = std::ptr::null_mut();
    let mut data_ptr = std::ptr::null_mut();
    let len = data.len();
    let status = unsafe {
        napi_ohos::sys::napi_create_arraybuffer(env.raw(), len, &mut data_ptr, &mut raw_value)
    };
    if status != napi_ohos::sys::Status::napi_ok {
        return Err(Error::from_status(Status::from(status)));
    }
    if !data_ptr.is_null() && len > 0 {
        unsafe {
            std::ptr::copy_nonoverlapping(data.as_ptr(), data_ptr.cast(), len);
        }
    }
    unsafe { ArrayBuffer::from_napi_value(env.raw(), raw_value) }
}

fn read_zip_part_bytes(path: &str, part: &str) -> Result<Vec<u8>> {
    let result = catch_unwind(AssertUnwindSafe(
        || -> std::result::Result<Vec<u8>, String> {
            jz_office_core::read_part(Path::new(path), part).map_err(|e| e.to_string())
        },
    ));

    match result {
        Ok(Ok(data)) => Ok(data),
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
    type Output = Vec<u8>;
    type JsValue = ArrayBuffer<'static>;

    fn compute(&mut self) -> Result<Self::Output> {
        read_zip_part_bytes(&self.path, &self.part)
    }

    fn resolve(&mut self, env: Env, output: Self::Output) -> Result<Self::JsValue> {
        create_arraybuffer_from_vec(&env, output)
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
pub fn read_part(env: Env, path: String, part: String) -> Result<ArrayBuffer<'static>> {
    let bytes = read_zip_part_bytes(&path, &part)?;
    create_arraybuffer_from_vec(&env, bytes)
}

/// 清除当前缓存的所有文档包及 ZIP 索引句柄
#[napi]
pub fn clear_cache() -> Result<()> {
    jz_office_core::clear_package_cache();
    Ok(())
}

/// 精准清除指定文档路径在底层缓存的包句柄与 ZIP 索引
#[napi]
pub fn evict_cache(path: String) -> Result<()> {
    let result = catch_unwind(AssertUnwindSafe(|| {
        jz_office_core::evict_package_cache(Path::new(&path));
    }));
    match result {
        Ok(()) => Ok(()),
        Err(_) => Err(Error::from_reason(
            "Failed to evict package cache".to_owned(),
        )),
    }
}
