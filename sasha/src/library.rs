//! Library scanning: finds audio files, reads their tags, groups them into
//! albums, saves cover art to the cache, and serialises the result for Qt.

use crate::tags::{self, Meta, AUDIO_EXTS};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};

pub struct Track {
    pub path: PathBuf,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: String,
    pub genre: String,
    pub year: String,
    pub track: u32,
    pub disc: u32,
    pub duration_ms: u64,
    pub codec: String,
    pub sample_rate: u32,
    pub bits: u32,
    pub bitrate: u32,
    pub channels: u32,
    pub size: u64,
    pub album_idx: usize,
    key: String,
}

pub struct Album {
    pub key: String,
    pub title: String,
    pub artist: String,
    pub year: String,
    pub genre: String,
    pub cover: String,
    pub tracks: Vec<usize>,
    pub duration_ms: u64,
    pub size: u64,
    pub codec: String,
}

/// A folder below the music root that holds music (directly or further down).
pub struct Folder {
    /// path relative to the music root ("" for the root itself)
    pub rel: String,
    pub name: String,
    /// index of the parent folder, -1 for the root
    pub parent: i64,
    /// subfolders, sorted by name
    pub children: Vec<usize>,
    /// tracks directly in this folder, sorted by file name
    pub tracks: Vec<usize>,
    /// tracks in this folder and everything below it
    pub total: u32,
    pub cover: String,
}

#[derive(Default)]
pub struct Library {
    pub tracks: Vec<Track>,
    pub albums: Vec<Album>,
    pub folders: Vec<Folder>,
}

pub const UNKNOWN_ARTIST: &str = "Unknown Artist";
pub const VARIOUS_ARTISTS: &str = "Various Artists";

