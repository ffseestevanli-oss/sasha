//! ID3v2.2 / 2.3 / 2.4 and ID3v1 tags.

use super::{be32, fill, genre_name, latin1, leading_number, read_up_to, sniff_mime, year_of, Meta, Picture, GENRES};
use std::fs::File;
use std::io::{self, Seek, SeekFrom};

pub fn synchsafe(b: &[u8]) -> u32 {
    ((b[0] as u32 & 0x7f) << 21) | ((b[1] as u32 & 0x7f) << 14) | ((b[2] as u32 & 0x7f) << 7) | (b[3] as u32 & 0x7f)
}

/// Reads an ID3v2 tag at the start of the file (if there is one) into `m`.
/// Returns the offset of the first byte after the tag, or 0 when there is none.
pub fn read_v2(f: &mut File, m: &mut Meta) -> io::Result<u64> {
    f.seek(SeekFrom::Start(0))?;
    let mut head = [0u8; 10];
    if read_up_to(f, &mut head)? < 10 || &head[0..3] != b"ID3" {
        return Ok(0);
    }
    if head[3] < 2 || head[3] > 4 || head[6..10].iter().any(|b| b & 0x80 != 0) {
        return Ok(0);
    }
    let size = synchsafe(&head[6..10]) as usize;
    let footer = if head[3] == 4 && head[5] & 0x10 != 0 { 10 } else { 0 };
    if size <= 64 * 1024 * 1024 {
        let mut tag = vec![0u8; 10 + size];
        tag[..10].copy_from_slice(&head);
        let n = read_up_to(f, &mut tag[10..])?;
        tag.truncate(10 + n);
        parse_v2(&tag, m);
    }
    Ok(10 + size as u64 + footer)
}

/// Parses a complete ID3v2 tag (10-byte header included).
pub fn parse_v2(tag: &[u8], m: &mut Meta) {
    if tag.len() < 10 || &tag[0..3] != b"ID3" {
        return;
    }
    let major = tag[3];
    let flags = tag[5];
    let mut body: Vec<u8> = tag[10..].to_vec();
    if major < 4 && flags & 0x80 != 0 {
        body = unsync(&body);
    }
    let mut pos = 0usize;
    if flags & 0x40 != 0 {
        match major {
            3 => pos = be32(&body, 0).map(|s| s as usize + 4).unwrap_or(body.len()),
            4 => pos = body.get(0..4).map(|s| synchsafe(s) as usize).unwrap_or(body.len()),
            _ => {}
        }
    }
    let pos = pos.min(body.len());
    if major == 2 {
        frames_v22(&body[pos..], m);
    } else {
        frames_v34(&body, pos, major, m);
    }
}

/// Removes the "unsynchronisation" stuffing: FF 00 -> FF.
fn unsync(b: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        out.push(b[i]);
        if b[i] == 0xFF && b.get(i + 1) == Some(&0) {
            i += 1;
        }
        i += 1;
    }
    out
}

