use jni::objects::{JClass, JString};
use jni::sys::jstring;
use jni::JNIEnv;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

fn into_jni_string_or_throw(
    mut env: JNIEnv<'_>,
    result: std::thread::Result<Result<jstring, String>>,
    panic_message: &str,
) -> jstring {
    let message = match result {
        Ok(Ok(value)) => return value,
        Ok(Err(error)) => error,
        Err(_) => panic_message.to_owned(),
    };
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_clear();
    }
    if env.throw_new("java/io/IOException", message).is_err() {
        return std::ptr::null_mut();
    }
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "system" fn Java_cn_jingzhuan_lib_office_NativeCore_parse(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
) -> jstring {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<jstring, String> {
        let path: String = env.get_string(&path).map_err(|e| e.to_string())?.into();
        let json =
            jz_office_core::parse_path_to_json(Path::new(&path)).map_err(|e| e.to_string())?;
        env.new_string(json)
            .map(JString::into_raw)
            .map_err(|e| e.to_string())
    }));
    into_jni_string_or_throw(env, result, "Document parser failed")
}

#[no_mangle]
pub extern "system" fn Java_cn_jingzhuan_lib_office_NativeCore_parseFirstViewport(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
) -> jstring {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<jstring, String> {
        let path: String = env.get_string(&path).map_err(|e| e.to_string())?.into();
        let json = jz_office_core::parse_path_scoped_to_json(
            Path::new(&path),
            jz_office_core::Scope::FirstViewport,
        )
        .map_err(|e| e.to_string())?;
        env.new_string(json)
            .map(JString::into_raw)
            .map_err(|e| e.to_string())
    }));
    into_jni_string_or_throw(env, result, "Document parser failed")
}

#[no_mangle]
pub extern "system" fn Java_cn_jingzhuan_lib_office_NativeCore_metadata(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
) -> jstring {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<jstring, String> {
        let path: String = env.get_string(&path).map_err(|e| e.to_string())?.into();
        let json =
            jz_office_core::metadata_path_to_json(Path::new(&path)).map_err(|e| e.to_string())?;
        env.new_string(json)
            .map(JString::into_raw)
            .map_err(|e| e.to_string())
    }));
    into_jni_string_or_throw(env, result, "Document metadata reader failed")
}

#[no_mangle]
pub extern "system" fn Java_cn_jingzhuan_lib_office_NativeCore_prewarmSearchIndex(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
) {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<(), String> {
        let path: String = env.get_string(&path).map_err(|e| e.to_string())?.into();
        jz_office_core::prewarm_search_index(Path::new(&path)).map_err(|e| e.to_string())
    }));
    let message = match result {
        Ok(Ok(())) => return,
        Ok(Err(error)) => error,
        Err(_) => "Document search index prewarm failed".to_owned(),
    };
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_clear();
    }
    let _ = env.throw_new("java/io/IOException", message);
}

#[no_mangle]
pub extern "system" fn Java_cn_jingzhuan_lib_office_NativeCore_search(
    mut env: JNIEnv<'_>,
    _class: JClass<'_>,
    path: JString<'_>,
    query: JString<'_>,
) -> jstring {
    let result = catch_unwind(AssertUnwindSafe(|| -> Result<jstring, String> {
        let path: String = env.get_string(&path).map_err(|e| e.to_string())?.into();
        let query: String = env.get_string(&query).map_err(|e| e.to_string())?.into();
        let json = jz_office_core::search_path_to_json(Path::new(&path), &query)
            .map_err(|e| e.to_string())?;
        env.new_string(json)
            .map(JString::into_raw)
            .map_err(|e| e.to_string())
    }));
    into_jni_string_or_throw(env, result, "Document search failed")
}