pub fn is_audio(p: &Path) -> bool {
    p.extension()
        .and_then(|e| e.to_str())
        .map(|e| AUDIO_EXTS.contains(&e.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

/// All audio files below `root`, sorted. Hidden folders are skipped and
/// symlinked folders are not followed (no loops).
pub fn collect(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let rd = match fs::read_dir(&dir) {
            Ok(r) => r,
            Err(_) => continue,
        };
        for entry in rd.flatten() {
            let path = entry.path();
            let hidden = path.file_name().and_then(|n| n.to_str()).map(|n| n.starts_with('.')).unwrap_or(false);
            if hidden {
                continue;
            }
            let ft = match entry.file_type() {
                Ok(t) => t,
                Err(_) => continue,
            };
            if ft.is_dir() {
                stack.push(path);
            } else if ft.is_file() {
                if is_audio(&path) {
                    out.push(path);
                }
            } else if ft.is_symlink() {
                // follow links to files, not to folders
                if let Ok(md) = fs::metadata(&path) {
                    if md.is_file() && is_audio(&path) {
                        out.push(path);
                    }
                }
            }
        }
    }
    out.sort();
    out
}

pub fn scan(root: &Path, cache_dir: &Path, done: &AtomicU32, total: &AtomicU32) -> Library {
    done.store(0, Ordering::Relaxed);
    total.store(0, Ordering::Relaxed);
    let files = collect(root);
    total.store(files.len() as u32, Ordering::Relaxed);
    let cover_dir = cache_dir.join("covers");
    let _ = fs::create_dir_all(&cover_dir);
    let mut covers: HashMap<String, String> = HashMap::new();
    let mut tracks = Vec::with_capacity(files.len());
    for path in files {
        let meta = std::panic::catch_unwind(|| tags::read(&path)).unwrap_or_default();
        let size = fs::metadata(&path).map(|md| md.len()).unwrap_or(0);
        tracks.push(make_track(path, meta, size, &cover_dir, &mut covers));
        done.fetch_add(1, Ordering::Relaxed);
    }
    group(tracks, &covers, root)
}

fn album_key(album: &str, album_artist: &str, path: &Path) -> String {
    if !album_artist.is_empty() {
        format!("aa\u{1f}{}\u{1f}{}", album_artist.to_lowercase(), album.to_lowercase())
    } else {
        let dir = path.parent().map(|d| d.to_string_lossy().to_string()).unwrap_or_default();
        format!("dir\u{1f}{}\u{1f}{}", album.to_lowercase(), dir)
    }
}

fn make_track(path: PathBuf, mut m: Meta, size: u64, cover_dir: &Path, covers: &mut HashMap<String, String>) -> Track {
    if m.title.is_empty() {
        m.title = path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_default();
    }
    if m.album.is_empty() {
        m.album = path
            .parent()
            .and_then(|d| d.file_name())
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "Unknown Album".into());
    }
    let key = album_key(&m.album, &m.album_artist, &path);
    if let Some(pic) = m.picture.take() {
        if !covers.contains_key(&key) {
            if let Some(file) = save_cover(cover_dir, &key, &pic.mime, &pic.data) {
                covers.insert(key.clone(), file);
            }
        }
    }
    Track {
        path,
        title: m.title,
        artist: m.artist,
        album: m.album,
        album_artist: m.album_artist,
        genre: m.genre,
        year: m.year,
        track: m.track,
        disc: m.disc,
        duration_ms: m.duration_ms,
        codec: m.codec,
        sample_rate: m.sample_rate,
        bits: m.bits,
        bitrate: m.bitrate,
        channels: m.channels,
        size,
        album_idx: 0,
        key,
    }
}

pub fn fnv64(s: &str) -> u64 {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        h ^= b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    h
}

fn save_cover(dir: &Path, key: &str, mime: &str, data: &[u8]) -> Option<String> {
    let ext = match mime {
        "image/png" => "png",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "image/bmp" => "bmp",
        _ => "jpg",
    };
    let file = dir.join(format!("{:016x}.{}", fnv64(key), ext));
    let same = fs::metadata(&file).map(|md| md.len() == data.len() as u64).unwrap_or(false);
    if !same && fs::write(&file, data).is_err() {
        return None;
    }
    Some(file.to_string_lossy().to_string())
}

/// cover.jpg, folder.png, front.jpg ... in the album's folder, else any image there.
fn folder_cover(dir: &Path, cache: &mut HashMap<PathBuf, String>) -> String {
    if let Some(c) = cache.get(dir) {
        return c.clone();
    }
    let mut images: Vec<PathBuf> = fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| {
                    let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
                    matches!(ext.as_str(), "jpg" | "jpeg" | "png" | "webp") && p.is_file()
                })
                .collect()
        })
        .unwrap_or_default();
    images.sort();
    let rank = |p: &PathBuf| -> usize {
        let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("").to_lowercase();
        const NAMES: [&str; 6] = ["cover", "folder", "front", "album", "albumart", "albumartlarge"];
        NAMES.iter().position(|n| stem == *n).unwrap_or_else(|| {
            if stem.contains("cover") || stem.contains("front") {
                NAMES.len()
            } else {
                NAMES.len() + 1
            }
        })
    };
    let best = images.iter().min_by_key(|p| rank(p)).map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
    cache.insert(dir.to_path_buf(), best.clone());
    best
}

