//! RIFF WAVE: format, duration, LIST/INFO and embedded "id3 " chunks.

use super::{fill, genre_name, id3, le16, le32, leading_number, read_up_to, year_of, Meta};
use std::fs::File;
use std::io::{self, Seek, SeekFrom};
use std::path::Path;

pub fn read(path: &Path, m: &mut Meta) -> io::Result<()> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    let mut h = [0u8; 12];
    if read_up_to(&mut f, &mut h)? < 12 || &h[0..4] != b"RIFF" || &h[8..12] != b"WAVE" {
        return Ok(());
    }
    m.codec = "WAV".into();
    let mut byte_rate = 0u64;
    let mut pos = 12u64;
    while pos + 8 <= len {
        f.seek(SeekFrom::Start(pos))?;
        let mut ch = [0u8; 8];
        if read_up_to(&mut f, &mut ch)? < 8 {
            break;
        }
        let size = u32::from_le_bytes([ch[4], ch[5], ch[6], ch[7]]) as u64;
        match &ch[0..4] {
            b"fmt " | b"LIST" | b"id3 " | b"ID3 " if size <= 16 * 1024 * 1024 => {
                let mut d = vec![0u8; size as usize];
                let n = read_up_to(&mut f, &mut d)?;
                d.truncate(n);
                match &ch[0..4] {
                    b"fmt " => {
                        m.channels = le16(&d, 2).unwrap_or(0) as u32;
                        m.sample_rate = le32(&d, 4).unwrap_or(0);
                        byte_rate = le32(&d, 8).unwrap_or(0) as u64;
                        m.bits = le16(&d, 14).unwrap_or(0) as u32;
                        if le16(&d, 0) == Some(3) {
                            m.codec = "WAV (float)".into();
                        }
                    }
                    b"LIST" => info(&d, m),
                    _ => id3::parse_v2(&d, m),
                }
            }
            b"data" => {
                if byte_rate > 0 {
                    let bytes = size.min(len.saturating_sub(pos + 8));
                    m.duration_ms = bytes * 1000 / byte_rate;
                    m.bitrate = (byte_rate * 8 / 1000) as u32;
                }
            }
            _ => {}
        }
        pos += 8 + size + (size & 1);
    }
    Ok(())
}

fn info(d: &[u8], m: &mut Meta) {
    if d.len() < 4 || &d[0..4] != b"INFO" {
        return;
    }
    let mut p = 4;
    while p + 8 <= d.len() {
        let size = le32(d, p + 4).unwrap_or(0) as usize;
        let start = p + 8;
        let end = (start + size).min(d.len());
        let raw = &d[start..end];
        let cut = raw.iter().position(|&c| c == 0).unwrap_or(raw.len());
        let v = String::from_utf8_lossy(&raw[..cut]).to_string();
        match &d[p..p + 4] {
            b"INAM" => fill(&mut m.title, &v),
            b"IART" => fill(&mut m.artist, &v),
            b"IPRD" => fill(&mut m.album, &v),
            b"ICRD" => fill(&mut m.year, &year_of(&v)),
            b"IGNR" => fill(&mut m.genre, &genre_name(&v)),
            b"ITRK" | b"IPRT" => {
                if m.track == 0 {
                    m.track = leading_number(&v);
                }
            }
            _ => {}
        }
        p = start + size + (size & 1);
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn reads_wav() {
        let mut fmt = Vec::new();
        fmt.extend_from_slice(&1u16.to_le_bytes());
        fmt.extend_from_slice(&2u16.to_le_bytes());
        fmt.extend_from_slice(&44100u32.to_le_bytes());
        fmt.extend_from_slice(&176_400u32.to_le_bytes());
        fmt.extend_from_slice(&4u16.to_le_bytes());
        fmt.extend_from_slice(&16u16.to_le_bytes());
        let mut list = b"INFO".to_vec();
        list.extend_from_slice(b"INAM");
        list.extend_from_slice(&5u32.to_le_bytes());
        list.extend_from_slice(b"Dusk\0\0");
        let data = vec![0u8; 176_400 * 2];
        let mut body = b"WAVE".to_vec();
        for (id, d) in [(&b"fmt "[..], &fmt), (&b"LIST"[..], &list), (&b"data"[..], &data)] {
            body.extend_from_slice(id);
            body.extend_from_slice(&(d.len() as u32).to_le_bytes());
            body.extend_from_slice(d);
        }
        let mut file = b"RIFF".to_vec();
        file.extend_from_slice(&(body.len() as u32).to_le_bytes());
        file.extend(body);
        let dir = std::env::temp_dir().join(format!("sasha-wav-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.wav");
        std::fs::write(&path, &file).unwrap();
        let m = crate::tags::read(&path);
        assert_eq!(m.title, "Dusk");
        assert_eq!((m.sample_rate, m.bits, m.channels), (44100, 16, 2));
        assert_eq!(m.duration_ms, 2000);
        assert_eq!(m.bitrate, 1411);
        std::fs::remove_dir_all(&dir).ok();
    }
}
