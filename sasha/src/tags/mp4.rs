//! MP4 / M4A (AAC and ALAC): iTunes-style ilst tags, duration and stream info.

use super::{be16, be32, be64, fill, genre_name, read_up_to, sniff_mime, year_of, Meta, Picture, GENRES};
use std::fs::File;
use std::io::{self, Seek, SeekFrom};
use std::path::Path;

pub fn read(path: &Path, m: &mut Meta) -> io::Result<()> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    let mut pos = 0u64;
    while pos + 8 <= len {
        f.seek(SeekFrom::Start(pos))?;
        let mut h = [0u8; 16];
        let n = read_up_to(&mut f, &mut h)?;
        if n < 8 {
            break;
        }
        let mut size = u32::from_be_bytes([h[0], h[1], h[2], h[3]]) as u64;
        let mut hdr = 8u64;
        if size == 1 {
            if n < 16 {
                break;
            }
            size = u64::from_be_bytes([h[8], h[9], h[10], h[11], h[12], h[13], h[14], h[15]]);
            hdr = 16;
        } else if size == 0 {
            size = len - pos;
        }
        if size < hdr {
            break;
        }
        if &h[4..8] == b"moov" {
            let body = size - hdr;
            if body <= 128 * 1024 * 1024 {
                f.seek(SeekFrom::Start(pos + hdr))?;
                let mut data = vec![0u8; body as usize];
                let got = read_up_to(&mut f, &mut data)?;
                data.truncate(got);
                let mut st = State::default();
                walk(&data, m, &mut st);
                if st.timescale > 0 && st.duration > 0 {
                    m.duration_ms = st.duration * 1000 / st.timescale as u64;
                }
            }
            break;
        }
        pos = pos.saturating_add(size);
    }
    if m.codec.is_empty() {
        m.codec = "AAC".into();
    }
    if m.duration_ms > 0 {
        m.bitrate = (len * 8 / m.duration_ms) as u32;
    }
    Ok(())
}

#[derive(Default)]
struct State {
    timescale: u32,
    duration: u64,
}

/// Iterates the atoms in `d` as (type, body).
fn atoms(d: &[u8]) -> Vec<([u8; 4], &[u8])> {
    let mut out = Vec::new();
    let mut p = 0usize;
    while p + 8 <= d.len() {
        let mut size = be32(d, p).unwrap_or(0) as usize;
        let mut hdr = 8;
        if size == 1 {
            size = match be64(d, p + 8) {
                Some(s) => s as usize,
                None => break,
            };
            hdr = 16;
        } else if size == 0 {
            size = d.len() - p;
        }
        if size < hdr || p + size > d.len() {
            break;
        }
        let mut t = [0u8; 4];
        t.copy_from_slice(&d[p + 4..p + 8]);
        out.push((t, &d[p + hdr..p + size]));
        p += size;
    }
    out
}

fn walk(d: &[u8], m: &mut Meta, st: &mut State) {
    for (t, body) in atoms(d) {
        match &t {
            b"trak" | b"mdia" | b"minf" | b"stbl" | b"udta" => walk(body, m, st),
            b"meta" => {
                // ISO "meta" is a full box (4 bytes version/flags); QuickTime's is not.
                let skip = if body.len() >= 8 && &body[4..8] == b"hdlr" { 0 } else { 4 };
                if body.len() > skip {
                    walk(&body[skip..], m, st);
                }
            }
            b"ilst" => items(body, m),
            b"mvhd" => {
                if body.first() == Some(&1) {
                    st.timescale = be32(body, 20).unwrap_or(0);
                    st.duration = be64(body, 24).unwrap_or(0);
                } else {
                    st.timescale = be32(body, 12).unwrap_or(0);
                    st.duration = be32(body, 16).unwrap_or(0) as u64;
                }
            }
            b"stsd" => sample_description(body, m),
            _ => {}
        }
    }
}

fn sample_description(body: &[u8], m: &mut Meta) {
    // version/flags (4), entry count (4), then the first entry
    let e = match body.get(8..) {
        Some(e) if e.len() >= 36 => e,
        _ => return,
    };
    let kind = &e[4..8];
    let codec = match kind {
        b"mp4a" => "AAC",
        b"alac" => "ALAC",
        b"ac-3" => "AC-3",
        b"ec-3" => "E-AC-3",
        b"Opus" => "Opus",
        b"fLaC" => "FLAC",
        _ => return, // video or other tracks
    };
    if !m.codec.is_empty() && m.codec != "AAC" {
        return;
    }
    m.codec = codec.into();
    m.channels = be16(e, 24).unwrap_or(0) as u32;
    let sample_size = be16(e, 26).unwrap_or(0) as u32;
    m.sample_rate = be16(e, 32).unwrap_or(0) as u32;
    if codec == "ALAC" || codec == "FLAC" {
        m.bits = sample_size;
    }
}