fn group(mut tracks: Vec<Track>, covers: &HashMap<String, String>, root: &Path) -> Library {
    tracks.sort_by_cached_key(|t| {
        let artist = if t.album_artist.is_empty() { &t.artist } else { &t.album_artist };
        (artist.to_lowercase(), t.album.to_lowercase(), t.key.clone(), t.disc, t.track, t.title.to_lowercase(), t.path.clone())
    });
    let mut index: HashMap<String, usize> = HashMap::new();
    let mut albums: Vec<Album> = Vec::new();
    for (i, t) in tracks.iter_mut().enumerate() {
        let ai = match index.get(&t.key) {
            Some(&a) => a,
            None => {
                albums.push(Album {
                    key: t.key.clone(),
                    title: t.album.clone(),
                    artist: String::new(),
                    year: String::new(),
                    genre: String::new(),
                    cover: String::new(),
                    tracks: Vec::new(),
                    duration_ms: 0,
                    size: 0,
                    codec: String::new(),
                });
                index.insert(t.key.clone(), albums.len() - 1);
                albums.len() - 1
            }
        };
        t.album_idx = ai;
        albums[ai].tracks.push(i);
    }

    let mut folder_cache: HashMap<PathBuf, String> = HashMap::new();
    for a in albums.iter_mut() {
        a.tracks.sort_by_key(|&i| (tracks[i].disc, tracks[i].track, tracks[i].title.to_lowercase()));
        let ts: Vec<&Track> = a.tracks.iter().map(|&i| &tracks[i]).collect();
        a.artist = if let Some(t) = ts.iter().find(|t| !t.album_artist.is_empty()) {
            t.album_artist.clone()
        } else {
            let first = &ts[0].artist;
            if ts.iter().all(|t| t.artist.eq_ignore_ascii_case(first)) {
                if first.is_empty() {
                    UNKNOWN_ARTIST.to_string()
                } else {
                    first.clone()
                }
            } else {
                VARIOUS_ARTISTS.to_string()
            }
        };
        a.year = ts.iter().filter(|t| !t.year.is_empty()).map(|t| t.year.clone()).min().unwrap_or_default();
        a.genre = ts.iter().find(|t| !t.genre.is_empty()).map(|t| t.genre.clone()).unwrap_or_default();
        a.duration_ms = ts.iter().map(|t| t.duration_ms).sum();
        a.size = ts.iter().map(|t| t.size).sum();
        let first_codec = &ts[0].codec;
        a.codec = if ts.iter().all(|t| &t.codec == first_codec) { first_codec.clone() } else { "Mixed".into() };
        a.cover = match covers.get(&a.key) {
            Some(c) => c.clone(),
            None => ts[0].path.parent().map(|d| folder_cover(d, &mut folder_cache)).unwrap_or_default(),
        };
    }

    // Albums sorted by artist, then title; tracks keep their own order.
    let mut order: Vec<usize> = (0..albums.len()).collect();
    order.sort_by_cached_key(|&i| (albums[i].artist.to_lowercase(), albums[i].title.to_lowercase(), i));
    let mut new_index = vec![0usize; albums.len()];
    for (new, &old) in order.iter().enumerate() {
        new_index[old] = new;
    }
    let mut slots: Vec<Option<Album>> = albums.into_iter().map(Some).collect();
    let albums: Vec<Album> = order.iter().map(|&old| slots[old].take().unwrap()).collect();
    for t in tracks.iter_mut() {
        t.album_idx = new_index[t.album_idx];
    }
    let folders = build_folders(root, &tracks, &albums);
    Library { tracks, albums, folders }
}

/// Finds or creates the folder for `rel` (and its parents).
fn ensure_folder(folders: &mut Vec<Folder>, index: &mut HashMap<PathBuf, usize>, rel: &Path) -> usize {
    if let Some(&i) = index.get(rel) {
        return i;
    }
    let parent_rel = rel.parent().map(|p| p.to_path_buf()).unwrap_or_default();
    let parent = ensure_folder(folders, index, &parent_rel);
    let name = rel.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    folders.push(Folder {
        rel: rel.to_string_lossy().to_string(),
        name,
        parent: parent as i64,
        children: Vec::new(),
        tracks: Vec::new(),
        total: 0,
        cover: String::new(),
    });
    let i = folders.len() - 1;
    folders[parent].children.push(i);
    index.insert(rel.to_path_buf(), i);
    i
}

