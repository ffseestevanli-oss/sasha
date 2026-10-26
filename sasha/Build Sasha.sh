#!/usr/bin/env bash
# ---------------------------------------------------------------------------
#  Build Sasha
#
#  Drop this script into the extracted Sasha source folder (or the folder
#  that contains it) and double-click it. It will:
#    1. find the Sasha source,
#    2. check for Rust, a C++ compiler and Qt 6 (Quick + Multimedia), and
#       offer to install what's missing,
#    3. build Sasha in release mode,
#    4. put the program, its icon and a .desktop launcher in "Built Binaries",
#    5. optionally add Sasha to your application menu.
#
#  On immutable systems (Bazzite, Silverblue/Kinoite, Bluefin, Aurora, SteamOS,
#  openSUSE Aeon/Kalpa/MicroOS, Vanilla OS, ...) nothing is installed on the
#  base system: the build runs inside a distrobox/toolbox container instead.
#
#  Options:  --clean      rebuild from scratch
#            --no-gui     terminal prompts only (no kdialog/zenity windows)
#            --yes        answer "yes" to every question (unattended builds)
#            --container  always build inside a container
#            --native     never use a container
#  Env:      QMAKE=/path/to/qt6/qmake  to use a specific Qt 6
#            MOC=/path/to/qt6/moc      if moc isn't found automatically
# ---------------------------------------------------------------------------

set -u

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
BUILDER_DIR="$(dirname "$SCRIPT_PATH")"
OUT_NAME="Built Binaries"
APP_ID="sasha"
APP_NAME="Sasha"
BOX_NAME="sasha-build"
LEGACY_BOX_NAME="tuneful-build"   # reused if it exists from when Sasha was called Tuneful

CLEAN=0
NO_GUI=0
ASSUME_YES=0
FORCE_CONTAINER=0
FORCE_NATIVE=0
INNER=0        # set when this script runs inside the build container
PASS_ARGS=()
for a in "$@"; do
    case "$a" in
        --clean) CLEAN=1; PASS_ARGS+=("$a") ;;
        --no-gui) NO_GUI=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --container) FORCE_CONTAINER=1 ;;
        --native) FORCE_NATIVE=1 ;;
        --inner-container-build) INNER=1; NO_GUI=1; ASSUME_YES=1 ;;
        -h|--help) sed -n '2,26p' "$SCRIPT_PATH"; exit 0 ;;
    esac
done

# ---------------------------------------------------------------- terminal ---
# Double-clicked from Dolphin there is no terminal: reopen in one so the build
# output is visible and sudo can ask for a password.
if [ "$INNER" = 0 ] && [ ! -t 1 ] && [ -z "${SASHA_BUILDER_IN_TERM:-}" ]; then
    export SASHA_BUILDER_IN_TERM=1
    for t in konsole x-terminal-emulator gnome-terminal kgx ptyxis xfce4-terminal xterm; do
        if command -v "$t" >/dev/null 2>&1; then
            case "$t" in
                konsole) exec konsole -p tabtitle="Building Sasha" -e bash "$SCRIPT_PATH" "$@" ;;
                gnome-terminal|kgx|ptyxis) exec "$t" -- bash "$SCRIPT_PATH" "$@" ;;
                *) exec "$t" -e bash "$SCRIPT_PATH" "$@" ;;
            esac
        fi
    done
    # No terminal emulator: carry on with dialogs only.
fi

# ------------------------------------------------------------------- output ---
if [ -t 1 ]; then
    B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else
    B=; G=; Y=; R=; C=; N=
fi
step() { printf '\n%s==> %s%s\n' "$B$C" "$*" "$N"; }
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$R" "$N" "$*"; }

GUI=""
if [ "$NO_GUI" = 0 ] && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    if command -v kdialog >/dev/null 2>&1; then GUI=kdialog
    elif command -v zenity >/dev/null 2>&1; then GUI=zenity
    fi
fi

dlg_info() {  # title, text
    case "$GUI" in
        kdialog) kdialog --title "$1" --msgbox "$2" 2>/dev/null ;;
        zenity)  zenity --info --title "$1" --text "$2" --width 420 2>/dev/null ;;
    esac
}
dlg_error() {
    case "$GUI" in
        kdialog) kdialog --title "$1" --error "$2" 2>/dev/null ;;
        zenity)  zenity --error --title "$1" --text "$2" --width 480 2>/dev/null ;;
    esac
}
dlg_notify() {
    [ "$GUI" = kdialog ] && kdialog --title "Sasha builder" --passivepopup "$1" 4 2>/dev/null &
}
ask() {  # title, question -> 0 = yes
    [ "$ASSUME_YES" = 1 ] && return 0
    case "$GUI" in
        kdialog) kdialog --title "$1" --yesno "$2" 2>/dev/null; return $? ;;
        zenity)  zenity --question --title "$1" --text "$2" --width 420 2>/dev/null; return $? ;;
    esac
    if [ -t 0 ]; then
        local r
        printf '\n%s%s%s [Y/n] ' "$B" "$2" "$N"
        read -r r
        case "$r" in n|N|no|NO) return 1 ;; *) return 0 ;; esac
    fi
    return 1
}

