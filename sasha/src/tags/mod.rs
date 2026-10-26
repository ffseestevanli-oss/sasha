//! Tag and stream-info readers for the formats Sasha lists in its library.
//!
//! Everything here is std-only and defensive: a malformed file yields fewer
//! fields, never a panic (the scanner also catches panics per file as a
//! second line of defense).

use std::fs::File;
use std::io::{self, Read};
use std::path::Path;

pub mod flac;
pub mod id3;
pub mod mp4;
pub mod mpeg;
pub mod ogg;
pub mod vorbis;
pub mod wav;

/// File extensions the library scanner picks up. Playback itself is done by
/// Qt Multimedia, so formats without a tag reader here still play; they are
/// just listed by file name.
pub const AUDIO_EXTS: &[&str] = &[
    "mp3", "mp2", "mp1", "flac", "ogg", "oga", "opus", "m4a", "m4b", "mp4", "alac", "aac", "wav",
    "aif", "aiff", "wv", "ape", "wma", "mpc", "dsf",
];

/// An embedded picture. `kind` uses the ID3/FLAC picture types (3 = front cover).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Picture {
    pub mime: String,
    pub kind: u32,
    pub data: Vec<u8>,
}

#[derive(Debug, Default)]
pub struct Meta {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub genre: String,
    pub year: String,
    pub track: u32,
    pub disc: u32,
    pub duration_ms: u64,
    pub sample_rate: u32,
    pub bits: u32,
    /// kbit/s
    pub bitrate: u32,
    pub channels: u32,
    pub codec: String,
    pub picture: Option<Picture>,
}

impl Meta {
    /// Keeps the first picture offered, but lets a front cover replace any
    /// other kind of picture.
    pub fn offer_picture(&mut self, p: Picture) {
        if p.data.len() < 16 {
            return;
        }
        let replace = match &self.picture {
            None => true,
            Some(cur) => cur.kind != 3 && p.kind == 3,
        };
        if replace {
            self.picture = Some(p);
        }
    }
}

/// Reads whatever the file offers. Never fails: unknown or broken files just
/// come back mostly empty.
pub fn read(path: &Path) -> Meta {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let mut m = Meta::default();
    let _ = match ext.as_str() {
        "mp3" | "mp2" | "mp1" | "aac" => mpeg::read(path, &mut m),
        "flac" => flac::read(path, &mut m),
        "ogg" | "oga" | "opus" => ogg::read(path, &mut m),
        "m4a" | "m4b" | "mp4" | "alac" => mp4::read(path, &mut m),
        "wav" => wav::read(path, &mut m),
        _ => Ok(()),
    };
    if m.codec.is_empty() {
        m.codec = codec_from_ext(&ext);
    }
    m
}

pub fn codec_from_ext(ext: &str) -> String {
    match ext {
        "aif" | "aiff" => "AIFF".into(),
        "wv" => "WavPack".into(),
        "ape" => "APE".into(),
        "wma" => "WMA".into(),
        "mpc" => "Musepack".into(),
        "dsf" => "DSD".into(),
        "m4a" | "m4b" | "mp4" => "AAC".into(),
        other => other.to_ascii_uppercase(),
    }
}

// ------------------------------------------------------------------ helpers --

/// Sets `field` from `value` unless it already has something (first value wins).
pub fn fill(field: &mut String, value: &str) {
    let v = value.trim_matches(|c: char| c == '\0' || c.is_whitespace());
    if field.is_empty() && !v.is_empty() {
        *field = v.to_string();
    }
}

/// "3/12" -> 3, " 07" -> 7, "x" -> 0
pub fn leading_number(s: &str) -> u32 {
    let d: String = s.trim().chars().take_while(|c| c.is_ascii_digit()).take(9).collect();
    d.parse().unwrap_or(0)
}

/// "2021-03-01" -> "2021", anything not starting with four digits -> ""
pub fn year_of(s: &str) -> String {
    let t = s.trim();
    if t.len() >= 4 && t.as_bytes()[..4].iter().all(u8::is_ascii_digit) {
        t[..4].to_string()
    } else {
        String::new()
    }
}

pub fn latin1(b: &[u8]) -> String {
    b.iter().map(|&c| c as char).collect()
}