fn is_frame_id(id: &[u8]) -> bool {
    id.iter().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

/// Is there a plausible frame (or padding / the end) at `at`?
fn next_ok(b: &[u8], at: usize) -> bool {
    if at == b.len() {
        return true;
    }
    match b.get(at..at + 4) {
        Some(id) => id[0] == 0 || is_frame_id(id),
        None => at <= b.len() && b[at..].iter().all(|&c| c == 0),
    }
}

fn frames_v22(b: &[u8], m: &mut Meta) {
    let mut p = 0;
    while p + 6 <= b.len() {
        let id = &b[p..p + 3];
        if id[0] == 0 || !is_frame_id(id) {
            break;
        }
        let size = ((b[p + 3] as usize) << 16) | ((b[p + 4] as usize) << 8) | b[p + 5] as usize;
        let start = p + 6;
        let end = start + size;
        if end > b.len() {
            break;
        }
        let id = std::str::from_utf8(id).unwrap_or("");
        frame(id, &b[start..end], m);
        p = end;
    }
}

fn frames_v34(b: &[u8], mut p: usize, major: u8, m: &mut Meta) {
    while p + 10 <= b.len() {
        let id = &b[p..p + 4];
        if id[0] == 0 || !is_frame_id(id) {
            break;
        }
        let raw = &b[p + 4..p + 8];
        let plain = u32::from_be_bytes([raw[0], raw[1], raw[2], raw[3]]) as usize;
        let mut size = if major == 4 { synchsafe(raw) as usize } else { plain };
        // Some ID3v2.4 writers store plain sizes; trust whichever lands on a frame.
        if major == 4 && plain != size && !next_ok(b, p + 10 + size) && next_ok(b, p + 10 + plain) {
            size = plain;
        }
        let fmt_flags = b[p + 9];
        let start = p + 10;
        let end = start.saturating_add(size);
        if end > b.len() {
            break;
        }
        let id_s = std::str::from_utf8(id).unwrap_or("");
        let mut data: &[u8] = &b[start..end];
        let owned: Vec<u8>;
        let mut skip = false;
        if major == 4 {
            let mut off = 0;
            if fmt_flags & 0x40 != 0 {
                off += 1; // group id
            }
            if fmt_flags & 0x08 != 0 || fmt_flags & 0x04 != 0 {
                skip = true; // compressed or encrypted
            }
            if fmt_flags & 0x01 != 0 {
                off += 4; // data length indicator
            }
            data = data.get(off..).unwrap_or(&[]);
            if fmt_flags & 0x02 != 0 {
                owned = unsync(data);
                data = &owned;
            }
        } else {
            if fmt_flags & 0x80 != 0 || fmt_flags & 0x40 != 0 {
                skip = true;
            }
            if fmt_flags & 0x20 != 0 {
                data = data.get(1..).unwrap_or(&[]);
            }
        }
        if !skip {
            frame(id_s, data, m);
        }
        p = end;
    }
}

fn frame(id: &str, d: &[u8], m: &mut Meta) {
    match id {
        "TIT2" | "TT2" => fill(&mut m.title, &text(d)),
        "TPE1" | "TP1" => fill(&mut m.artist, &text(d)),
        "TPE2" | "TP2" => fill(&mut m.album_artist, &text(d)),
        "TALB" | "TAL" => fill(&mut m.album, &text(d)),
        "TCON" | "TCO" => fill(&mut m.genre, &genre_name(&text(d))),
        "TRCK" | "TRK" => {
            if m.track == 0 {
                m.track = leading_number(&text(d));
            }
        }
        "TPOS" | "TPA" => {
            if m.disc == 0 {
                m.disc = leading_number(&text(d));
            }
        }
        "TDRC" | "TYER" | "TYE" | "TDOR" | "TORY" => fill(&mut m.year, &year_of(&text(d))),
        "TLEN" | "TLE" => {
            if m.duration_ms == 0 {
                m.duration_ms = leading_number(&text(d)) as u64;
            }
        }
        "APIC" => {
            if let Some(p) = apic(d) {
                m.offer_picture(p);
            }
        }
        "PIC" => {
            if let Some(p) = pic22(d) {
                m.offer_picture(p);
            }
        }
        _ => {}
    }
}

/// First value of a text frame.
fn text(d: &[u8]) -> String {
    match d.first() {
        Some(&enc) => decode_term(enc, &d[1..]).0.trim().to_string(),
        None => String::new(),
    }
}

/// Decodes one terminated string in the given ID3 encoding.
/// Returns the string and how many bytes it used (terminator included).
fn decode_term(enc: u8, b: &[u8]) -> (String, usize) {
    match enc {
        1 | 2 => {
            let mut i = 0;
            while i + 1 < b.len() {
                if b[i] == 0 && b[i + 1] == 0 {
                    break;
                }
                i += 2;
            }
            let end = i.min(b.len());
            (decode_utf16(&b[..end], enc == 2), (end + 2).min(b.len()))
        }
        _ => {
            let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
            let s = if enc == 3 {
                String::from_utf8_lossy(&b[..end]).into_owned()
            } else {
                latin1(&b[..end])
            };
            (s, (end + 1).min(b.len()))
        }
    }
}

fn decode_utf16(b: &[u8], default_be: bool) -> String {
    let mut be = default_be;
    let mut start = 0;
    if b.len() >= 2 {
        if b[0] == 0xFF && b[1] == 0xFE {
            be = false;
            start = 2;
        } else if b[0] == 0xFE && b[1] == 0xFF {
            be = true;
            start = 2;
        }
    }
    let units: Vec<u16> = b[start..]
        .chunks_exact(2)
        .map(|c| if be { u16::from_be_bytes([c[0], c[1]]) } else { u16::from_le_bytes([c[0], c[1]]) })
        .collect();
    String::from_utf16_lossy(&units).trim_end_matches('\0').to_string()
}

fn apic(d: &[u8]) -> Option<Picture> {
    let enc = *d.first()?;
    let rest = &d[1..];
    let mime_end = rest.iter().position(|&c| c == 0)?;
    let mime = latin1(&rest[..mime_end]).to_ascii_lowercase();
    let rest = rest.get(mime_end + 1..)?;
    let kind = *rest.first()? as u32;
    let rest = &rest[1..];
    let (_, used) = decode_term(enc, rest);
    let data = rest.get(used..)?.to_vec();
    let fallback = if mime.contains('/') {
        mime
    } else if mime.contains("png") {
        "image/png".to_string()
    } else {
        "image/jpeg".to_string()
    };
    Some(Picture { mime: sniff_mime(&data, &fallback), kind, data })
}

fn pic22(d: &[u8]) -> Option<Picture> {
    let enc = *d.first()?;
    let fmt = latin1(d.get(1..4)?).to_ascii_uppercase();
    let kind = *d.get(4)? as u32;
    let rest = d.get(5..)?;
    let (_, used) = decode_term(enc, rest);
    let data = rest.get(used..)?.to_vec();
    let fallback = if fmt == "PNG" { "image/png" } else { "image/jpeg" };
    Some(Picture { mime: sniff_mime(&data, fallback), kind, data })
}

/// The 128-byte ID3v1 tag at the end of a file.
pub fn parse_v1(b: &[u8], m: &mut Meta) {
    if b.len() < 128 || &b[0..3] != b"TAG" {
        return;
    }
    let field = |r: std::ops::Range<usize>| {
        let s = &b[r];
        let end = s.iter().position(|&c| c == 0).unwrap_or(s.len());
        latin1(&s[..end]).trim().to_string()
    };
    fill(&mut m.title, &field(3..33));
    fill(&mut m.artist, &field(33..63));
    fill(&mut m.album, &field(63..93));
    fill(&mut m.year, &year_of(&field(93..97)));
    if b[125] == 0 && b[126] != 0 && m.track == 0 {
        m.track = b[126] as u32;
    }
    if m.genre.is_empty() {
        if let Some(g) = GENRES.get(b[127] as usize) {
            m.genre = g.to_string();
        }
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;

    fn frame_v3(id: &str, data: &[u8]) -> Vec<u8> {
        let mut f = id.as_bytes().to_vec();
        f.extend_from_slice(&(data.len() as u32).to_be_bytes());
        f.extend_from_slice(&[0, 0]);
        f.extend_from_slice(data);
        f
    }

    fn ss(n: usize) -> [u8; 4] {
        [((n >> 21) & 0x7f) as u8, ((n >> 14) & 0x7f) as u8, ((n >> 7) & 0x7f) as u8, (n & 0x7f) as u8]
    }

    /// A small ID3v2.3 tag used by these tests and the MPEG tests.
    pub fn sample_v23() -> Vec<u8> {
        let mut body = Vec::new();
        // UTF-16 with BOM
        let mut t = vec![1u8, 0xFF, 0xFE];
        for u in "Harbor Lights".encode_utf16() {
            t.extend_from_slice(&u.to_le_bytes());
        }
        t.extend_from_slice(&[0, 0]);
        body.extend(frame_v3("TIT2", &t));
        body.extend(frame_v3("TPE1", b"\x00Marlow Reed"));
        body.extend(frame_v3("TALB", b"\x03Low Tide Sessions"));
        body.extend(frame_v3("TRCK", b"\x002/4"));
        body.extend(frame_v3("TYER", b"\x002021"));
        body.extend(frame_v3("TCON", b"\x00(17)"));
        let mut apic = vec![0u8];
        apic.extend_from_slice(b"image/jpeg\0");
        apic.push(3);
        apic.extend_from_slice(b"cover\0");
        apic.extend_from_slice(&[0xFF, 0xD8, 0xFF, 0xE0]);
        apic.extend_from_slice(&[7u8; 40]);
        body.extend(frame_v3("APIC", &apic));
        body.extend_from_slice(&[0u8; 32]); // padding
        let mut tag = b"ID3\x03\x00\x00".to_vec();
        tag.extend_from_slice(&ss(body.len()));
        tag.extend(body);
        tag
    }

    #[test]
    fn parses_v23() {
        let mut m = Meta::default();
        parse_v2(&sample_v23(), &mut m);
        assert_eq!(m.title, "Harbor Lights");
        assert_eq!(m.artist, "Marlow Reed");
        assert_eq!(m.album, "Low Tide Sessions");
        assert_eq!(m.track, 2);
        assert_eq!(m.year, "2021");
        assert_eq!(m.genre, "Rock");
        let p = m.picture.expect("picture");
        assert_eq!(p.kind, 3);
        assert_eq!(p.mime, "image/jpeg");
        assert_eq!(p.data.len(), 44);
    }

    #[test]
    fn parses_v24_with_synchsafe_and_plain_sizes() {
        let mut body = Vec::new();
        // synchsafe size, UTF-8
        let title = b"\x03A title that is long enough to need more than 127 bytes in a synchsafe size field so the two encodings differ, really it is";
        body.extend_from_slice(b"TIT2");
        body.extend_from_slice(&ss(title.len()));
        body.extend_from_slice(&[0, 0]);
        body.extend_from_slice(title);
        // a buggy writer's plain size
        let artist_val: Vec<u8> = std::iter::once(3u8).chain(std::iter::repeat(b'x').take(200)).collect();
        body.extend_from_slice(b"TPE1");
        body.extend_from_slice(&(artist_val.len() as u32).to_be_bytes());
        body.extend_from_slice(&[0, 0]);
        body.extend_from_slice(&artist_val);
        body.extend_from_slice(b"TDRC");
        body.extend_from_slice(&ss(11));
        body.extend_from_slice(&[0, 0]);
        body.extend_from_slice(b"\x032019-05-01");
        let mut tag = b"ID3\x04\x00\x00".to_vec();
        tag.extend_from_slice(&ss(body.len()));
        tag.extend(body);
        let mut m = Meta::default();
        parse_v2(&tag, &mut m);
        assert!(m.title.starts_with("A title"));
        assert_eq!(m.artist.len(), 200);
        assert_eq!(m.year, "2019");
    }

    #[test]
    fn parses_v1() {
        let mut b = vec![0u8; 128];
        b[0..3].copy_from_slice(b"TAG");
        b[3..8].copy_from_slice(b"Dusk ");
        b[33..38].copy_from_slice(b"Fern ");
        b[93..97].copy_from_slice(b"2023");
        b[126] = 4;
        b[127] = 26;
        let mut m = Meta::default();
        parse_v1(&b, &mut m);
        assert_eq!(m.title, "Dusk");
        assert_eq!(m.artist, "Fern");
        assert_eq!(m.year, "2023");
        assert_eq!(m.track, 4);
        assert_eq!(m.genre, "Ambient");
    }

    #[test]
    fn garbage_does_not_panic() {
        let mut m = Meta::default();
        let mut tag = b"ID3\x03\x00\x00\x00\x00\x01\x00".to_vec();
        tag.extend((0..200u32).map(|i| (i * 37 % 251) as u8));
        parse_v2(&tag, &mut m);
        parse_v2(b"ID3", &mut m);
    }
}
