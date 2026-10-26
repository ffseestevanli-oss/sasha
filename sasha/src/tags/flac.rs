//! Native FLAC files: STREAMINFO, VORBIS_COMMENT and PICTURE blocks.

use super::{be32, id3, vorbis, Meta};
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::Path;

pub struct StreamInfo {
    pub sample_rate: u32,
    pub channels: u32,
    pub bits: u32,
    pub total_samples: u64,
}

/// The 34-byte STREAMINFO block body.
pub fn parse_streaminfo(b: &[u8]) -> Option<StreamInfo> {
    if b.len() < 18 {
        return None;
    }
    let sample_rate = ((b[10] as u32) << 12) | ((b[11] as u32) << 4) | (b[12] as u32 >> 4);
    let channels = ((b[12] as u32 >> 1) & 7) + 1;
    let bits = (((b[12] as u32 & 1) << 4) | (b[13] as u32 >> 4)) + 1;
    let total_samples = ((b[13] as u64 & 0xF) << 32) | be32(b, 14)? as u64;
    Some(StreamInfo { sample_rate, channels, bits, total_samples })
}

pub fn apply_streaminfo(si: &StreamInfo, m: &mut Meta) {
    m.sample_rate = si.sample_rate;
    m.channels = si.channels;
    m.bits = si.bits;
    if si.sample_rate > 0 && si.total_samples > 0 {
        m.duration_ms = si.total_samples * 1000 / si.sample_rate as u64;
    }
}

pub fn read(path: &Path, m: &mut Meta) -> io::Result<()> {
    let mut f = File::open(path)?;
    let len = f.metadata()?.len();
    // A few taggers put ID3v2 in front of FLAC; read it, then skip past it.
    let start = id3::read_v2(&mut f, m)?;
    f.seek(SeekFrom::Start(start))?;
    let mut magic = [0u8; 4];
    f.read_exact(&mut magic)?;
    if &magic != b"fLaC" {
        return Ok(());
    }
    m.codec = "FLAC".into();
    loop {
        let mut h = [0u8; 4];
        f.read_exact(&mut h)?;
        let last = h[0] & 0x80 != 0;
        let kind = h[0] & 0x7f;
        let blen = ((h[1] as u64) << 16) | ((h[2] as u64) << 8) | h[3] as u64;
        match kind {
            0 | 4 | 6 if blen <= 32 * 1024 * 1024 => {
                let mut data = vec![0u8; blen as usize];
                f.read_exact(&mut data)?;
                match kind {
                    0 => {
                        if let Some(si) = parse_streaminfo(&data) {
                            apply_streaminfo(&si, m);
                        }
                    }
                    4 => vorbis::parse_comment(&data, m),
                    _ => {
                        if let Some(p) = vorbis::parse_picture_block(&data) {
                            m.offer_picture(p);
                        }
                    }
                }
            }
            127 => break, // invalid block type
            _ => {
                f.seek(SeekFrom::Current(blen as i64))?;
            }
        }
        if last {
            break;
        }
    }
    let audio_start = f.stream_position()?;
    if m.duration_ms > 0 {
        m.bitrate = (len.saturating_sub(audio_start) * 8 / m.duration_ms) as u32;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tags::vorbis::tests::{comment_block, picture_block};

    pub fn streaminfo(sr: u32, ch: u32, bps: u32, total: u64) -> Vec<u8> {
        let mut b = vec![0u8; 34];
        b[0..2].copy_from_slice(&4096u16.to_be_bytes());
        b[2..4].copy_from_slice(&4096u16.to_be_bytes());
        b[10] = (sr >> 12) as u8;
        b[11] = (sr >> 4) as u8;
        b[12] = (((sr & 0xF) << 4) | ((ch - 1) << 1) | ((bps - 1) >> 4)) as u8;
        b[13] = ((((bps - 1) & 0xF) << 4) as u64 | (total >> 32)) as u8;
        b[14..18].copy_from_slice(&(total as u32).to_be_bytes());
        b
    }

    fn block(kind: u8, last: bool, data: &[u8]) -> Vec<u8> {
        let mut b = vec![kind | if last { 0x80 } else { 0 }];
        let n = data.len();
        b.extend_from_slice(&[(n >> 16) as u8, (n >> 8) as u8, n as u8]);
        b.extend_from_slice(data);
        b
    }

    #[test]
    fn streaminfo_roundtrip() {
        let si = parse_streaminfo(&streaminfo(44100, 2, 16, 44100 * 200)).unwrap();
        assert_eq!((si.sample_rate, si.channels, si.bits, si.total_samples), (44100, 2, 16, 44100 * 200));
        let si = parse_streaminfo(&streaminfo(96000, 2, 24, 1 << 33)).unwrap();
        assert_eq!((si.sample_rate, si.bits, si.total_samples), (96000, 24, 1 << 33));
    }

    #[test]
    fn reads_flac_file() {
        let dir = std::env::temp_dir().join(format!("sasha-flac-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.flac");
        let mut d = b"fLaC".to_vec();
        d.extend(block(0, false, &streaminfo(48000, 2, 24, 48000 * 60)));
        d.extend(block(1, false, &[0u8; 100])); // padding
        d.extend(block(4, false, &comment_block(&["TITLE=Driftwood", "ARTIST=Marlow Reed", "TRACKNUMBER=1"])));
        let jpg: Vec<u8> = [0xFF, 0xD8, 0xFF, 0xE0].iter().copied().chain(std::iter::repeat(9).take(30)).collect();
        d.extend(block(6, true, &picture_block(&jpg)));
        d.extend(std::iter::repeat(0x55).take(720_000)); // "audio"
        std::fs::write(&path, &d).unwrap();
        let m = crate::tags::read(&path);
        assert_eq!(m.codec, "FLAC");
        assert_eq!(m.title, "Driftwood");
        assert_eq!(m.track, 1);
        assert_eq!((m.sample_rate, m.bits, m.channels), (48000, 24, 2));
        assert_eq!(m.duration_ms, 60_000);
        assert_eq!(m.bitrate, 96);
        assert_eq!(m.picture.unwrap().mime, "image/jpeg");
        std::fs::remove_dir_all(&dir).ok();
    }
}