finish() {  # exit code
    if [ "$INNER" = 0 ] && [ -n "${SASHA_BUILDER_IN_TERM:-}" ] && [ -t 0 ]; then
        printf '\nPress Enter to close this window...'
        read -r _
    fi
    exit "$1"
}

fail() {  # message
    bad "$1"
    dlg_error "Sasha build failed" "$1"
    finish 1
}

if [ "$INNER" = 1 ]; then
    printf '%sSasha builder (inside the build container)%s\n' "$B" "$N"
else
    printf '%sSasha builder%s\n' "$B" "$N"
fi

# ---------------------------------------------------------- 1. find source ---
step "Looking for the Sasha source"

is_app_src() {
    [ -f "$1/Cargo.toml" ] && [ -f "$1/cpp/host.cpp" ] && [ -f "$1/src/main.rs" ] && [ -f "$1/qml/main.qml" ] &&
        grep -Eq '^name *= *"sasha"' "$1/Cargo.toml"
}

SRC=""
if is_app_src "$BUILDER_DIR"; then
    SRC="$BUILDER_DIR"
else
    for d in "$BUILDER_DIR"/*/ "$BUILDER_DIR"/*/*/; do
        d="${d%/}"
        if is_app_src "$d"; then SRC="$d"; break; fi
    done
fi
[ -n "$SRC" ] || fail "Couldn't find the Sasha source next to this script.

Put \"Build Sasha.sh\" inside the extracted Sasha folder (the one containing Cargo.toml, src/, cpp/ and qml/) and run it again."

APP_VER="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$SRC/Cargo.toml" | head -1)"
CRATE="$(sed -n 's/^name *= *"\(.*\)"/\1/p' "$SRC/Cargo.toml" | head -1)"
ok "Found $APP_NAME ${APP_VER:-?} in $SRC"
OUT="$BUILDER_DIR/$OUT_NAME"

# ------------------------------------------------------------- system info ---
OS_IDS=""
OS_NAME=""
OS_VERSION_ID=""
if [ -r /etc/os-release ]; then
    # Read in a subshell so os-release variables (VERSION, NAME, ...) don't leak.
    OS_IDS="$(. /etc/os-release; echo " ${ID:-} ${ID_LIKE:-} ")"
    OS_NAME="$(. /etc/os-release; echo "${PRETTY_NAME:-}")"
    OS_VERSION_ID="$(. /etc/os-release; echo "${VERSION_ID:-}")"
fi

DISTRO="unknown"
case "$OS_IDS" in
    *" arch "*|*" manjaro "*|*" endeavouros "*|*" steamos "*|*" cachyos "*) DISTRO=arch ;;
    *" fedora "*|*" rhel "*) DISTRO=fedora ;;
    *" opensuse"*|*" suse "*|*" sles "*) DISTRO=suse ;;
    *" debian "*|*" ubuntu "*|*" neon "*) DISTRO=debian ;;
esac

in_container() {
    [ -e /run/.containerenv ] || [ -e /.dockerenv ] || [ -n "${container:-}" ] ||
        [ -n "${DISTROBOX_ENTER_PATH:-}" ] || [ -n "${TOOLBOX_PATH:-}" ]
}

# Returns 0 and sets IMMUTABLE_KIND when the base system can't take packages
# through the normal package manager.
IMMUTABLE_KIND=""
detect_immutable() {
    in_container && return 1
    if [ -e /run/ostree-booted ]; then
        IMMUTABLE_KIND="ostree (rpm-ostree / bootc)"; return 0
    fi
    case "$OS_IDS" in
        *" steamos "*|*" holo "*) IMMUTABLE_KIND="SteamOS"; return 0 ;;
        *" bazzite "*|*" bluefin "*|*" aurora "*|*" kinoite "*|*" silverblue "*|*" ublue"*)
            IMMUTABLE_KIND="Universal Blue / Fedora Atomic"; return 0 ;;
        *" vanilla"*) IMMUTABLE_KIND="Vanilla OS"; return 0 ;;
        *" endless"*) IMMUTABLE_KIND="Endless OS"; return 0 ;;
        *" blendos "*) IMMUTABLE_KIND="blendOS"; return 0 ;;
        *" nixos "*) IMMUTABLE_KIND="NixOS"; return 0 ;;
        *" aeon "*|*" kalpa "*|*" opensuse-microos "*|*" opensuse-leap-micro "*)
            IMMUTABLE_KIND="openSUSE transactional (Aeon/Kalpa/MicroOS)"; return 0 ;;
    esac
    if command -v transactional-update >/dev/null 2>&1; then
        IMMUTABLE_KIND="openSUSE transactional (Aeon/Kalpa/MicroOS)"; return 0
    fi
    if command -v abroot >/dev/null 2>&1; then
        IMMUTABLE_KIND="ABRoot"; return 0
    fi
    if command -v findmnt >/dev/null 2>&1 && findmnt -no OPTIONS /usr 2>/dev/null | tr ',' '\n' | grep -qx ro; then
        IMMUTABLE_KIND="read-only /usr"; return 0
    fi
    return 1
}

