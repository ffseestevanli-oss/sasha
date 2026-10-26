//! MPEG audio (MP1/MP2/MP3) and raw ADTS AAC: tags plus duration/bitrate.

use super::{be32, id3, read_up_to, Meta};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

pub fn read(path: &Path, m: &mut Meta) -> io::Result<()> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    let start = id3::read_v2(&mut f, m)?.min(len);
    let mut end = len;
    if len >= start + 128 {
        f.seek(SeekFrom::End(-128))?;
        let mut t = [0u8; 128];
        f.read_exact(&mut t)?;
        if &t[0..3] == b"TAG" {
            end -= 128;
            id3::parse_v1(&t, m);
        }
    }
    f.seek(SeekFrom::Start(start))?;
    let mut buf = vec![0u8; 64 * 1024];
    let n = read_up_to(&mut f, &mut buf)?;
    buf.truncate(n);
    stream_info(&buf, start, end, m);
    Ok(())
}

/// Fills codec, sample rate, channels, duration and bitrate from the first
/// audio frame (and a Xing/Info/VBRI header when there is one).
/// `buf` starts at file offset `start`; audio ends at `end`.
pub fn stream_info(buf: &[u8], start: u64, end: u64, m: &mut Meta) {
    if let Some((off, h)) = find_frame(buf) {
        m.codec = match h.layer {
            1 => "MP1",
            2 => "MP2",
            _ => "MP3",
        }
        .into();
        m.sample_rate = h.sr;
        m.channels = if h.mono { 1 } else { 2 };
        let audio_bytes = end.saturating_sub(start + off as u64);
        let mut frames = 0u64;
        let mut bytes = 0u64;
        let side = match (h.version == 1, h.mono) {
            (true, true) => 17,
            (true, false) => 32,
            (false, true) => 9,
            (false, false) => 17,
        };
        let x = off + 4 + side;
        if let Some(tag) = buf.get(x..x + 4) {
            if tag == &b"Xing"[..] || tag == &b"Info"[..] {
                let flags = be32(buf, x + 4).unwrap_or(0);
                let mut p = x + 8;
                if flags & 1 != 0 {
                    frames = be32(buf, p).unwrap_or(0) as u64;
                    p += 4;
                }
                if flags & 2 != 0 {
                    bytes = be32(buf, p).unwrap_or(0) as u64;
                }
            }
        }
        let v = off + 4 + 32;
        if frames == 0 && buf.get(v..v + 4) == Some(&b"VBRI"[..]) {
            bytes = be32(buf, v + 10).unwrap_or(0) as u64;
            frames = be32(buf, v + 14).unwrap_or(0) as u64;
        }
        if frames > 0 && h.sr > 0 {
            m.duration_ms = frames * h.spf as u64 * 1000 / h.sr as u64;
            let b = if bytes > 0 { bytes } else { audio_bytes };
            if m.duration_ms > 0 {
                m.bitrate = (b * 8 / m.duration_ms) as u32;
            }
        } else if h.bitrate > 0 {
            // Constant bitrate: bits / (kbit/s) = milliseconds.
            m.bitrate = h.bitrate;
            m.duration_ms = audio_bytes * 8 / h.bitrate as u64;
        }
    } else if let Some((sr, ch)) = find_adts(buf) {
        m.codec = "AAC".into();
        m.sample_rate = sr;
        m.channels = ch;
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Header {
    pub version: u8, // 1, 2 or 25 (MPEG 2.5)
    pub layer: u8,
    pub bitrate: u32, // kbit/s
    pub sr: u32,
    pub mono: bool,
    pub len: usize,
    pub spf: u32,
}

const BR_V1: [[u32; 15]; 3] = [
    [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
    [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
    [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
];
const BR_V2: [[u32; 15]; 2] = [
    [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
    [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
];
const SR: [[u32; 3]; 3] = [[44100, 48000, 32000], [22050, 24000, 16000], [11025, 12000, 8000]];

pub fn parse_header(b: &[u8]) -> Option<Header> {
    if b.len() < 4 || b[0] != 0xFF || b[1] & 0xE0 != 0xE0 {
        return None;
    }
    let ver_bits = (b[1] >> 3) & 3;
    let layer_bits = (b[1] >> 1) & 3;
    if ver_bits == 1 || layer_bits == 0 {
        return None;
    }
    let br_idx = (b[2] >> 4) as usize;
    let sr_idx = ((b[2] >> 2) & 3) as usize;
    if br_idx == 0 || br_idx == 15 || sr_idx == 3 {
        return None;
    }
    let pad = ((b[2] >> 1) & 1) as u32;
    let mono = (b[3] >> 6) == 3;
    let version = match ver_bits {
        3 => 1,
        2 => 2,
        _ => 25,
    };
    let layer = 4 - layer_bits;
    let sr = SR[match version {
        1 => 0,
        2 => 1,
        _ => 2,
    }][sr_idx];
    let bitrate = if version == 1 {
        BR_V1[(layer - 1) as usize][br_idx]
    } else if layer == 1 {
        BR_V2[0][br_idx]
    } else {
        BR_V2[1][br_idx]
    };
    let spf = match (layer, version) {
        (1, _) => 384,
        (2, _) => 1152,
        (_, 1) => 1152,
        _ => 576,
    };
    let len = if layer == 1 {
        ((12 * bitrate * 1000 / sr + pad) * 4) as usize
    } else {
        (spf / 8 * bitrate * 1000 / sr + pad) as usize
    };
    if len < 4 {
        return None;
    }
    Some(Header { version, layer, bitrate, sr, mono, len, spf })
}

/// The first frame header that is followed by another matching one.
fn find_frame(buf: &[u8]) -> Option<(usize, Header)> {
    let mut i = 0;
    while i + 4 <= buf.len() {
        if let Some(h) = parse_header(&buf[i..]) {
            let n = i + h.len;
            if n + 4 > buf.len() {
                return Some((i, h));
            }
            if let Some(h2) = parse_header(&buf[n..]) {
                if h2.sr == h.sr && h2.layer == h.layer {
                    return Some((i, h));
                }
            }
        }
        i += 1;
    }
    None
}

const ADTS_RATES: [u32; 13] = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350];

fn find_adts(b: &[u8]) -> Option<(u32, u32)> {
    let mut i = 0;
    while i + 7 <= b.len() {
        if b[i] == 0xFF && b[i + 1] & 0xF6 == 0xF0 {
            let sri = ((b[i + 2] >> 2) & 0xF) as usize;
            let ch = (((b[i + 2] & 1) << 2) | (b[i + 3] >> 6)) as u32;
            if let Some(&sr) = ADTS_RATES.get(sri) {
                return Some((sr, ch.max(1)));
            }
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    /// MPEG-1 Layer III, 128 kbit/s, 44.1 kHz, joint stereo, no padding.
    const HDR: [u8; 4] = [0xFF, 0xFB, 0x90, 0x40];

    #[test]
    fn header_fields() {
        let h = parse_header(&HDR).unwrap();
        assert_eq!((h.version, h.layer, h.bitrate, h.sr, h.spf), (1, 3, 128, 44100, 1152));
        assert_eq!(h.len, 417);
        assert!(!h.mono);
    }

    #[test]
    fn cbr_duration() {
        let mut buf = Vec::new();
        for _ in 0..20 {
            buf.extend_from_slice(&HDR);
            buf.extend(std::iter::repeat(0).take(413));
        }
        let mut m = Meta::default();
        // pretend the file holds 1,000,000 bytes of audio
        stream_info(&buf, 0, 1_000_000, &mut m);
        assert_eq!(m.codec, "MP3");
        assert_eq!(m.bitrate, 128);
        assert_eq!(m.duration_ms, 62_500);
    }

    #[test]
    fn xing_duration() {
        let mut buf = Vec::new();
        let mut first = HDR.to_vec();
        first.extend(std::iter::repeat(0).take(32));
        first.extend_from_slice(b"Xing");
        first.extend_from_slice(&3u32.to_be_bytes()); // frames + bytes
        first.extend_from_slice(&1000u32.to_be_bytes());
        first.extend_from_slice(&2_000_000u32.to_be_bytes());
        first.resize(417, 0);
        buf.extend(first);
        for _ in 0..3 {
            buf.extend_from_slice(&HDR);
            buf.extend(std::iter::repeat(0).take(413));
        }
        let mut m = Meta::default();
        stream_info(&buf, 0, 9_999_999, &mut m);
        // 1000 frames * 1152 / 44100 = 26.122 s
        assert_eq!(m.duration_ms, 26_122);
        assert_eq!(m.bitrate, (2_000_000u64 * 8 / 26_122) as u32);
    }

    #[test]
    fn reads_file_with_id3() {
        let dir = std::env::temp_dir().join(format!("sasha-mpeg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("a.mp3");
        let mut data = crate::tags::id3::tests::sample_v23();
        for _ in 0..10 {
            data.extend_from_slice(&HDR);
            data.extend(std::iter::repeat(0).take(413));
        }
        std::fs::write(&path, &data).unwrap();
        let m = crate::tags::read(&path);
        assert_eq!(m.title, "Harbor Lights");
        assert_eq!(m.codec, "MP3");
        assert_eq!(m.sample_rate, 44100);
        assert!(m.duration_ms > 0);
        std::fs::remove_dir_all(&dir).ok();
    }
}
