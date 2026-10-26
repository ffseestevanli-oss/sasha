//! Compiles the Qt 6 host (cpp/) and links it into the Rust binary.
//!
//! Qt 6 is located, in order, through:
//!   1. the QMAKE environment variable (path to a Qt 6 qmake),
//!   2. pkg-config (Qt6Widgets, Qt6Quick, Qt6Qml, Qt6Multimedia, Qt6DBus),
//!   3. qmake6, qmake-qt6 or qmake on PATH (must report Qt 6).
//!
//! moc is found through MOC, qmake/qtpaths, pkg-config or the usual paths.
//! KF6 WindowSystem (frosted-glass blur on Plasma) is optional.
//!
//! SASHA_SKIP_QT=1 skips all of this (for `cargo test` on machines without Qt).

use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

const MODULES: [&str; 7] = ["Core", "Gui", "Widgets", "Qml", "Quick", "Multimedia", "DBus"];
const PC_MODULES: [&str; 5] = ["Qt6Widgets", "Qt6Quick", "Qt6Qml", "Qt6Multimedia", "Qt6DBus"];

struct Flags {
    cflags: Vec<String>,
    link_dirs: Vec<String>,
    libs: Vec<String>,
}

fn run(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn qmake_ok(q: &str) -> bool {
    run(q, &["-query", "QT_VERSION"]).map(|v| v.starts_with('6')).unwrap_or(false)
}

fn find_qmake() -> Option<String> {
    if let Ok(q) = env::var("QMAKE") {
        return if qmake_ok(&q) { Some(q) } else { None };
    }
    for q in ["qmake6", "qmake-qt6", "qmake", "/usr/lib64/qt6/bin/qmake", "/usr/lib/qt6/bin/qmake", "/usr/lib/x86_64-linux-gnu/qt6/bin/qmake", "/usr/lib/aarch64-linux-gnu/qt6/bin/qmake"] {
        if qmake_ok(q) {
            return Some(q.to_string());
        }
    }
    None
}

fn parse_pkg(out: &str, f: &mut Flags) {
    for tok in out.split_whitespace() {
        if let Some(d) = tok.strip_prefix("-L") {
            f.link_dirs.push(d.to_string());
        } else if let Some(l) = tok.strip_prefix("-l") {
            f.libs.push(l.to_string());
        } else if tok.starts_with("-I") || tok.starts_with("-D") || tok.starts_with("-isystem") || tok.starts_with("-std") || tok.starts_with("-f") {
            f.cflags.push(tok.to_string());
        }
    }
}

fn from_pkg_config() -> Option<Flags> {
    let mut args = vec!["--cflags", "--libs"];
    args.extend_from_slice(&PC_MODULES);
    let out = run("pkg-config", &args)?;
    let mut f = Flags { cflags: vec![], link_dirs: vec![], libs: vec![] };
    parse_pkg(&out, &mut f);
    if f.libs.is_empty() {
        return None;
    }
    Some(f)
}

fn from_qmake(qmake: &str) -> Option<Flags> {
    let headers = run(qmake, &["-query", "QT_INSTALL_HEADERS"])?;
    let libdir = run(qmake, &["-query", "QT_INSTALL_LIBS"])?;
    let mut cflags = vec![format!("-I{headers}")];
    // Every Qt module's header folder: Quick and Qml headers pull in
    // QtQmlIntegration, QtQmlModels, QtNetwork and friends.
    if let Ok(rd) = std::fs::read_dir(&headers) {
        let mut dirs: Vec<String> = rd
            .flatten()
            .filter(|e| e.path().is_dir())
            .filter_map(|e| e.file_name().to_str().map(|s| s.to_string()))
            .filter(|n| n.starts_with("Qt"))
            .collect();
        dirs.sort();
        for d in dirs {
            cflags.push(format!("-I{headers}/{d}"));
        }
    } else {
        for m in MODULES {
            cflags.push(format!("-I{headers}/Qt{m}"));
        }
    }
    Some(Flags { cflags, link_dirs: vec![libdir], libs: MODULES.iter().rev().map(|m| format!("Qt6{m}")).collect() })
}

fn find_qt() -> (Flags, Option<String>) {
    let qmake = find_qmake();
    if env::var("QMAKE").is_ok() {
        let q = qmake.unwrap_or_else(|| panic!("QMAKE={} is not a working Qt 6 qmake", env::var("QMAKE").unwrap()));
        return (from_qmake(&q).expect("qmake -query failed"), Some(q));
    }
    if let Some(f) = from_pkg_config() {
        return (f, qmake);
    }
    if let Some(q) = &qmake {
        if let Some(f) = from_qmake(q) {
            return (f, qmake);
        }
    }
    panic!(
        "\n\nCould not find the Qt 6 development files (Widgets, Quick, Qml, Multimedia).\n\
         Install them (Arch: qt6-base qt6-declarative qt6-multimedia,\n\
         Fedora: qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel,\n\
         Debian/Kubuntu: qt6-base-dev qt6-base-dev-tools qt6-declarative-dev qt6-multimedia-dev,\n\
         openSUSE: qt6-base-devel qt6-declarative-devel qt6-multimedia-devel)\n\
         or set QMAKE=/path/to/qt6/bin/qmake\n\n"
    );
}

fn moc_ok(path: &str) -> bool {
    let out = match Command::new(path).arg("-v").output() {
        Ok(o) => o,
        Err(_) => return false,
    };
    let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    text.contains(" 6.")
}

fn find_moc(qmake: &Option<String>) -> String {
    if let Ok(m) = env::var("MOC") {
        return m;
    }
    let mut candidates: Vec<String> = Vec::new();
    let mut tools: Vec<&str> = Vec::new();
    if let Some(q) = qmake {
        tools.push(q.as_str());
    }
    tools.extend_from_slice(&["qtpaths6", "qtpaths-qt6", "qtpaths"]);
    for tool in tools {
        for var in ["QT_HOST_LIBEXECS", "QT_INSTALL_LIBEXECS", "QT_HOST_BINS", "QT_INSTALL_BINS"] {
            let out = if tool.contains("qtpaths") { run(tool, &["--query", var]) } else { run(tool, &["-query", var]) };
            if let Some(dir) = out {
                if !dir.is_empty() {
                    candidates.push(format!("{dir}/moc"));
                }
            }
        }
    }
    for var in ["libexecdir", "host_bins", "bindir"] {
        if let Some(dir) = run("pkg-config", &[&format!("--variable={var}"), "Qt6Core"]) {
            if !dir.is_empty() {
                candidates.push(format!("{dir}/moc"));
            }
        }
    }
    for p in [
        "/usr/lib/qt6/libexec/moc",
        "/usr/lib/qt6/moc",
        "/usr/lib64/qt6/libexec/moc",
        "/usr/libexec/qt6/moc",
        "/usr/lib/x86_64-linux-gnu/qt6/libexec/moc",
        "/usr/lib/aarch64-linux-gnu/qt6/libexec/moc",
        "moc-qt6",
        "moc6",
        "moc",
    ] {
        candidates.push(p.to_string());
    }
    for c in &candidates {
        if moc_ok(c) {
            return c.clone();
        }
    }
    panic!("\n\nCould not find Qt 6's moc. Install the Qt 6 base development tools (Debian/Kubuntu: qt6-base-dev-tools) or set MOC=/path/to/moc\n\n");
}

/// Optional: KF6 WindowSystem for KWin's blur-behind.
fn find_kwindowsystem() -> Option<Flags> {
    if env::var("SASHA_NO_KF6").is_ok() {
        return None;
    }
    if let Some(out) = run("pkg-config", &["--cflags", "--libs", "KF6WindowSystem"]) {
        let mut f = Flags { cflags: vec![], link_dirs: vec![], libs: vec![] };
        parse_pkg(&out, &mut f);
        if !f.libs.is_empty() {
            return Some(f);
        }
    }
    for inc in ["/usr/include/KF6/KWindowSystem", "/usr/local/include/KF6/KWindowSystem"] {
        if Path::new(inc).join("KWindowEffects").exists() {
            return Some(Flags { cflags: vec![format!("-I{inc}")], link_dirs: vec![], libs: vec!["KF6WindowSystem".into()] });
        }
    }
    None
}

fn compile(cxx: &str, src: &Path, obj: &Path, flags: &[String], extra: &[String]) {
    let status = Command::new(cxx)
        .args(["-std=c++17", "-O2", "-fPIC", "-Wall", "-c"])
        .arg(src)
        .arg("-o")
        .arg(obj)
        .args(flags)
        .args(extra)
        .args(env::var("CXXFLAGS").unwrap_or_default().split_whitespace())
        .status()
        .unwrap_or_else(|e| panic!("failed to run C++ compiler '{cxx}': {e}"));
    assert!(status.success(), "compiling {} failed", src.display());
}

fn main() {
    for f in ["cpp/host.cpp", "cpp/player.cpp", "cpp/player.h", "build.rs", "assets"] {
        println!("cargo:rerun-if-changed={f}");
    }
    for v in ["QMAKE", "MOC", "CXX", "CXXFLAGS", "SASHA_SKIP_QT", "SASHA_NO_KF6"] {
        println!("cargo:rerun-if-env-changed={v}");
    }
    if env::var("SASHA_SKIP_QT").is_ok() {
        return;
    }

    let (qt, qmake) = find_qt();
    let moc = find_moc(&qmake);
    let kws = find_kwindowsystem();
    if kws.is_some() {
        println!("cargo:warning=KF6 WindowSystem found: the header gets KWin's frosted-glass blur");
    } else {
        println!("cargo:warning=KF6 WindowSystem not found: building without the frosted-glass blur");
    }

    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(env::var("OUT_DIR").unwrap());
    let cxx = env::var("CXX").unwrap_or_else(|_| "c++".to_string());

    let mut flags = qt.cflags.clone();
    flags.push(format!("-I{}", manifest.join("cpp").display()));
    let mut extra = vec![
        format!("-DTN_VERSION=\"{}\"", env::var("CARGO_PKG_VERSION").unwrap()),
        format!("-DTN_ASSET_DIR=\"{}/assets\"", manifest.display()),
    ];
    if let Some(k) = &kws {
        flags.extend(k.cflags.iter().cloned());
        extra.push("-DTN_HAVE_KWINDOWSYSTEM=1".into());
    }

    // moc: Q_OBJECT classes in player.h
    let moc_out = out.join("moc_player.cpp");
    let mut moc_args: Vec<String> = flags.iter().filter(|f| f.starts_with("-I") || f.starts_with("-D")).cloned().collect();
    moc_args.extend(extra.iter().filter(|f| f.starts_with("-DTN_HAVE")).cloned());
    let status = Command::new(&moc)
        .args(&moc_args)
        .arg(manifest.join("cpp/player.h"))
        .arg("-o")
        .arg(&moc_out)
        .status()
        .unwrap_or_else(|e| panic!("failed to run moc '{moc}': {e}"));
    assert!(status.success(), "moc failed on cpp/player.h");

    let sources = [manifest.join("cpp/host.cpp"), manifest.join("cpp/player.cpp"), moc_out];
    let mut objs = Vec::new();
    for src in &sources {
        let obj = out.join(format!("{}.o", src.file_stem().unwrap().to_string_lossy()));
        compile(&cxx, src, &obj, &flags, &extra);
        objs.push(obj);
    }

    let lib = out.join("libsasha_qt.a");
    let _ = std::fs::remove_file(&lib);
    let status = Command::new("ar").arg("crs").arg(&lib).args(&objs).status().expect("failed to run ar");
    assert!(status.success(), "ar failed");

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=sasha_qt");
    let mut link_dirs = qt.link_dirs.clone();
    let mut libs = qt.libs.clone();
    if let Some(k) = kws {
        link_dirs.extend(k.link_dirs);
        libs.extend(k.libs);
    }
    for d in &link_dirs {
        println!("cargo:rustc-link-search=native={d}");
        // Harmless for system Qt, required for a Qt installed in a custom prefix.
        println!("cargo:rustc-link-arg=-Wl,-rpath,{d}");
    }
    for l in &libs {
        println!("cargo:rustc-link-lib=dylib={l}");
    }
    println!("cargo:rustc-link-lib=dylib=stdc++");
}