IMMUTABLE=0
if [ "$INNER" = 0 ] && detect_immutable; then
    IMMUTABLE=1
fi

# ------------------------------------------------------- 2. dependencies ---
pkgs_for() {  # what -> package list for this distro
    case "$DISTRO:$1" in
        arch:rust) echo "rust" ;;
        arch:cxx) echo "base-devel" ;;
        arch:qt) echo "qt6-base qt6-declarative qt6-multimedia qt6-multimedia-ffmpeg pkgconf" ;;
        arch:moc) echo "qt6-base" ;;
        arch:qml) echo "qt6-declarative" ;;
        arch:blur) echo "kwindowsystem" ;;
        fedora:rust) echo "cargo rust" ;;
        fedora:cxx) echo "gcc-c++" ;;
        fedora:qt) echo "qt6-qtbase-devel qt6-qtdeclarative-devel qt6-qtmultimedia-devel pkgconf-pkg-config" ;;
        fedora:moc) echo "qt6-qtbase-devel" ;;
        fedora:qml) echo "qt6-qtdeclarative" ;;
        fedora:blur) echo "kf6-kwindowsystem-devel" ;;
        suse:rust) echo "cargo rust" ;;
        suse:cxx) echo "gcc-c++" ;;
        suse:qt) echo "qt6-base-devel qt6-declarative-devel qt6-multimedia-devel qt6-declarative-imports pkgconf" ;;
        suse:moc) echo "qt6-base-common-devel" ;;
        suse:qml) echo "qt6-declarative-imports" ;;
        suse:blur) echo "kf6-kwindowsystem-devel" ;;
        debian:rust) echo "cargo rustc" ;;
        debian:cxx) echo "g++" ;;
        debian:qt) echo "qt6-base-dev qt6-base-dev-tools qt6-declarative-dev qt6-multimedia-dev pkg-config" ;;
        debian:moc) echo "qt6-base-dev-tools" ;;
        debian:qml) echo "qml6-module-qtquick qml6-module-qtquick-controls qml6-module-qtquick-templates qml6-module-qtquick-window qml6-module-qtqml-workerscript qml6-module-qtqml-models" ;;
        debian:blur) echo "libkf6windowsystem-dev" ;;
    esac
}

install_cmd() {
    case "$DISTRO" in
        arch) echo "pacman -Syu --needed --noconfirm $*" ;;
        fedora) echo "dnf install -y $*" ;;
        suse) echo "zypper --non-interactive install $*" ;;
        debian) echo "apt-get install -y $*" ;;
    esac
}

CXX_BIN="${CXX:-}"
find_cxx() {
    [ -n "$CXX_BIN" ] && command -v "$CXX_BIN" >/dev/null 2>&1 && return 0
    for c in c++ g++ clang++; do
        if command -v "$c" >/dev/null 2>&1; then CXX_BIN="$c"; return 0; fi
    done
    return 1
}

QMAKE_BIN=""
find_qmake() {
    QMAKE_BIN=""
    local v
    if [ -n "${QMAKE:-}" ]; then
        v="$("$QMAKE" -query QT_VERSION 2>/dev/null)"
        case "$v" in 6*) QMAKE_BIN="$QMAKE"; return 0 ;; esac
        return 1
    fi
    for q in qmake6 qmake-qt6 qmake /usr/lib64/qt6/bin/qmake /usr/lib/qt6/bin/qmake /usr/lib/x86_64-linux-gnu/qt6/bin/qmake /usr/lib/aarch64-linux-gnu/qt6/bin/qmake; do
        if command -v "$q" >/dev/null 2>&1 || [ -x "$q" ]; then
            v="$("$q" -query QT_VERSION 2>/dev/null)"
            case "$v" in 6*) QMAKE_BIN="$q"; return 0 ;; esac
        fi
    done
    return 1
}