fn build_folders(root: &Path, tracks: &[Track], albums: &[Album]) -> Vec<Folder> {
    let root_name = root
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| root.to_string_lossy().to_string());
    let mut folders = vec![Folder {
        rel: String::new(),
        name: root_name,
        parent: -1,
        children: Vec::new(),
        tracks: Vec::new(),
        total: 0,
        cover: String::new(),
    }];
    let mut index: HashMap<PathBuf, usize> = HashMap::new();
    index.insert(PathBuf::new(), 0);
    for (ti, t) in tracks.iter().enumerate() {
        let dir = t.path.parent().unwrap_or_else(|| Path::new(""));
        // Files reached through symlinks from outside the root land in the root.
        let rel = dir.strip_prefix(root).map(|p| p.to_path_buf()).unwrap_or_default();
        let fi = ensure_folder(&mut folders, &mut index, &rel);
        folders[fi].tracks.push(ti);
    }
    // Sort, then add up totals and pick covers from the bottom up (children
    // always have higher indices than their parents).
    let names: Vec<String> = folders.iter().map(|f| f.name.to_lowercase()).collect();
    for f in folders.iter_mut() {
        f.children.sort_by(|&a, &b| names[a].cmp(&names[b]));
        f.tracks.sort_by_cached_key(|&t| tracks[t].path.file_name().map(|n| n.to_string_lossy().to_lowercase()).unwrap_or_default());
    }
    for i in (0..folders.len()).rev() {
        let mut total = folders[i].tracks.len() as u32;
        let mut cover = String::new();
        if let Some(&t) = folders[i].tracks.first() {
            cover = albums.get(tracks[t].album_idx).map(|a| a.cover.clone()).unwrap_or_default();
        }
        for &c in &folders[i].children {
            total += folders[c].total;
            if cover.is_empty() {
                cover = folders[c].cover.clone();
            }
        }
        folders[i].total = total;
        folders[i].cover = cover;
    }
    folders
}

fn clean(s: &str) -> String {
    s.chars().map(|c| if c == '\u{1f}' || c == '\n' || c == '\r' { ' ' } else { c }).collect()
}

fn track_fields(t: &Track) -> [String; 17] {
    [
        clean(&t.path.to_string_lossy()),
        clean(&t.title),
        clean(&t.artist),
        clean(&t.album),
        clean(&t.album_artist),
        clean(&t.genre),
        clean(&t.year),
        t.track.to_string(),
        t.disc.to_string(),
        t.duration_ms.to_string(),
        clean(&t.codec),
        t.sample_rate.to_string(),
        t.bits.to_string(),
        t.bitrate.to_string(),
        t.channels.to_string(),
        t.size.to_string(),
        t.album_idx.to_string(),
    ]
}

/// One file outside the library (opened from a file manager): a single "T"
/// record with album index -1, plus an 18th field with its cached cover file
/// (empty if none).
pub fn single(path: &Path, cache_dir: &Path) -> Vec<u8> {
    let meta = std::panic::catch_unwind(|| tags::read(path)).unwrap_or_default();
    let size = fs::metadata(path).map(|md| md.len()).unwrap_or(0);
    let cover_dir = cache_dir.join("covers");
    let _ = fs::create_dir_all(&cover_dir);
    let mut covers: HashMap<String, String> = HashMap::new();
    let t = make_track(path.to_path_buf(), meta, size, &cover_dir, &mut covers);
    let cover = covers.get(&t.key).cloned().unwrap_or_default();
    let mut fields = track_fields(&t);
    fields[16] = "-1".into();
    let mut s = String::from("T");
    for f in fields.iter().chain(std::iter::once(&clean(&cover))) {
        s.push('\u{1f}');
        s.push_str(f);
    }
    s.into_bytes()
}

