pub mod segment;

use std::ffi::{CString, c_char, c_int, c_void};

const SQLITE_OK: c_int = 0;
const FTS5_TOKEN_COLOCATED: c_int = 0x0001;

type EmitFn = unsafe extern "C" fn(
    ctx: *mut c_void,
    tflags: c_int,
    token: *const c_char,
    n_token: c_int,
    start: c_int,
    end: c_int,
) -> c_int;

unsafe extern "C" {
    fn sqlite3_jieba_init_impl(
        db: *mut c_void,
        err_msg: *mut *mut c_char,
        api: *const c_void,
    ) -> c_int;
}

/// The extension entry point. Forwarding through Rust is what keeps the linker
/// from dropping the C shim out of the cdylib.
///
/// # Safety
/// Called by SQLite with a live `sqlite3*` and api-routines table.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sqlite3_jieba_init(
    db: *mut c_void,
    err_msg: *mut *mut c_char,
    api: *const c_void,
) -> c_int {
    unsafe { sqlite3_jieba_init_impl(db, err_msg, api) }
}

unsafe fn borrow_utf8<'a>(text: *const c_char, len: c_int) -> Option<&'a str> {
    if text.is_null() || len <= 0 {
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(text.cast::<u8>(), len as usize) };
    std::str::from_utf8(bytes).ok()
}

/// # Safety
/// `text` must point at `n_text` bytes; `emit` is FTS5's `xToken`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sqlite3_jieba_tokenize(
    text: *const c_char,
    n_text: c_int,
    ctx: *mut c_void,
    emit: EmitFn,
) -> c_int {
    // Indexing nothing beats failing the write that carried the bad bytes.
    let Some(text) = (unsafe { borrow_utf8(text, n_text) }) else {
        return SQLITE_OK;
    };
    for token in segment::tokenize(text) {
        let flags = if token.colocated {
            FTS5_TOKEN_COLOCATED
        } else {
            0
        };
        let rc = unsafe {
            emit(
                ctx,
                flags,
                token.text.as_ptr().cast::<c_char>(),
                token.text.len() as c_int,
                token.start as c_int,
                token.end as c_int,
            )
        };
        if rc != SQLITE_OK {
            return rc;
        }
    }
    SQLITE_OK
}

fn json_array(tokens: &[String]) -> String {
    let mut out = String::from("[");
    for (i, token) in tokens.iter().enumerate() {
        if i > 0 {
            out.push(',');
        }
        out.push('"');
        for ch in token.chars() {
            match ch {
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
                c => out.push(c),
            }
        }
        out.push('"');
    }
    out.push(']');
    out
}

/// # Safety
/// `text` must point at `n_text` bytes. The result must be released with
/// [`sqlite3_jieba_free_json`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sqlite3_jieba_cut_json(text: *const c_char, n_text: c_int) -> *mut c_char {
    let tokens = match unsafe { borrow_utf8(text, n_text) } {
        Some(text) => segment::distinct_tokens(text),
        None => Vec::new(),
    };
    match CString::new(json_array(&tokens)) {
        Ok(json) => json.into_raw(),
        Err(_) => std::ptr::null_mut(),
    }
}

/// # Safety
/// `p` must come from [`sqlite3_jieba_cut_json`] and be freed exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn sqlite3_jieba_free_json(p: *mut c_char) {
    if !p.is_null() {
        drop(unsafe { CString::from_raw(p) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_array_escapes() {
        assert_eq!(json_array(&[]), "[]");
        assert_eq!(
            json_array(&["a\"b".into(), "c\\d".into(), "中文".into()]),
            r#"["a\"b","c\\d","中文"]"#
        );
    }
}
