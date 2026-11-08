use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

/// C-ABI 字符串返回结果：成功时 `data` 非空、`error` 为空；失败时 `data` 为空、`error` 非空
#[repr(C)]
pub struct JZStringResult {
    pub data: *mut c_char,
    pub error: *mut c_char,
}

/// C-ABI 字节数组返回结果：成功时 `data` 非空（或空切片）、`error` 为空；失败时 `error` 非空
#[repr(C)]
pub struct JZBytesResult {
    pub data: *mut u8,
    pub len: usize,
    pub error: *mut c_char,
}

fn into_c_string_ptr(text: String) -> *mut c_char {
    let sanitized = if text.as_bytes().contains(&0) {
        text.replace('\0', " ")
    } else {
        text
    };
    match CString::new(sanitized) {
        Ok(cstr) => cstr.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// # Safety
/// `ptr` 必须为有效的以 `\0` 结尾的 UTF-8 C 字符串指针，或为空指针。
unsafe fn c_str_to_string(ptr: *const c_char) -> Result<String, String> {
    if ptr.is_null() {
        return Err("Null string pointer".to_owned());
    }
    // SAFETY: 调用方保证 ptr 指向有效的以 '\0' 结尾的 C 字符串内存。
    let cstr = unsafe { CStr::from_ptr(ptr) };
    cstr.to_str()
        .map(str::to_owned)
        .map_err(|e| format!("Invalid UTF-8 string: {e}"))
}

/// 解析指定路径的 Office 文档（DOCX / PPTX / XLSX），返回 `schemaVersion: 9` 的 JSON 字符串。
///
/// # Safety
/// `path_utf8` 必须为有效的以 `\0` 结尾的 C 字符串指针；返回值中的 `data` 或 `error` 必须通过 `jz_office_free_string` 释放。
#[no_mangle]
pub unsafe extern "C" fn jz_office_parse_path(path_utf8: *const c_char) -> JZStringResult {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<String, String> {
        // SAFETY: 委托 c_str_to_string 检查空指针并按 C 字符串解析。
        let path_str = unsafe { c_str_to_string(path_utf8)? };
        jz_office_core::parse_path_to_json(Path::new(&path_str)).map_err(|e| e.to_string())
    }));

    match outcome {
        Ok(Ok(json)) => JZStringResult {
            data: into_c_string_ptr(json),
            error: std::ptr::null_mut(),
        },
        Ok(Err(err)) => JZStringResult {
            data: std::ptr::null_mut(),
            error: into_c_string_ptr(err),
        },
        Err(_) => JZStringResult {
            data: std::ptr::null_mut(),
            error: into_c_string_ptr("Document parser panicked".to_owned()),
        },
    }
}

/// 从指定文档包中按需读取内嵌部件（如图片媒体资源），受 16 MiB 单部件与 256 MiB 累计解压预算保护。
///
/// # Safety
/// `path_utf8` 与 `part_utf8` 必须为有效的以 `\0` 结尾的 C 字符串指针；
/// 返回值中的 `data` 必须通过 `jz_office_free_bytes(data, len)` 释放，`error` 必须通过 `jz_office_free_string(error)` 释放。
#[no_mangle]
pub unsafe extern "C" fn jz_office_read_part(
    path_utf8: *const c_char,
    part_utf8: *const c_char,
) -> JZBytesResult {
    let outcome = catch_unwind(AssertUnwindSafe(|| -> Result<Vec<u8>, String> {
        // SAFETY: 委托 c_str_to_string 检查空指针并按 C 字符串解析。
        let path_str = unsafe { c_str_to_string(path_utf8)? };
        // SAFETY: 委托 c_str_to_string 检查空指针并按 C 字符串解析。
        let part_str = unsafe { c_str_to_string(part_utf8)? };
        jz_office_core::read_part(Path::new(&path_str), &part_str).map_err(|e| e.to_string())
    }));

    match outcome {
        Ok(Ok(bytes)) => {
            let boxed: Box<[u8]> = bytes.into_boxed_slice();
            let len = boxed.len();
            let raw_slice = Box::into_raw(boxed);
            JZBytesResult {
                data: raw_slice.cast::<u8>(),
                len,
                error: std::ptr::null_mut(),
            }
        }
        Ok(Err(err)) => JZBytesResult {
            data: std::ptr::null_mut(),
            len: 0,
            error: into_c_string_ptr(err),
        },
        Err(_) => JZBytesResult {
            data: std::ptr::null_mut(),
            len: 0,
            error: into_c_string_ptr("Failed to read document part".to_owned()),
        },
    }
}

/// 从底层文档包缓存中淘汰指定路径的 ZIP 句柄与索引。
///
/// # Safety
/// `path_utf8` 必须为有效的以 `\0` 结尾的 C 字符串指针。
#[no_mangle]
pub unsafe extern "C" fn jz_office_evict_cache(path_utf8: *const c_char) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: 委托 c_str_to_string 检查空指针并按 C 字符串解析。
        if let Ok(path_str) = unsafe { c_str_to_string(path_utf8) } {
            jz_office_core::evict_package_cache(Path::new(&path_str));
        }
    }));
}

/// 清空底层所有已缓存的文档包句柄。
#[no_mangle]
pub extern "C" fn jz_office_clear_cache() {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        jz_office_core::clear_package_cache();
    }));
}

/// 释放由 `jz_office_parse_path` 或 `jz_office_read_part` 分配的 C 字符串。
///
/// # Safety
/// `ptr` 必须是由本库通过 `CString::into_raw` 分配的指针，或为空指针。
#[no_mangle]
pub unsafe extern "C" fn jz_office_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: ptr 由本库 CString::into_raw 创建且仅在此处释放一次。
        let _ = unsafe { CString::from_raw(ptr) };
    }
}

/// 释放由 `jz_office_read_part` 分配的字节缓冲区。
///
/// # Safety
/// `ptr` 与 `len` 必须是由本库 `Box<[u8]>` 导出的原始指针与长度，或 `ptr` 为空指针。
#[no_mangle]
pub unsafe extern "C" fn jz_office_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        // SAFETY: ptr 与 len 由本库 Box::<[u8]>::into_raw 创建且仅在此处释放一次。
        let slice_ptr = std::ptr::slice_from_raw_parts_mut(ptr, len);
        // SAFETY: slice_ptr 对应完整的 Box<[u8]> 内存块。
        let _ = unsafe { Box::from_raw(slice_ptr) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn null_path_returns_clean_error_without_panic() {
        // SAFETY: 测试空指针防护逻辑。
        let res = unsafe { jz_office_parse_path(std::ptr::null()) };
        assert!(res.data.is_null());
        assert!(!res.error.is_null());
        // SAFETY: 释放返回的错误字符串。
        unsafe { jz_office_free_string(res.error) };
    }

    #[test]
    fn missing_file_returns_error_and_frees_cleanly() {
        let path = CString::new("/nonexistent/jz-office-missing.docx").unwrap_or_default();
        // SAFETY: path 为合法 CString，结果通过 jz_office_free_string 释放。
        let res = unsafe { jz_office_parse_path(path.as_ptr()) };
        assert!(res.data.is_null());
        assert!(!res.error.is_null());
        // SAFETY: 释放错误字符串。
        unsafe { jz_office_free_string(res.error) };
    }
}