QT_HOW=""
QT_VER=""
find_qt() {
    QT_HOW=""; QT_VER=""
    if [ -z "${QMAKE:-}" ] && command -v pkg-config >/dev/null 2>&1 &&
        pkg-config --exists Qt6Widgets Qt6Quick Qt6Qml Qt6Multimedia Qt6DBus 2>/dev/null; then
        QT_VER="$(pkg-config --modversion Qt6Quick)"; QT_HOW="pkg-config"; return 0
    fi
    find_qmake || return 1
    local h
    h="$("$QMAKE_BIN" -query QT_INSTALL_HEADERS 2>/dev/null)"
    if [ -f "$h/QtQuick/QQuickWindow" ] && [ -f "$h/QtMultimedia/QMediaPlayer" ] && [ -f "$h/QtWidgets/QApplication" ] && [ -f "$h/QtDBus/QDBusConnection" ]; then
        QT_VER="$("$QMAKE_BIN" -query QT_VERSION 2>/dev/null)"; QT_HOW="$QMAKE_BIN"; return 0
    fi
    return 1
}

moc_is_qt6() { "$1" -v 2>&1 | grep -q ' 6\.'; }

MOC_BIN=""
find_moc() {
    MOC_BIN=""
    if [ -n "${MOC:-}" ]; then
        moc_is_qt6 "$MOC" && { MOC_BIN="$MOC"; return 0; }
        return 1
    fi
    local cands=() d var
    find_qmake >/dev/null 2>&1
    for tool in ${QMAKE_BIN:+"$QMAKE_BIN"} qtpaths6 qtpaths-qt6 qtpaths; do
        command -v "$tool" >/dev/null 2>&1 || [ -x "$tool" ] || continue
        for var in QT_HOST_LIBEXECS QT_INSTALL_LIBEXECS QT_HOST_BINS QT_INSTALL_BINS; do
            case "$tool" in
                *qtpaths*) d="$("$tool" --query "$var" 2>/dev/null)" ;;
                *) d="$("$tool" -query "$var" 2>/dev/null)" ;;
            esac
            [ -n "$d" ] && cands+=("$d/moc")
        done
    done
    if command -v pkg-config >/dev/null 2>&1; then
        for var in libexecdir host_bins bindir; do
            d="$(pkg-config --variable="$var" Qt6Core 2>/dev/null)"
            [ -n "$d" ] && cands+=("$d/moc")
        done
    fi
    cands+=(/usr/lib/qt6/libexec/moc /usr/lib/qt6/moc /usr/lib64/qt6/libexec/moc /usr/libexec/qt6/moc
            /usr/lib/x86_64-linux-gnu/qt6/libexec/moc /usr/lib/aarch64-linux-gnu/qt6/libexec/moc)
    for c in moc-qt6 moc6 moc; do
        command -v "$c" >/dev/null 2>&1 && cands+=("$(command -v "$c")")
    done
    for c in "${cands[@]}"; do
        if [ -x "$c" ] && moc_is_qt6 "$c"; then MOC_BIN="$c"; return 0; fi
    done
    return 1
}

# The Qt Quick modules the window imports, needed when the program runs.
qml_ok() {
    local dirs=() d
    find_qmake >/dev/null 2>&1 && d="$("$QMAKE_BIN" -query QT_INSTALL_QML 2>/dev/null)" && [ -n "$d" ] && dirs+=("$d")
    dirs+=(/usr/lib/qt6/qml /usr/lib64/qt6/qml /usr/lib/x86_64-linux-gnu/qt6/qml /usr/lib/aarch64-linux-gnu/qt6/qml)
    for d in "${dirs[@]}"; do
        if [ -f "$d/QtQuick/Controls/Basic/qmldir" ] && [ -f "$d/QtQuick/Window/qmldir" ]; then
            return 0
        fi
    done
    return 1
}

blur_ok() {
    { command -v pkg-config >/dev/null 2>&1 && pkg-config --exists KF6WindowSystem 2>/dev/null; } ||
        [ -f /usr/include/KF6/KWindowSystem/KWindowEffects ]
}

[ -d "$HOME/.cargo/bin" ] && PATH="$HOME/.cargo/bin:$PATH"