pub fn be16(b: &[u8], at: usize) -> Option<u16> {
    b.get(at..at.checked_add(2)?).map(|s| u16::from_be_bytes([s[0], s[1]]))
}
pub fn be32(b: &[u8], at: usize) -> Option<u32> {
    b.get(at..at.checked_add(4)?).map(|s| u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
}
pub fn be64(b: &[u8], at: usize) -> Option<u64> {
    let s = b.get(at..at.checked_add(8)?)?;
    let mut a = [0u8; 8];
    a.copy_from_slice(s);
    Some(u64::from_be_bytes(a))
}
pub fn le16(b: &[u8], at: usize) -> Option<u16> {
    b.get(at..at.checked_add(2)?).map(|s| u16::from_le_bytes([s[0], s[1]]))
}
pub fn le32(b: &[u8], at: usize) -> Option<u32> {
    b.get(at..at.checked_add(4)?).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
}
pub fn le64(b: &[u8], at: usize) -> Option<u64> {
    let s = b.get(at..at.checked_add(8)?)?;
    let mut a = [0u8; 8];
    a.copy_from_slice(s);
    Some(u64::from_le_bytes(a))
}

/// Like `read`, but keeps going until the buffer is full or the file ends.
pub fn read_up_to(f: &mut File, buf: &mut [u8]) -> io::Result<usize> {
    let mut n = 0;
    while n < buf.len() {
        match f.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

/// Picks the image type from the data itself; tags often lie or leave it out.
pub fn sniff_mime(data: &[u8], fallback: &str) -> String {
    if data.starts_with(&[0xFF, 0xD8, 0xFF]) {
        "image/jpeg".into()
    } else if data.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png".into()
    } else if data.starts_with(b"GIF8") {
        "image/gif".into()
    } else if data.len() > 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        "image/webp".into()
    } else if data.starts_with(b"BM") {
        "image/bmp".into()
    } else if fallback.contains('/') {
        fallback.to_ascii_lowercase()
    } else {
        "image/jpeg".into()
    }
}

/// "(17)", "(17)Rock", "17" and plain names -> a genre name.
pub fn genre_name(s: &str) -> String {
    let t = s.trim();
    if let Some(rest) = t.strip_prefix('(') {
        if let Some(close) = rest.find(')') {
            let inner = &rest[..close];
            let after = rest[close + 1..].trim();
            if !after.is_empty() {
                return after.to_string();
            }
            if let Ok(n) = inner.parse::<usize>() {
                return GENRES.get(n).map(|g| g.to_string()).unwrap_or_default();
            }
            match inner {
                "RX" => return "Remix".into(),
                "CR" => return "Cover".into(),
                _ => {}
            }
        }
    }
    if !t.is_empty() && t.len() <= 3 && t.chars().all(|c| c.is_ascii_digit()) {
        if let Ok(n) = t.parse::<usize>() {
            return GENRES.get(n).map(|g| g.to_string()).unwrap_or_default();
        }
    }
    t.to_string()
}

/// The ID3v1 genre list (the original 80 entries).
pub const GENRES: &[&str] = &[
    "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz",
    "Metal", "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno",
    "Industrial", "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno",
    "Ambient", "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental",
    "Acid", "House", "Game", "Sound Clip", "Gospel", "Noise", "Alternative Rock", "Bass", "Soul",
    "Punk", "Space", "Meditative", "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
    "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance", "Dream",
    "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40", "Christian Rap", "Pop/Funk", "Jungle",
    "Native American", "Cabaret", "New Wave", "Psychedelic", "Rave", "Showtunes", "Trailer",
    "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical", "Rock & Roll",
    "Hard Rock",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn genre_list_has_80_entries() {
        assert_eq!(GENRES.len(), 80);
        assert_eq!(GENRES[17], "Rock");
        assert_eq!(GENRES[79], "Hard Rock");
    }

    #[test]
    fn genre_names() {
        assert_eq!(genre_name("(17)"), "Rock");
        assert_eq!(genre_name("(17)Indie Rock"), "Indie Rock");
        assert_eq!(genre_name("13"), "Pop");
        assert_eq!(genre_name("Synthwave"), "Synthwave");
        assert_eq!(genre_name("2049"), "2049");
    }

    #[test]
    fn numbers_and_years() {
        assert_eq!(leading_number("3/12"), 3);
        assert_eq!(leading_number(" 07"), 7);
        assert_eq!(leading_number("x"), 0);
        assert_eq!(year_of("2021-03-01"), "2021");
        assert_eq!(year_of("21"), "");
    }

    #[test]
    fn fill_keeps_first_value() {
        let mut s = String::new();
        fill(&mut s, "  First\0");
        fill(&mut s, "Second");
        assert_eq!(s, "First");
    }
}
