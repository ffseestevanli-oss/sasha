//! Sasha: the Rust side. Owns the library scanner, the play queue and the
//! spectrum maths, and exposes them to the Qt host (cpp/) through a small
//! C ABI. The Qt host owns the window, playback and the event loop.

// The C bridge necessarily takes raw pointers from the Qt host.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

mod library;
mod m3u;
mod queue;
mod spectrum;
mod tags;

use std::ffi::{c_char, CStr, OsStr};
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};

static SCAN_DONE: AtomicU32 = AtomicU32::new(0);
static SCAN_TOTAL: AtomicU32 = AtomicU32::new(0);

fn blob() -> MutexGuard<'static, Vec<u8>> {
    static B: OnceLock<Mutex<Vec<u8>>> = OnceLock::new();
    B.get_or_init(|| Mutex::new(Vec::new())).lock().unwrap_or_else(|e| e.into_inner())
}

fn queue() -> MutexGuard<'static, queue::Queue> {
    static Q: OnceLock<Mutex<queue::Queue>> = OnceLock::new();
    Q.get_or_init(|| {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9E3779B97F4A7C15);
        Mutex::new(queue::Queue::new(seed))
    })
    .lock()
    .unwrap_or_else(|e| e.into_inner())
}

fn path_from(p: *const c_char) -> PathBuf {
    // SAFETY: the host passes valid NUL-terminated strings.
    PathBuf::from(OsStr::from_bytes(unsafe { CStr::from_ptr(p) }.to_bytes()))
}

fn opt(o: Option<u32>) -> i64 {
    o.map(|v| v as i64).unwrap_or(-1)
}

// ------------------------------------------------------------- library ---

/// Scans `root` (blocking; the host calls it from a worker thread) and keeps
/// the result for `tn_library_blob`. Returns the number of tracks found.
#[no_mangle]
pub extern "C" fn tn_scan(root: *const c_char, cache_dir: *const c_char) -> u32 {
    if root.is_null() || cache_dir.is_null() {
        return 0;
    }
    let root = path_from(root);
    let cache = path_from(cache_dir);
    let result = std::panic::catch_unwind(|| {
        let lib = library::scan(&root, &cache, &SCAN_DONE, &SCAN_TOTAL);
        (lib.tracks.len() as u32, library::blob(&lib))
    });
    match result {
        Ok((n, data)) => {
            *blob() = data;
            n
        }
        Err(_) => 0,
    }
}

#[no_mangle]
pub extern "C" fn tn_scan_progress() -> u32 {
    SCAN_DONE.load(Ordering::Relaxed)
}

#[no_mangle]
pub extern "C" fn tn_scan_total() -> u32 {
    SCAN_TOTAL.load(Ordering::Relaxed)
}

/// The last scan result (see library::blob for the format). The pointer stays
/// valid until the next tn_scan finishes; the host copies it right away.
#[no_mangle]
pub extern "C" fn tn_library_blob(len: *mut usize) -> *const u8 {
    let b = blob();
    if !len.is_null() {
        // SAFETY: the host passes a valid pointer.
        unsafe { *len = b.len() };
    }
    b.as_ptr()
}

// --------------------------------------------------------------- queue ---

/// Replaces the queue with `n` track indices. `start` is a position in that
/// list (-1 = from the top, or a random track when shuffling).
/// Returns the track to play, or -1.
#[no_mangle]
pub extern "C" fn tn_queue_set(tracks: *const u32, n: usize, start: i64, shuffle: bool) -> i64 {
    let list = if tracks.is_null() || n == 0 {
        Vec::new()
    } else {
        // SAFETY: the host passes `n` valid indices.
        unsafe { std::slice::from_raw_parts(tracks, n) }.to_vec()
    };
    let start = if start >= 0 { Some(start as usize) } else { None };
    opt(queue().set(list, start, shuffle))
}

/// "Play next": inserts `n` tracks right after the current one.
/// Returns the current track (the first inserted one if the queue was empty).
#[no_mangle]
pub extern "C" fn tn_queue_insert_next(tracks: *const u32, n: usize) -> i64 {
    if tracks.is_null() || n == 0 {
        return opt(queue().current());
    }
    // SAFETY: the host passes `n` valid indices.
    let list = unsafe { std::slice::from_raw_parts(tracks, n) };
    opt(queue().insert_next(list))
}

#[no_mangle]
pub extern "C" fn tn_queue_next(user: bool) -> i64 {
    opt(queue().next(user))
}

#[no_mangle]
pub extern "C" fn tn_queue_prev() -> i64 {
    opt(queue().prev())
}

#[no_mangle]
pub extern "C" fn tn_queue_current() -> i64 {
    opt(queue().current())
}

