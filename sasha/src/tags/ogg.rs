//! Ogg containers: Vorbis, Opus and FLAC-in-Ogg headers and comments.

use super::{flac, le16, le32, le64, read_up_to, vorbis, Meta};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

/// Reads the first `want` packets of the first logical stream.
fn first_packets(f: &mut File, want: usize) -> io::Result<(Vec<Vec<u8>>, u32)> {
    let mut packets: Vec<Vec<u8>> = Vec::new();
    let mut cur = Vec::new();
    let mut serial: Option<u32> = None;
    let mut total = 0usize;
    while packets.len() < want {
        let mut h = [0u8; 27];
        if f.read_exact(&mut h).is_err() || &h[0..4] != b"OggS" {
            break;
        }
        let ser = u32::from_le_bytes([h[14], h[15], h[16], h[17]]);
        let nseg = h[26] as usize;
        let mut lace = vec![0u8; nseg];
        f.read_exact(&mut lace)?;
        let body_len: usize = lace.iter().map(|&x| x as usize).sum();
        let mut body = vec![0u8; body_len];
        f.read_exact(&mut body)?;
        total += body_len;
        if serial.is_none() {
            serial = Some(ser);
        }
        if Some(ser) != serial {
            continue;
        }
        let mut p = 0;
        for &l in &lace {
            cur.extend_from_slice(&body[p..p + l as usize]);
            p += l as usize;
            if l < 255 {
                packets.push(std::mem::take(&mut cur));
                if packets.len() >= want {
                    break;
                }
            }
        }
        if total > 32 * 1024 * 1024 {
            break;
        }
    }
    Ok((packets, serial.unwrap_or(0)))
}

/// Granule position of the last page of `serial`.
fn last_granule(f: &mut File, len: u64, serial: u32) -> io::Result<Option<u64>> {
    let take = len.min(128 * 1024);
    f.seek(SeekFrom::Start(len - take))?;
    let mut b = vec![0u8; take as usize];
    let n = read_up_to(f, &mut b)?;
    b.truncate(n);
    if b.len() < 27 {
        return Ok(None);
    }
    let mut i = b.len() - 27;
    loop {
        if &b[i..i + 4] == b"OggS" && le32(&b, i + 14) == Some(serial) {
            if let Some(g) = le64(&b, i + 6) {
                if g != u64::MAX {
                    return Ok(Some(g));
                }
            }
        }
        if i == 0 {
            break;
        }
        i -= 1;
    }
    Ok(None)
}

