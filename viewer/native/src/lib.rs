use jni::objects::{JClass, JString};
use jni::sys::jstring;
use jni::JNIEnv;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;

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
    let message = match result {
        Ok(Ok(value)) => return value,
        Ok(Err(error)) => error,
        Err(_) => "Document parser failed".to_owned(),
    };
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_clear();
    }
    if env.throw_new("java/io/IOException", message).is_err() {
        return std::ptr::null_mut();
    }
    std::ptr::null_mut()
}