#[no_mangle]
pub extern "C" fn tn_queue_peek() -> i64 {
    opt(queue().peek())
}

#[no_mangle]
pub extern "C" fn tn_queue_len() -> u32 {
    queue().len() as u32
}

#[no_mangle]
pub extern "C" fn tn_queue_shuffled() -> bool {
    queue().shuffle()
}

#[no_mangle]
pub extern "C" fn tn_queue_set_shuffle(on: bool) {
    queue().set_shuffle(on);
}

/// 0 = off, 1 = repeat all, 2 = repeat one
#[no_mangle]
pub extern "C" fn tn_queue_set_repeat(mode: u32) {
    queue().set_repeat(queue::Repeat::from_u32(mode));
}

// ----------------------------------------------------------- playlists ---

/// Parses M3U/M3U8 text; relative entries resolve against `base_dir`.
/// Returns the paths separated by '\n' in a buffer the host releases with
/// tn_free_buffer(ptr, *out_len).
#[no_mangle]
pub extern "C" fn tn_m3u_parse(text: *const u8, len: usize, base_dir: *const c_char, out_len: *mut usize) -> *mut u8 {
    let mut out: Vec<u8> = Vec::new();
    if !text.is_null() && !base_dir.is_null() {
        // SAFETY: the host passes a valid buffer and string.
        let bytes = unsafe { std::slice::from_raw_parts(text, len) };
        let base = path_from(base_dir);
        let text = String::from_utf8_lossy(bytes);
        let paths = std::panic::catch_unwind(|| m3u::parse(&text, &base)).unwrap_or_default();
        for (i, p) in paths.iter().enumerate() {
            if i > 0 {
                out.push(b'\n');
            }
            out.extend_from_slice(p.as_os_str().as_bytes());
        }
    }
    if !out_len.is_null() {
        // SAFETY: valid pointer from the host.
        unsafe { *out_len = out.len() };
    }
    Box::into_raw(out.into_boxed_slice()) as *mut u8
}

/// Reads one audio file's tags (for files opened from outside the library).
/// Returns a "T" record like the library blob's, with album index -1 and the
/// cached cover file as an 18th field. Free with `tn_free_buffer`.
#[no_mangle]
pub extern "C" fn tn_read_track(path: *const c_char, cache_dir: *const c_char, out_len: *mut usize) -> *mut u8 {
    let out = if path.is_null() || cache_dir.is_null() {
        Vec::new()
    } else {
        library::single(&path_from(path), &path_from(cache_dir))
    };
    if !out_len.is_null() {
        // SAFETY: valid pointer from the host.
        unsafe { *out_len = out.len() };
    }
    Box::into_raw(out.into_boxed_slice()) as *mut u8
}

/// Frees a buffer returned by `tn_m3u_parse` or `tn_read_track`.
#[no_mangle]
pub extern "C" fn tn_free_buffer(ptr: *mut u8, len: usize) {
    if ptr.is_null() {
        return;
    }
    // SAFETY: ptr/len came from tn_m3u_parse.
    unsafe { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len))) };
}

// ------------------------------------------------------------ spectrum ---

/// Writes `bands` levels (0..1) for the mono `samples` into `out`.
#[no_mangle]
pub extern "C" fn tn_spectrum(samples: *const f32, n: usize, sample_rate: u32, out: *mut f32, bands: usize) {
    if samples.is_null() || out.is_null() || bands == 0 {
        return;
    }
    // SAFETY: the host passes valid buffers of the given sizes.
    let (s, o) = unsafe { (std::slice::from_raw_parts(samples, n), std::slice::from_raw_parts_mut(out, bands)) };
    spectrum::bands(s, sample_rate, o);
}

// ---------------------------------------------------------------- main ---

#[cfg(not(test))]
extern "C" {
    /// cpp/host.cpp: runs the Qt application and returns its exit code.
    fn tn_host_main(argc: std::ffi::c_int, argv: *mut *mut c_char, qml: *const c_char, qml_len: usize) -> std::ffi::c_int;
}

#[cfg(not(test))]
const MAIN_QML: &str = include_str!("../qml/main.qml");

#[cfg(not(test))]
fn main() {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStringExt;
    let args: Vec<CString> = std::env::args_os()
        .map(|a| CString::new(a.into_vec()).unwrap_or_default())
        .collect();
    let mut argv: Vec<*mut c_char> = args.iter().map(|a| a.as_ptr() as *mut c_char).collect();
    argv.push(std::ptr::null_mut());
    // SAFETY: argv outlives the call; the QML text is static.
    let code = unsafe {
        tn_host_main(args.len() as std::ffi::c_int, argv.as_mut_ptr(), MAIN_QML.as_ptr() as *const c_char, MAIN_QML.len())
    };
    std::process::exit(code);
}