pub fn read(path: &Path, m: &mut Meta) -> io::Result<()> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    let (packets, serial) = first_packets(&mut f, 2)?;
    let id = match packets.first() {
        Some(p) => p,
        None => return Ok(()),
    };
    let comment = packets.get(1);
    // (rate used for the granule position, samples to skip at the start)
    let mut granule_rate = 0u32;
    let mut pre_skip = 0u64;
    if id.starts_with(b"\x01vorbis") {
        m.codec = "Vorbis".into();
        m.channels = *id.get(11).unwrap_or(&0) as u32;
        m.sample_rate = le32(id, 12).unwrap_or(0);
        let nominal = le32(id, 20).unwrap_or(0) as i32;
        if nominal > 0 {
            m.bitrate = nominal as u32 / 1000;
        }
        granule_rate = m.sample_rate;
        if let Some(c) = comment {
            if c.starts_with(b"\x03vorbis") {
                vorbis::parse_comment(&c[7..], m);
            }
        }
    } else if id.starts_with(b"OpusHead") {
        m.codec = "Opus".into();
        m.channels = *id.get(9).unwrap_or(&0) as u32;
        pre_skip = le16(id, 10).unwrap_or(0) as u64;
        m.sample_rate = 48000;
        granule_rate = 48000;
        if let Some(c) = comment {
            if c.starts_with(b"OpusTags") {
                vorbis::parse_comment(&c[8..], m);
            }
        }
    } else if id.starts_with(b"\x7fFLAC") {
        // 0x7F "FLAC" major minor count(2) "fLaC" + metadata block header (4)
        m.codec = "FLAC".into();
        if let Some(si) = id.get(17..).and_then(flac::parse_streaminfo) {
            flac::apply_streaminfo(&si, m);
            granule_rate = si.sample_rate;
        }
        if let Some(c) = comment {
            if c.len() > 4 && c[0] & 0x7f == 4 {
                vorbis::parse_comment(&c[4..], m);
            }
        }
    } else {
        return Ok(());
    }
    if granule_rate > 0 {
        if let Some(g) = last_granule(&mut f, len, serial)? {
            let samples = g.saturating_sub(pre_skip);
            let d = samples * 1000 / granule_rate as u64;
            if d > 0 {
                m.duration_ms = d;
            }
        }
    }
    if m.duration_ms > 0 && (m.bitrate == 0 || m.codec == "Opus" || m.codec == "FLAC") {
        m.bitrate = (len * 8 / m.duration_ms) as u32;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::tags::vorbis::tests::comment_block;

    fn page(serial: u32, seq: u32, granule: u64, packets: &[&[u8]]) -> Vec<u8> {
        let mut lace = Vec::new();
        let mut body = Vec::new();
        for p in packets {
            let mut n = p.len();
            while n >= 255 {
                lace.push(255u8);
                n -= 255;
            }
            lace.push(n as u8);
            body.extend_from_slice(p);
        }
        let mut h = b"OggS\x00\x00".to_vec();
        h.extend_from_slice(&granule.to_le_bytes());
        h.extend_from_slice(&serial.to_le_bytes());
        h.extend_from_slice(&seq.to_le_bytes());
        h.extend_from_slice(&[0, 0, 0, 0]);
        h.push(lace.len() as u8);
        h.extend(lace);
        h.extend(body);
        h
    }

    #[test]
    fn reads_opus() {
        let dir = std::env::temp_dir().join(format!("sasha-ogg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.opus");
        let mut head = b"OpusHead\x01\x02".to_vec();
        head.extend_from_slice(&312u16.to_le_bytes());
        head.extend_from_slice(&44100u32.to_le_bytes());
        head.extend_from_slice(&[0, 0, 0]);
        let mut tags = b"OpusTags".to_vec();
        // long enough to span two lacing values
        let long_title = format!("TITLE={}", "Creek Bed ".repeat(40));
        tags.extend(comment_block(&[&long_title, "ARTIST=Fern & Hollow", "TRACKNUMBER=3"]));
        let mut d = page(77, 0, 0, &[&head]);
        d.extend(page(77, 1, 0, &[&tags]));
        d.extend(page(77, 2, 48000 * 90 + 312, &[&[0u8; 300]]));
        std::fs::write(&path, &d).unwrap();
        let m = crate::tags::read(&path);
        assert_eq!(m.codec, "Opus");
        assert!(m.title.starts_with("Creek Bed Creek Bed"));
        assert_eq!(m.artist, "Fern & Hollow");
        assert_eq!(m.track, 3);
        assert_eq!(m.channels, 2);
        assert_eq!(m.duration_ms, 90_000);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn reads_vorbis() {
        let dir = std::env::temp_dir().join(format!("sasha-vorbis-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.ogg");
        let mut id = b"\x01vorbis".to_vec();
        id.extend_from_slice(&0u32.to_le_bytes());
        id.push(2);
        id.extend_from_slice(&44100u32.to_le_bytes());
        id.extend_from_slice(&0u32.to_le_bytes());
        id.extend_from_slice(&192_000u32.to_le_bytes());
        id.extend_from_slice(&0u32.to_le_bytes());
        id.extend_from_slice(&[0xb8, 1]);
        let mut c = b"\x03vorbis".to_vec();
        c.extend(comment_block(&["TITLE=Tall Grass", "ALBUM=Field Notes"]));
        c.push(1);
        let mut d = page(5, 0, 0, &[&id]);
        d.extend(page(5, 1, 0, &[&c, &[5u8; 20]]));
        d.extend(page(5, 2, 44100 * 30, &[&[0u8; 50]]));
        std::fs::write(&path, &d).unwrap();
        let m = crate::tags::read(&path);
        assert_eq!(m.codec, "Vorbis");
        assert_eq!(m.title, "Tall Grass");
        assert_eq!(m.album, "Field Notes");
        assert_eq!(m.sample_rate, 44100);
        assert_eq!(m.bitrate, 192);
        assert_eq!(m.duration_ms, 30_000);
        std::fs::remove_dir_all(&dir).ok();
    }
}