/// Serialises the library for the Qt side: one record per line, fields
/// separated by 0x1F. "T" records are tracks (in display order), "A" records
/// are albums (in display order).
pub fn blob(lib: &Library) -> Vec<u8> {
    let mut s = String::new();
    let sep = '\u{1f}';
    for t in &lib.tracks {
        let fields = track_fields(t);
        s.push('T');
        for f in fields.iter() {
            s.push(sep);
            s.push_str(f);
        }
        s.push('\n');
    }
    for a in &lib.albums {
        let tracks: Vec<String> = a.tracks.iter().map(|i| i.to_string()).collect();
        let fields: [String; 9] = [
            clean(&a.title),
            clean(&a.artist),
            clean(&a.year),
            clean(&a.genre),
            clean(&a.cover),
            a.duration_ms.to_string(),
            a.size.to_string(),
            clean(&a.codec),
            tracks.join(","),
        ];
        s.push('A');
        for f in fields.iter() {
            s.push(sep);
            s.push_str(f);
        }
        s.push('\n');
    }
    for f in &lib.folders {
        let join = |v: &Vec<usize>| v.iter().map(|i| i.to_string()).collect::<Vec<_>>().join(",");
        let fields: [String; 7] = [
            clean(&f.rel),
            clean(&f.name),
            f.parent.to_string(),
            f.total.to_string(),
            clean(&f.cover),
            join(&f.tracks),
            join(&f.children),
        ];
        s.push('F');
        for fl in fields.iter() {
            s.push(sep);
            s.push_str(fl);
        }
        s.push('\n');
    }
    s.into_bytes()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_file_record() {
        let dir = std::env::temp_dir().join(format!("sasha-single-{}", std::process::id()));
        let _ = fs::create_dir_all(dir.join("Some Album"));
        let file = dir.join("Some Album").join("My Song.mp3");
        fs::write(&file, b"not really audio").unwrap();
        let rec = String::from_utf8(single(&file, &dir)).unwrap();
        let f: Vec<&str> = rec.split('\u{1f}').collect();
        assert_eq!(f[0], "T");
        assert_eq!(f.len(), 19);
        assert_eq!(f[1], file.to_string_lossy());
        assert_eq!(f[2], "My Song");
        assert_eq!(f[4], "Some Album");
        assert_eq!(f[17], "-1");
        assert_eq!(f[18], "");
        let _ = fs::remove_dir_all(&dir);
    }

    fn track(path: &str, title: &str, artist: &str, album: &str, aa: &str, n: u32) -> Track {
        let path = PathBuf::from(path);
        let key = album_key(album, aa, &path);
        Track {
            path,
            title: title.into(),
            artist: artist.into(),
            album: album.into(),
            album_artist: aa.into(),
            genre: String::new(),
            year: "2020".into(),
            track: n,
            disc: 0,
            duration_ms: 1000,
            codec: "MP3".into(),
            sample_rate: 44100,
            bits: 0,
            bitrate: 320,
            channels: 2,
            size: 10,
            album_idx: 0,
            key,
        }
    }

    #[test]
    fn groups_and_orders_albums() {
        let tracks = vec![
            track("/m/z/2.mp3", "Two", "Zed", "Zulu", "", 2),
            track("/m/z/1.mp3", "One", "Zed", "Zulu", "", 1),
            track("/m/c/1.mp3", "Alpha", "Ann", "Comp", "", 1),
            track("/m/c/2.mp3", "Beta", "Bob", "Comp", "", 2),
            track("/m/a/1.mp3", "First", "Guest", "Apex", "Abe", 1),
            track("/m/a/2.mp3", "Second", "Abe", "Apex", "Abe", 2),
        ];
        let lib = group(tracks, &HashMap::new(), Path::new("/m"));
        assert_eq!(lib.albums.len(), 3);
        let names: Vec<(&str, &str)> = lib.albums.iter().map(|a| (a.artist.as_str(), a.title.as_str())).collect();
        assert_eq!(names, vec![("Abe", "Apex"), ("Various Artists", "Comp"), ("Zed", "Zulu")]);
        for (ai, a) in lib.albums.iter().enumerate() {
            for &ti in &a.tracks {
                assert_eq!(lib.tracks[ti].album_idx, ai);
            }
        }
        let zulu = &lib.albums[2];
        let titles: Vec<&str> = zulu.tracks.iter().map(|&i| lib.tracks[i].title.as_str()).collect();
        assert_eq!(titles, vec!["One", "Two"]);
        assert_eq!(zulu.duration_ms, 2000);
    }

    #[test]
    fn blob_has_one_line_per_record() {
        let tracks = vec![track("/m/a/1.mp3", "Line\nbreak", "A\u{1f}B", "Al", "", 1)];
        let lib = group(tracks, &HashMap::new(), Path::new("/m"));
        let b = String::from_utf8(blob(&lib)).unwrap();
        let lines: Vec<&str> = b.lines().collect();
        // one track, one album, and the folders /m and /m/a
        assert_eq!(lines.len(), 4);
        assert!(lines[2].starts_with('F') && lines[3].starts_with('F'));
        assert_eq!(lines[2].split('\u{1f}').count(), 8);
        assert_eq!(lines[0].split('\u{1f}').count(), 18);
        assert_eq!(lines[1].split('\u{1f}').count(), 10);
        assert!(lines[0].contains("Line break"));
    }

    #[test]
    fn builds_the_folder_tree() {
        let tracks = vec![
            track("/m/Rock/B Band/Second/2.mp3", "b2", "B Band", "Second", "", 2),
            track("/m/Rock/A Band/First/1.mp3", "a1", "A Band", "First", "", 1),
            track("/m/Rock/A Band/First/2.mp3", "a2", "A Band", "First", "", 2),
            track("/m/loose.mp3", "loose", "X", "m", "", 0),
            track("/elsewhere/link.mp3", "link", "Y", "elsewhere", "", 0),
        ];
        let lib = group(tracks, &HashMap::new(), Path::new("/m"));
        let f = &lib.folders;
        let root = &f[0];
        assert_eq!(root.name, "m");
        assert_eq!(root.parent, -1);
        assert_eq!(root.total, 5);
        assert_eq!(root.tracks.len(), 2); // loose.mp3 and the symlinked file
        let rock = root.children.iter().map(|&c| &f[c]).find(|x| x.name == "Rock").unwrap();
        assert_eq!(rock.total, 3);
        assert_eq!(rock.rel, "Rock");
        let bands: Vec<&str> = rock.children.iter().map(|&c| f[c].name.as_str()).collect();
        assert_eq!(bands, vec!["A Band", "B Band"]);
        let a = &f[rock.children[0]];
        let first = &f[a.children[0]];
        assert_eq!(first.rel, "Rock/A Band/First");
        let titles: Vec<&str> = first.tracks.iter().map(|&t| lib.tracks[t].title.as_str()).collect();
        assert_eq!(titles, vec!["a1", "a2"]);
        for (i, x) in f.iter().enumerate() {
            for &c in &x.children {
                assert_eq!(f[c].parent, i as i64);
            }
        }
    }

    #[test]
    fn scans_a_folder_with_covers() {
        let root = std::env::temp_dir().join(format!("sasha-lib-{}", std::process::id()));
        let cache = root.join(".cache");
        let album = root.join("Artist").join("Record");
        fs::create_dir_all(&album).unwrap();
        fs::write(album.join("01 intro.mp3"), b"not really audio").unwrap();
        fs::write(album.join("02 song.flac"), b"nope").unwrap();
        fs::write(album.join("folder.jpg"), [0xFF, 0xD8, 0xFF]).unwrap();
        fs::write(album.join("notes.txt"), b"skip me").unwrap();
        fs::create_dir_all(root.join(".hidden")).unwrap();
        fs::write(root.join(".hidden").join("x.mp3"), b"").unwrap();
        let done = AtomicU32::new(0);
        let total = AtomicU32::new(0);
        let lib = scan(&root, &cache, &done, &total);
        assert_eq!(lib.tracks.len(), 2);
        assert_eq!(done.load(Ordering::Relaxed), 2);
        assert_eq!(lib.albums.len(), 1);
        assert_eq!(lib.albums[0].title, "Record");
        assert!(lib.albums[0].cover.ends_with("folder.jpg"));
        assert_eq!(lib.tracks[0].title, "01 intro");
        fs::remove_dir_all(&root).ok();
    }
}
