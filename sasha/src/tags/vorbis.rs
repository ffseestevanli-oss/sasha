//! Vorbis comments (FLAC, Ogg Vorbis, Opus), FLAC picture blocks and base64.

use super::{be32, fill, genre_name, le32, leading_number, sniff_mime, year_of, Meta, Picture};

/// Parses a Vorbis comment block (vendor string, then KEY=value entries).
pub fn parse_comment(d: &[u8], m: &mut Meta) {
    let _ = parse_comment_inner(d, m);
}

fn parse_comment_inner(d: &[u8], m: &mut Meta) -> Option<()> {
    let vendor = le32(d, 0)? as usize;
    let mut p = 4usize.checked_add(vendor)?;
    let count = le32(d, p)?;
    p += 4;
    let mut cover_art: Option<Vec<u8>> = None;
    for _ in 0..count {
        let len = le32(d, p)? as usize;
        p += 4;
        let s = d.get(p..p.checked_add(len)?)?;
        p += len;
        let eq = match s.iter().position(|&c| c == b'=') {
            Some(e) => e,
            None => continue,
        };
        let key = String::from_utf8_lossy(&s[..eq]).to_ascii_uppercase();
        let val = &s[eq + 1..];
        match key.as_str() {
            "METADATA_BLOCK_PICTURE" => {
                if let Some(raw) = base64(val) {
                    if let Some(pic) = parse_picture_block(&raw) {
                        m.offer_picture(pic);
                    }
                }
            }
            "COVERART" => cover_art = base64(val),
            _ => apply(&key, &String::from_utf8_lossy(val), m),
        }
    }
    if m.picture.is_none() {
        if let Some(data) = cover_art {
            let mime = sniff_mime(&data, "image/jpeg");
            m.offer_picture(Picture { mime, kind: 3, data });
        }
    }
    Some(())
}

fn apply(key: &str, v: &str, m: &mut Meta) {
    match key {
        "TITLE" => fill(&mut m.title, v),
        "ARTIST" => fill(&mut m.artist, v),
        "ALBUM" => fill(&mut m.album, v),
        "ALBUMARTIST" | "ALBUM ARTIST" | "ALBUM_ARTIST" => fill(&mut m.album_artist, v),
        "GENRE" => fill(&mut m.genre, &genre_name(v)),
        "DATE" | "YEAR" | "ORIGINALDATE" | "ORIGINALYEAR" => fill(&mut m.year, &year_of(v)),
        "TRACKNUMBER" => {
            if m.track == 0 {
                m.track = leading_number(v);
            }
        }
        "DISCNUMBER" => {
            if m.disc == 0 {
                m.disc = leading_number(v);
            }
        }
        _ => {}
    }
}

/// A FLAC PICTURE metadata block (also used base64-encoded in Ogg comments).
pub fn parse_picture_block(d: &[u8]) -> Option<Picture> {
    let kind = be32(d, 0)?;
    let mime_len = be32(d, 4)? as usize;
    let mime = String::from_utf8_lossy(d.get(8..8usize.checked_add(mime_len)?)?).to_string();
    let mut p = 8 + mime_len;
    let desc_len = be32(d, p)? as usize;
    p = p.checked_add(4 + desc_len)?;
    p += 16; // width, height, depth, colors
    let data_len = be32(d, p)? as usize;
    p += 4;
    let data = d.get(p..p.checked_add(data_len)?)?.to_vec();
    Some(Picture { mime: sniff_mime(&data, &mime), kind, data })
}

/// Standard base64, ignoring whitespace. None on invalid characters.
pub fn base64(s: &[u8]) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a' + 26) as u32),
            b'0'..=b'9' => Some((c - b'0' + 52) as u32),
            b'+' | b'-' => Some(62),
            b'/' | b'_' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut acc = 0u32;
    let mut bits = 0u32;
    for &c in s {
        if c == b'=' {
            break;
        }
        if c.is_ascii_whitespace() {
            continue;
        }
        acc = (acc << 6) | val(c)?;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

#[cfg(test)]
pub mod tests {
    use super::*;

    pub fn comment_block(entries: &[&str]) -> Vec<u8> {
        let mut d = Vec::new();
        d.extend_from_slice(&6u32.to_le_bytes());
        d.extend_from_slice(b"tester");
        d.extend_from_slice(&(entries.len() as u32).to_le_bytes());
        for e in entries {
            d.extend_from_slice(&(e.len() as u32).to_le_bytes());
            d.extend_from_slice(e.as_bytes());
        }
        d
    }

    pub fn picture_block(data: &[u8]) -> Vec<u8> {
        let mut b = Vec::new();
        b.extend_from_slice(&3u32.to_be_bytes());
        b.extend_from_slice(&9u32.to_be_bytes());
        b.extend_from_slice(b"image/png");
        b.extend_from_slice(&0u32.to_be_bytes());
        b.extend_from_slice(&[0u8; 16]);
        b.extend_from_slice(&(data.len() as u32).to_be_bytes());
        b.extend_from_slice(data);
        b
    }

    fn encode64(d: &[u8]) -> String {
        const A: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut s = String::new();
        for chunk in d.chunks(3) {
            let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
            for i in 0..4 {
                if i <= chunk.len() {
                    s.push(A[(n >> (18 - 6 * i) & 63) as usize] as char);
                } else {
                    s.push('=');
                }
            }
        }
        s
    }

    #[test]
    fn base64_roundtrip() {
        for len in 0..20 {
            let d: Vec<u8> = (0..len).map(|i| (i * 31 + 7) as u8).collect();
            assert_eq!(base64(encode64(&d).as_bytes()).unwrap(), d);
        }
    }

    #[test]
    fn comments_and_picture() {
        let png = [0x89, b'P', b'N', b'G', 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14];
        let pic = format!("METADATA_BLOCK_PICTURE={}", encode64(&picture_block(&png)));
        let d = comment_block(&[
            "title=Morning Fog",
            "ARTIST=Fern & Hollow",
            "Album=Field Notes",
            "ALBUMARTIST=Fern & Hollow",
            "DATE=2023-04-01",
            "TRACKNUMBER=1/4",
            "GENRE=Ambient",
            &pic,
        ]);
        let mut m = Meta::default();
        parse_comment(&d, &mut m);
        assert_eq!(m.title, "Morning Fog");
        assert_eq!(m.artist, "Fern & Hollow");
        assert_eq!(m.album, "Field Notes");
        assert_eq!(m.album_artist, "Fern & Hollow");
        assert_eq!(m.year, "2023");
        assert_eq!(m.track, 1);
        let p = m.picture.unwrap();
        assert_eq!(p.mime, "image/png");
        assert_eq!(p.data, png);
    }

    #[test]
    fn truncated_comment_is_harmless() {
        let d = comment_block(&["TITLE=A", "ARTIST=B"]);
        for cut in 0..d.len() {
            let mut m = Meta::default();
            parse_comment(&d[..cut], &mut m);
        }
    }
}