fn items(d: &[u8], m: &mut Meta) {
    for (name, item) in atoms(d) {
        for (t, data) in atoms(item) {
            if &t != b"data" || data.len() < 8 {
                continue;
            }
            let kind = be32(data, 0).unwrap_or(0) & 0x00FF_FFFF;
            let payload = &data[8..];
            let text = || String::from_utf8_lossy(payload).to_string();
            match &name {
                b"\xa9nam" => fill(&mut m.title, &text()),
                b"\xa9ART" => fill(&mut m.artist, &text()),
                b"aART" => fill(&mut m.album_artist, &text()),
                b"\xa9alb" => fill(&mut m.album, &text()),
                b"\xa9gen" => fill(&mut m.genre, &genre_name(&text())),
                b"\xa9day" => fill(&mut m.year, &year_of(&text())),
                b"gnre" => {
                    if let Some(n) = be16(payload, 0) {
                        if n > 0 {
                            if let Some(g) = GENRES.get(n as usize - 1) {
                                fill(&mut m.genre, g);
                            }
                        }
                    }
                }
                b"trkn" => {
                    if m.track == 0 {
                        m.track = be16(payload, 2).unwrap_or(0) as u32;
                    }
                }
                b"disk" => {
                    if m.disc == 0 {
                        m.disc = be16(payload, 2).unwrap_or(0) as u32;
                    }
                }
                b"covr" => {
                    let fallback = if kind == 14 { "image/png" } else { "image/jpeg" };
                    m.offer_picture(Picture { mime: sniff_mime(payload, fallback), kind: 3, data: payload.to_vec() });
                }
                _ => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    fn atom(t: &[u8], body: &[u8]) -> Vec<u8> {
        let mut a = ((body.len() + 8) as u32).to_be_bytes().to_vec();
        a.extend_from_slice(t);
        a.extend_from_slice(body);
        a
    }

    fn data(kind: u32, payload: &[u8]) -> Vec<u8> {
        let mut b = kind.to_be_bytes().to_vec();
        b.extend_from_slice(&[0, 0, 0, 0]);
        b.extend_from_slice(payload);
        atom(b"data", &b)
    }

    #[test]
    fn reads_m4a() {
        let mut ilst = Vec::new();
        ilst.extend(atom(b"\xa9nam", &data(1, b"Night Drive")));
        ilst.extend(atom(b"\xa9ART", &data(1, b"Glass Pilots")));
        ilst.extend(atom(b"\xa9alb", &data(1, b"Neon Arcade")));
        ilst.extend(atom(b"\xa9day", &data(1, b"2019-10-01T00:00:00Z")));
        ilst.extend(atom(b"trkn", &data(0, &[0, 0, 0, 5, 0, 8, 0, 0])));
        ilst.extend(atom(b"gnre", &data(0, &[0, 53])));
        let png: Vec<u8> = [0x89, b'P', b'N', b'G'].iter().copied().chain(std::iter::repeat(1).take(20)).collect();
        ilst.extend(atom(b"covr", &data(14, &png)));
        let mut meta_body = vec![0, 0, 0, 0];
        meta_body.extend(atom(b"hdlr", &[0u8; 25]));
        meta_body.extend(atom(b"ilst", &ilst));
        let udta = atom(b"udta", &atom(b"meta", &meta_body));
        let mut mvhd = vec![0u8; 100];
        mvhd[12..16].copy_from_slice(&1000u32.to_be_bytes());
        mvhd[16..20].copy_from_slice(&262_000u32.to_be_bytes());
        // stsd with one mp4a entry: 2 ch, 16 bit, 44100 Hz
        let mut entry = vec![0u8; 36];
        entry[0..4].copy_from_slice(&36u32.to_be_bytes());
        entry[4..8].copy_from_slice(b"mp4a");
        entry[24..26].copy_from_slice(&2u16.to_be_bytes());
        entry[26..28].copy_from_slice(&16u16.to_be_bytes());
        entry[32..34].copy_from_slice(&44100u16.to_be_bytes());
        let mut stsd = vec![0, 0, 0, 0, 0, 0, 0, 1];
        stsd.extend(entry);
        let trak = atom(b"trak", &atom(b"mdia", &atom(b"minf", &atom(b"stbl", &atom(b"stsd", &stsd)))));
        let mut moov_body = atom(b"mvhd", &mvhd);
        moov_body.extend(trak);
        moov_body.extend(udta);
        let mut file = atom(b"ftyp", b"M4A \0\0\0\0");
        file.extend(atom(b"mdat", &[0u8; 1000]));
        file.extend(atom(b"moov", &moov_body));

        let dir = std::env::temp_dir().join(format!("sasha-mp4-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.m4a");
        std::fs::write(&path, &file).unwrap();
        let m = crate::tags::read(&path);
        assert_eq!(m.title, "Night Drive");
        assert_eq!(m.artist, "Glass Pilots");
        assert_eq!(m.album, "Neon Arcade");
        assert_eq!(m.year, "2019");
        assert_eq!(m.track, 5);
        assert_eq!(m.genre, "Electronic");
        assert_eq!(m.duration_ms, 262_000);
        assert_eq!((m.codec.as_str(), m.channels, m.sample_rate), ("AAC", 2, 44100));
        assert_eq!(m.picture.unwrap().mime, "image/png");
        std::fs::remove_dir_all(&dir).ok();
    }
}