check_all() {
    MISSING=()
    MISSING_NAMES=()
    if command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
        ok "Rust: $(rustc --version 2>/dev/null)"
    else
        bad "Rust (cargo/rustc) not found"; MISSING+=(rust); MISSING_NAMES+=("Rust")
    fi
    if find_cxx; then
        ok "C++ compiler: $CXX_BIN"
    else
        bad "C++ compiler not found"; MISSING+=(cxx); MISSING_NAMES+=("C++ compiler")
    fi
    if find_qt; then
        ok "Qt $QT_VER (via $QT_HOW)"
        if find_moc; then
            ok "moc: $MOC_BIN"
        else
            bad "Qt 6 moc not found"; MISSING+=(moc); MISSING_NAMES+=("Qt 6 moc")
        fi
    else
        bad "Qt 6 development files (Quick, Multimedia) not found"; MISSING+=(qt); MISSING_NAMES+=("Qt 6 Quick and Multimedia development files")
    fi
    if qml_ok; then
        ok "Qt Quick modules"
    else
        bad "Qt Quick modules (QtQuick.Controls, QtQuick.Window) not found"; MISSING+=(qml); MISSING_NAMES+=("Qt Quick modules")
    fi
}

run_as_root() {  # command...
    if [ "$(id -u)" = 0 ]; then
        "$@"
    elif in_container && command -v sudo >/dev/null 2>&1; then
        # distrobox / toolbox give passwordless sudo
        sudo -n "$@" 2>/dev/null || sudo "$@"
    elif [ -t 0 ] && command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
    else
        return 127
    fi
}

# ----------------------------------------------------- container helpers ---
BOX_TOOL=""
pick_box_tool() {
    if command -v distrobox >/dev/null 2>&1 &&
        { command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1 || command -v lilipod >/dev/null 2>&1; }; then
        BOX_TOOL=distrobox; return 0
    fi
    if command -v toolbox >/dev/null 2>&1; then
        BOX_TOOL=toolbox; return 0
    fi
    return 1
}

# Pick a container image as close to the host as possible, so the program can
# usually run directly on the host afterwards.
box_image() {
    case "$OS_IDS" in
        *" fedora "*|*" bazzite "*|*" bluefin "*|*" aurora "*|*" kinoite "*|*" silverblue "*)
            case "$OS_VERSION_ID" in
                [0-9]*) echo "registry.fedoraproject.org/fedora-toolbox:${OS_VERSION_ID%%.*}" ;;
                *) echo "registry.fedoraproject.org/fedora-toolbox:latest" ;;
            esac ;;
        *" steamos "*|*" arch "*) echo "docker.io/library/archlinux:latest" ;;
        *" opensuse"*|*" suse "*) echo "registry.opensuse.org/opensuse/distrobox:latest" ;;
        *" ubuntu "*|*" debian "*) echo "docker.io/library/ubuntu:24.04" ;;
        *) echo "registry.fedoraproject.org/fedora-toolbox:latest" ;;
    esac
}

box_exists() {
    case "$BOX_TOOL" in
        distrobox) distrobox list 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -F'|' '{gsub(/ /,"",$2); print $2}' | grep -qx "$BOX_NAME" ;;
        toolbox) toolbox list -c 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$BOX_NAME" ;;
    esac
}

box_create() {
    local img; img="$(box_image)"
    step "Creating build container \"$BOX_NAME\" from $img"
    case "$BOX_TOOL" in
        distrobox) distrobox create --yes --name "$BOX_NAME" --image "$img" ;;
        toolbox) toolbox create -y -c "$BOX_NAME" --image "$img" ;;
    esac
}

box_run() {  # command...
    case "$BOX_TOOL" in
        distrobox) distrobox enter --name "$BOX_NAME" -- "$@" ;;
        toolbox) toolbox run -c "$BOX_NAME" "$@" ;;
    esac
}

# ------------------------------------------------------- output packaging ---
write_icon() {
    # sasha.svg is the default (C); the app can switch it to A or B from
    # Settings, using the copies in icons/.
    install -m 644 "$SRC/assets/sasha.svg" "$OUT/$APP_ID.svg"
    mkdir -p "$OUT/icons"
    install -m 644 "$SRC"/assets/sasha-a.svg "$SRC"/assets/sasha-b.svg "$SRC"/assets/sasha-c.svg "$OUT/icons/"
}

# .desktop Exec quoting: escape \ " ` $ for the exec layer, then \ again for
# the desktop-entry string layer.
exec_quote() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//\`/\\\`}"; s="${s//\$/\\\$}"
    s="${s//\\/\\\\}"
    printf '"%s"' "$s"
}
desktop_str() { local s="$1"; printf '%s' "${s//\\/\\\\}"; }

# How the launcher starts Sasha: directly, or inside the build container.
RUN_MODE="native"
exec_line() {
    local bin="$OUT/$APP_ID"
    if [ "$RUN_MODE" = container ]; then
        case "$BOX_TOOL" in
            distrobox) printf '%s enter --name %s -- %s' "$(exec_quote "$(command -v distrobox)")" "$BOX_NAME" "$(exec_quote "$bin")" ;;
            toolbox) printf '%s run -c %s %s' "$(exec_quote "$(command -v toolbox)")" "$BOX_NAME" "$(exec_quote "$bin")" ;;
        esac
    else
        exec_quote "$bin"
    fi
}

