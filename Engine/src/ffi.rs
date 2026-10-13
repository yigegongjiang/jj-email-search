use crate::{
    engine::{Engine, Progress},
    thunderbird,
};
use anyhow::{Context, Result, bail};
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char, c_void},
    panic::{AssertUnwindSafe, catch_unwind},
    path::PathBuf,
    sync::{Arc, Mutex},
};
struct Handle {
    engine: Mutex<Option<Engine>>,
    progress: Arc<Progress>,
    directory: PathBuf,
}
fn response(result: Result<Value>) -> Value {
    match result {
        Ok(v) => json!({"ok":true,"data":v}),
        Err(e) => json!({"ok":false,"error":format!("{e:#}")}),
    }
}
fn string(v: Value) -> *mut c_char {
    CString::new(v.to_string()).unwrap().into_raw()
}
fn get_str<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v.get(k)
        .and_then(Value::as_str)
        .with_context(|| format!("Missing parameter {k}"))
}
/// JSON protocol is shared by the App and diagnostic CLI; private mail contents
/// are never logged by the engine. The engine mutex serializes operations.
pub fn dispatch(engine: &mut Engine, v: &Value) -> Result<Value> {
    match get_str(v, "op")? {
        "status" => engine.status(),
        "discover" => {
            let root = v
                .get("root")
                .and_then(Value::as_str)
                .map(PathBuf::from)
                .unwrap_or(
                    std::env::var("HOME")
                        .map(PathBuf::from)?
                        .join("Library/Thunderbird"),
                );
            Ok(serde_json::to_value(thunderbird::discover(&root)?)?)
        }
        "sync" => {
            let root = v
                .get("root")
                .and_then(Value::as_str)
                .map(PathBuf::from)
                .unwrap_or(
                    std::env::var("HOME")
                        .map(PathBuf::from)?
                        .join("Library/Thunderbird"),
                );
            let wanted: Vec<String> =
                serde_json::from_value(v.get("folders").cloned().context("Missing folders")?)?;
            let discovered = thunderbird::discover(&root)?;
            let selected: Vec<_> = discovered
                .into_iter()
                .filter(|f| wanted.contains(&f.id))
                .collect();
            anyhow::ensure!(
                selected.len() == wanted.len(),
                "所选源文件夹已变化，请刷新文件夹列表"
            );
            engine.sync(&selected)
        }
        "search" => {
            let folders: Vec<String> =
                serde_json::from_value(v.get("folders").cloned().unwrap_or(json!([])))?;
            engine.search(
                &folders,
                v.get("query").and_then(Value::as_str).unwrap_or(""),
                v.get("field").and_then(Value::as_str).unwrap_or("all"),
            )
        }
        "preview" => engine.preview(get_str(v, "id")?),
        "export" => engine.export(
            get_str(v, "id")?,
            v.get("attachment")
                .and_then(Value::as_u64)
                .map(|v| v as u32),
            &PathBuf::from(get_str(v, "path")?),
        ),
        _ => bail!("Unknown engine operation"),
    }
}
/// # Safety
/// `directory` must point to a valid NUL-terminated string for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jj_engine_open(directory: *const c_char) -> *mut c_void {
    if directory.is_null() {
        return std::ptr::null_mut();
    }
    let result = catch_unwind(AssertUnwindSafe(|| {
        let path = unsafe { CStr::from_ptr(directory) }.to_str().ok()?;
        Some(Box::into_raw(Box::new(Handle {
            engine: Mutex::new(None),
            progress: Arc::new(Progress::default()),
            directory: PathBuf::from(path),
        })) as *mut c_void)
    }));
    result.ok().flatten().unwrap_or(std::ptr::null_mut())
}
/// # Safety
/// `handle` must be live and `request` a valid NUL-terminated string. Close must not run concurrently.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jj_engine_call(
    handle: *mut c_void,
    request: *const c_char,
) -> *mut c_char {
    if handle.is_null() || request.is_null() {
        return string(json!({"ok":false,"error":"Invalid engine pointer"}));
    }
    let r = catch_unwind(AssertUnwindSafe(|| -> Result<Value> {
        let h = unsafe { &*(handle as *const Handle) };
        let v: Value = serde_json::from_slice(unsafe { CStr::from_ptr(request) }.to_bytes())?;
        let mut guard = h
            .engine
            .lock()
            .map_err(|_| anyhow::anyhow!("Engine failure; restart App"))?;
        if guard.is_none() {
            *guard = Some(Engine::open(&h.directory, h.progress.clone())?);
        }
        dispatch(guard.as_mut().unwrap(), &v)
    }));
    string(match r {
        Ok(v) => response(v),
        Err(_) => json!({"ok":false,"error":"Engine panic contained; restart App"}),
    })
}
/// # Safety
/// `handle` must be live; close must not run concurrently.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jj_engine_progress(handle: *mut c_void) -> *mut c_char {
    if handle.is_null() {
        return string(json!({}));
    }
    let h = unsafe { &*(handle as *const Handle) };
    string(h.progress.value())
}
/// # Safety
/// `handle` must be live; close must not run concurrently.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jj_engine_cancel(handle: *mut c_void) {
    if !handle.is_null() {
        unsafe { &*(handle as *const Handle) }
            .progress
            .cancelled
            .store(true, std::sync::atomic::Ordering::Relaxed);
    }
}
/// # Safety
/// `value` must be null or an unfreed pointer returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jj_engine_free_string(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}
/// # Safety
/// `handle` must be live and exclusively owned, with no pending calls.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jj_engine_close(handle: *mut c_void) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle as *mut Handle) });
    }
}

/// # Safety
/// `handle` must be live; only one sync invocation may be active per handle.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jj_engine_begin_sync(handle: *mut c_void) {
    if !handle.is_null() {
        unsafe { &*(handle as *const Handle) }.progress.reset();
    }
}
