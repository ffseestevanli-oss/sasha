//! Reading M3U / M3U8 playlists: comments and #EXT lines are skipped,
//! relative entries resolve against the playlist's folder, file:// URLs are
//! decoded, and other URLs (streams) are left out.

use std::ffi::OsString;
use std::os::unix::ffi::OsStringExt;
use std::path::{Component, Path, PathBuf};

pub fn parse(text: &str, base: &Path) -> Vec<PathBuf> {
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    text.lines()
        .filter_map(|line| {
            let l = line.trim();
            if l.is_empty() || l.starts_with('#') {
                return None;
            }
            resolve(l, base)
        })
        .collect()
}

fn resolve(entry: &str, base: &Path) -> Option<PathBuf> {
    if let Some(rest) = entry.strip_prefix("file://") {
        let rest = rest.strip_prefix("localhost").unwrap_or(rest);
        return Some(PathBuf::from(OsString::from_vec(percent_decode(rest))));
    }
    if entry.contains("://") {
        return None; // http streams and the like
    }
    // Playlists written on Windows use backslashes.
    let e = if entry.contains('\\') && !entry.contains('/') { entry.replace('\\', "/") } else { entry.to_string() };
    let p = PathBuf::from(e);
    Some(if p.is_absolute() { normalize(&p) } else { normalize(&base.join(p)) })
}

/// Resolves "." and ".." without touching the disk.
fn normalize(p: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in p.components() {
        match c {
            Component::ParentDir => {
                out.pop();
            }
            Component::CurDir => {}
            other => out.push(other.as_os_str()),
        }
    }
    out
}

fn percent_decode(s: &str) -> Vec<u8> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            let hex = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok());
            if let Some(v) = hex {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_common_forms() {
        let text = "\u{feff}#EXTM3U\r\n#EXTINF:262,Glass Pilots - Night Drive\r\n/music/Glass Pilots/01 Night Drive.flac\r\n\r\n\
                    ../Other/song.mp3\nfile:///music/With%20Space/%C3%A9t%C3%A9.mp3\nhttp://radio.example/stream\n\
                    sub\\dir\\win.mp3\n./here.ogg\n";
        let got = parse(text, Path::new("/home/me/.local/share/sasha/playlists"));
        let want: Vec<PathBuf> = [
            "/music/Glass Pilots/01 Night Drive.flac",
            "/home/me/.local/share/sasha/Other/song.mp3",
            "/music/With Space/été.mp3",
            "/home/me/.local/share/sasha/playlists/sub/dir/win.mp3",
            "/home/me/.local/share/sasha/playlists/here.ogg",
        ]
        .iter()
        .map(PathBuf::from)
        .collect();
        assert_eq!(got, want);
    }

    #[test]
    fn bad_percent_escapes_pass_through() {
        assert_eq!(percent_decode("a%2"), b"a%2".to_vec());
        assert_eq!(percent_decode("a%zz%41"), b"a%zzA".to_vec());
        assert_eq!(percent_decode("%"), b"%".to_vec());
    }
}