write_desktop() {  # file, icon value
    mkdir -p "$(dirname "$1")"
    cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Version=1.5
Name=$APP_NAME
GenericName=Music Player
Comment=Play your music library by album, artist or genre
Exec=$(exec_line) %F
Path=$(desktop_str "$OUT")
Icon=$(desktop_str "$2")
Terminal=false
Categories=AudioVideo;Audio;Player;Qt;
Keywords=music;player;audio;mp3;flac;opus;album;shuffle;
StartupNotify=true
StartupWMClass=sasha
MimeType=audio/mpeg;audio/x-mp3;audio/mp2;audio/flac;audio/x-flac;audio/ogg;audio/x-vorbis+ogg;audio/x-flac+ogg;audio/opus;audio/x-opus+ogg;audio/mp4;audio/x-m4a;audio/x-m4b;audio/aac;audio/x-aac;audio/wav;audio/x-wav;audio/vnd.wave;audio/x-aiff;audio/x-wavpack;audio/x-ape;audio/x-ms-wma;audio/x-musepack;audio/x-dsf;audio/x-mpegurl;audio/mpegurl;
EOF
    chmod 755 "$1"
}

# Can the built program start on this system without the container?
native_runnable() {
    command -v ldd >/dev/null 2>&1 || return 1
    local out
    out="$(ldd "$OUT/$APP_ID" 2>&1)" || return 1
    if printf '%s\n' "$out" | grep -q "not found"; then
        printf '%s\n' "$out" | grep "not found" | sed 's/^/      /' | head -5
        return 1
    fi
    qml_ok || { warn "the Qt Quick modules aren't installed on the host"; return 1; }
    return 0
}

# ===================================================== container route ======
build_in_container() {
    step "Immutable system detected (${IMMUTABLE_KIND:-container requested})"
    printf '  The base system stays untouched: Sasha will be built inside a\n'
    printf '  %s container named "%s".\n' "${BOX_TOOL:-distrobox}" "$BOX_NAME"

    if ! pick_box_tool; then
        fail "This is an immutable system (${IMMUTABLE_KIND:-}), so build tools can't be installed on it directly, and neither distrobox nor toolbox was found.

Install distrobox (e.g. from your distro's app store or https://distrobox.it) and run this again."
    fi
    ok "Using $BOX_TOOL"

    # Reuse the container from the Tuneful days instead of downloading another.
    local want="$BOX_NAME"
    BOX_NAME="$LEGACY_BOX_NAME"
    if box_exists; then
        ok "Reusing the existing \"$LEGACY_BOX_NAME\" container"
    else
        BOX_NAME="$want"
    fi

    if box_exists; then
        ok "Container \"$BOX_NAME\" already exists"
    else
        ask "Sasha builder" "Your system is immutable (${IMMUTABLE_KIND:-}), so packages can't be installed on it directly.

Sasha can be built inside a $BOX_TOOL container instead:
  name:  $BOX_NAME
  image: $(box_image)

This downloads the container image once (a few hundred MB). Continue?" ||
            fail "Build cancelled. Nothing was changed."
        box_create || fail "Creating the \"$BOX_NAME\" container failed. See the terminal output for details."
        ok "Container created"
    fi

    step "Entering the container (the first start can take a few minutes)"
    local inner_args=(--inner-container-build ${PASS_ARGS[@]+"${PASS_ARGS[@]}"})
    box_run bash "$SCRIPT_PATH" "${inner_args[@]}"
    local rc=$?
    [ "$rc" -eq 0 ] && [ -x "$OUT/$APP_ID" ] ||
        fail "The build inside the \"$BOX_NAME\" container failed. The log is in:
  $OUT/build.log"

    step "Checking whether Sasha runs directly on this system"
    if [ "$FORCE_CONTAINER" = 0 ] && native_runnable; then
        RUN_MODE="native"
        ok "Yes: the launcher will start it directly"
    else
        RUN_MODE="container"
        warn "This system lacks a matching Qt 6, so the launcher will start Sasha inside \"$BOX_NAME\""
    fi
}

# ======================================================== native route ======
build_native() {
    step "Checking build tools"
    check_all

    if [ "${#MISSING[@]}" -gt 0 ]; then
        PKGS=""
        for m in "${MISSING[@]}"; do PKGS="$PKGS $(pkgs_for "$m")"; done
        PKGS="$(echo $PKGS)"
        NAMES="$(printf '%s, ' "${MISSING_NAMES[@]}")"; NAMES="${NAMES%, }"

        if [ -z "$PKGS" ]; then
            fail "Missing: $NAMES.

Your distribution wasn't recognised, so please install Rust, a C++ compiler and the Qt 6 base, Declarative (Qt Quick) and Multimedia development packages yourself, then run this again."
        fi

        CMD="$(install_cmd $PKGS)"
        if ask "Sasha builder" "Missing: $NAMES.

Install them now with:
  $CMD

(You may be asked for your password.)"; then
            step "Installing $PKGS"
            # shellcheck disable=SC2086
            run_as_root $CMD || fail "Installing packages failed. Command was:
  sudo $CMD"
            hash -r
            step "Re-checking build tools"
            check_all
            [ "${#MISSING[@]}" -eq 0 ] || fail "Still missing after install: $(printf '%s, ' "${MISSING_NAMES[@]}" | sed 's/, $//')"
        else
            fail "Can't build without: $NAMES.

Install them with:
  sudo $CMD"
        fi
    fi

    # Optional: KF6 WindowSystem gives the header KWin's frosted-glass blur.
    if blur_ok; then
        ok "KF6 WindowSystem (frosted-glass header)"
    else
        warn "KF6 WindowSystem not found: the header will be solid instead of frosted glass"
        BLUR_PKGS="$(pkgs_for blur)"
        if [ -n "$BLUR_PKGS" ]; then
            BLUR_CMD="$(install_cmd $BLUR_PKGS)"
            if ask "Sasha builder" "Optional: install KF6 WindowSystem so Sasha's header gets KDE's frosted-glass blur?

  $BLUR_CMD

Sasha works fine without it."; then
                # shellcheck disable=SC2086
                if run_as_root $BLUR_CMD; then
                    ok "Installed $BLUR_PKGS"
                else
                    warn "Couldn't install $BLUR_PKGS; building without the blur"
                fi
            fi
        fi
    fi

    # Cargo older than 1.78 can't read a version-4 Cargo.lock. Sasha has no
    # crate dependencies, so the lock file can simply be regenerated.
    CARGO_MINOR="$(cargo --version | sed -n 's/^cargo 1\.\([0-9]*\).*/\1/p')"
    if [ -n "$CARGO_MINOR" ] && [ "$CARGO_MINOR" -lt 78 ] && grep -q '^version = 4' "$SRC/Cargo.lock" 2>/dev/null; then
        warn "Older cargo detected; regenerating Cargo.lock"
        rm -f "$SRC/Cargo.lock"
    fi
    if [ -n "$CARGO_MINOR" ] && [ "$CARGO_MINOR" -lt 70 ]; then
        warn "Rust 1.$CARGO_MINOR is quite old; if the build fails, install a newer Rust from https://rustup.rs"
    fi

    step "Building $APP_NAME (release)"
    mkdir -p "$OUT" || fail "Couldn't create \"$OUT\""
    LOG="$OUT/build.log"
    [ "$INNER" = 0 ] && dlg_notify "Building $APP_NAME ${APP_VER}…"

    if [ "$CLEAN" = 1 ]; then
        (cd "$SRC" && cargo clean) >/dev/null 2>&1
    fi

    [ -n "$MOC_BIN" ] && export MOC="$MOC_BIN"
    [ -n "$QMAKE_BIN" ] && [ -z "${QMAKE:-}" ] && [ "$QT_HOW" != "pkg-config" ] && export QMAKE="$QMAKE_BIN"

    START=$(date +%s)
    (cd "$SRC" && cargo build --release --color always 2>&1) | tee "$LOG"
    RC=${PIPESTATUS[0]}
    # keep the log readable in a text editor
    sed -i 's/\x1b\[[0-9;]*[mK]//g' "$LOG" 2>/dev/null

    if [ "$RC" -ne 0 ] || [ ! -x "$SRC/target/release/$CRATE" ]; then
        TAIL="$(grep -E 'error|Error|fatal' "$LOG" | head -8)"
        fail "The build failed. The full log is in:
  $LOG

${TAIL}"
    fi
    ok "Built in $(( $(date +%s) - START ))s"

    install -m 755 "$SRC/target/release/$CRATE" "$OUT/$APP_ID" || fail "Couldn't copy the program into \"$OUT\""
    {
        echo "Rust:    $(rustc --version 2>/dev/null)"
        echo "Qt:      $QT_VER (via $QT_HOW)"
        if blur_ok; then echo "Blur:    KF6 WindowSystem"; else echo "Blur:    not built in (KF6 WindowSystem missing)"; fi
        echo "Built on: ${OS_NAME:-unknown}"
    } > "$OUT/.toolchain"
}

# ==================================================================== main ===
if [ "$INNER" = 1 ]; then
    # Running inside the container: build only; the host side writes launchers.
    build_native
    exit 0
fi

USE_CONTAINER=0
if [ "$FORCE_CONTAINER" = 1 ]; then
    USE_CONTAINER=1
elif [ "$IMMUTABLE" = 1 ] && [ "$FORCE_NATIVE" = 0 ]; then
    # If someone has already layered every build dependency onto the image,
    # just build natively.
    step "Checking build tools on the host"
    check_all >/dev/null 2>&1
    if [ "${#MISSING[@]}" -eq 0 ]; then
        ok "Everything needed is already installed on the host"
    else
        warn "Immutable system detected: $IMMUTABLE_KIND"
        USE_CONTAINER=1
    fi
fi

if [ "$USE_CONTAINER" = 1 ]; then
    pick_box_tool
    build_in_container
else
    build_native
fi

# --------------------------------------------------------------- package ---
step "Writing \"$OUT_NAME\""
ok "$APP_ID"
write_icon && ok "$APP_ID.svg and icons/"
write_desktop "$OUT/Sasha.desktop" "$OUT/$APP_ID.svg" && ok "Sasha.desktop"
# Clean up launchers left by Tuneful-era builds in the same folder.
rm -f "$OUT/Tuneful.desktop" "$OUT/tuneful" "$OUT/tuneful.svg"

{
    echo "$APP_NAME $APP_VER"
    echo "Built:   $(date '+%Y-%m-%d %H:%M')"
    echo "Source:  $SRC"
    cat "$OUT/.toolchain" 2>/dev/null
    echo "Host:    ${OS_NAME:-unknown}${IMMUTABLE_KIND:+ (immutable: $IMMUTABLE_KIND)}"
    if [ "$USE_CONTAINER" = 1 ]; then
        echo "Built in container: $BOX_NAME ($BOX_TOOL, $(box_image))"
        echo "Launch mode: $RUN_MODE"
        [ "$RUN_MODE" = container ] && echo "Note: the launcher needs the \"$BOX_NAME\" container; don't remove it."
    fi
    echo
    echo "Launch Sasha.desktop (or ./$APP_ID) from this folder."
    echo "If you move this folder, run the builder again so the launcher points at the new location."
} > "$OUT/BUILD-INFO.txt"
rm -f "$OUT/.toolchain"
ok "BUILD-INFO.txt"

# ------------------------------------------------------------ app menu ---
MENU_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/applications/$APP_ID.desktop"
ICON_FILE="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/$APP_ID.svg"
MENU_MSG=""
OLD_MENU="${XDG_DATA_HOME:-$HOME/.local/share}/applications/tuneful.desktop"
OLD_ICON="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps/tuneful.svg"
if [ -f "$OLD_MENU" ] && grep -q "^Name=Tuneful" "$OLD_MENU"; then
    # Tuneful was renamed: replace its menu entry with Sasha's.
    rm -f "$OLD_MENU" "$OLD_ICON"
    install -Dm 644 "$OUT/$APP_ID.svg" "$ICON_FILE"
    write_desktop "$MENU_FILE" "$OUT/$APP_ID.svg"
    ok "Replaced the old Tuneful menu entry"
fi
if [ -f "$MENU_FILE" ]; then
    # Already in the menu from an earlier build: keep it pointing at this build.
    write_desktop "$MENU_FILE" "$OUT/$APP_ID.svg"
    install -Dm 644 "$OUT/$APP_ID.svg" "$ICON_FILE"
    MENU_MSG="The application-menu entry was updated."
    ok "Updated the application-menu entry"
elif ask "Sasha builder" "$APP_NAME was built successfully.

Add it to your application menu too?"; then
    install -Dm 644 "$OUT/$APP_ID.svg" "$ICON_FILE"
    write_desktop "$MENU_FILE" "$OUT/$APP_ID.svg"
    MENU_MSG="It was added to your application menu."
    ok "Added to the application menu"
fi
if [ -n "$MENU_MSG" ]; then
    command -v kbuildsycoca6 >/dev/null 2>&1 && kbuildsycoca6 >/dev/null 2>&1
    command -v update-desktop-database >/dev/null 2>&1 &&
        update-desktop-database "$(dirname "$MENU_FILE")" >/dev/null 2>&1
fi

step "Done"
printf '  %s %s is in:\n    %s\n' "$APP_NAME" "$APP_VER" "$OUT"
EXTRA=""
[ "$RUN_MODE" = container ] && EXTRA="
It runs inside the \"$BOX_NAME\" container; keep that container installed."
dlg_info "Sasha is ready" "$APP_NAME ${APP_VER} was built into:
$OUT

Double-click Sasha.desktop there to start it.${MENU_MSG:+
$MENU_MSG}${EXTRA}"
finish 0
