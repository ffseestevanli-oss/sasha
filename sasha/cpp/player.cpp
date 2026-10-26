#include "player.h"

#include <QAudioOutput>
#include <QDBusConnection>
#include <QDirIterator>
#include <QDBusMessage>
#include <QDesktopServices>
#include <QFileInfo>
#include <QSaveFile>
#include <QDir>
#include <QEvent>
#include <QFile>
#include <QFileDialog>
#include <QFileSystemWatcher>
#include <QIcon>
#include <QProcess>
#include <QGuiApplication>
#include <QLocale>
#include <QMap>
#include <QMediaPlayer>
#include <QPalette>
#include <QQuickWindow>
#include <QRectF>
#include <QRegion>
#include <QSettings>
#include <QStandardPaths>
#include <QStringList>
#include <QThread>
#include <QTimer>
#include <QUrl>

#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
#include <QAudioBuffer>
#include <QAudioBufferOutput>
#include <QAudioFormat>
#endif

#ifdef TN_HAVE_KWINDOWSYSTEM
#include <KWindowEffects>
#include <KWindowSystem>
#endif

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <numeric>

// The Rust side (src/main.rs).
extern "C" {
uint32_t tn_scan(const char *root, const char *cache_dir);
uint32_t tn_scan_progress();
uint32_t tn_scan_total();
const uint8_t *tn_library_blob(size_t *len);
int64_t tn_queue_set(const uint32_t *tracks, size_t n, int64_t start, bool shuffle);
int64_t tn_queue_next(bool user);
int64_t tn_queue_prev();
int64_t tn_queue_current();
int64_t tn_queue_peek();
uint32_t tn_queue_len();
bool tn_queue_shuffled();
void tn_queue_set_shuffle(bool on);
void tn_queue_set_repeat(uint32_t mode);
void tn_spectrum(const float *samples, size_t n, uint32_t sample_rate, float *out, size_t bands);
int64_t tn_queue_insert_next(const uint32_t *tracks, size_t n);
uint8_t *tn_m3u_parse(const uint8_t *text, size_t len, const char *base_dir, size_t *out_len);
uint8_t *tn_read_track(const char *path, const char *cache_dir, size_t *out_len);
void tn_free_buffer(uint8_t *ptr, size_t len);
}

namespace {

constexpr int kMaxBands = 192;

QString formatDuration(qint64 ms)
{
    if (ms <= 0)
        return QStringLiteral("0:00");
    const qint64 s = ms / 1000;
    const qint64 h = s / 3600, m = (s % 3600) / 60, sec = s % 60;
    if (h > 0)
        return QStringLiteral("%1:%2:%3").arg(h).arg(m, 2, 10, QLatin1Char('0')).arg(sec, 2, 10, QLatin1Char('0'));
    return QStringLiteral("%1:%2").arg(m).arg(sec, 2, 10, QLatin1Char('0'));
}

QString formatLong(qint64 ms)
{
    const qint64 minutes = ms / 60000;
    if (minutes >= 24 * 60)
        return QObject::tr("%1 days %2 h").arg(minutes / (24 * 60)).arg((minutes / 60) % 24);
    if (minutes >= 60)
        return QObject::tr("%1 h %2 min").arg(minutes / 60).arg(minutes % 60);
    return formatDuration(ms);
}

QString plural(qint64 n, const QString &one, const QString &many)
{
    return (n == 1 ? one : many).arg(QLocale().toString(n));
}

// A "T" record from the Rust side (see blob() in src/library.rs).
TrackInfo parseTrackRecord(const QList<QByteArray> &f)
{
    auto str = [&f](int i) { return i < f.size() ? QString::fromUtf8(f[i]) : QString(); };
    auto num = [&f](int i) { return i < f.size() ? f[i].toLongLong() : 0LL; };
    TrackInfo t;
    t.path = str(1);
    t.title = str(2);
    t.artist = str(3);
    t.album = str(4);
    t.albumArtist = str(5);
    t.genre = str(6);
    t.year = str(7);
    t.track = int(num(8));
    t.disc = int(num(9));
    t.durationMs = num(10);
    t.codec = str(11);
    t.sampleRate = int(num(12));
    t.bits = int(num(13));
    t.bitrate = int(num(14));
    t.channels = int(num(15));
    t.size = num(16);
    t.albumIndex = int(num(17));
    t.cover = str(18);
    return t;
}

QString coverUrlFor(const QString &path)
{
    return path.isEmpty() ? QString() : QUrl::fromLocalFile(path).toString();
}

struct Group {
    QString name;
    QVector<int> albums;
    QVariantList tracks;
};

QVariantList groupsToList(QMap<QString, Group> &groups, const std::vector<AlbumInfo> &albums)
{
    QVariantList out;
    for (auto it = groups.begin(); it != groups.end(); ++it) {
        Group &g = it.value();
        std::sort(g.albums.begin(), g.albums.end(), [&albums](int a, int b) {
            const AlbumInfo &x = albums[size_t(a)];
            const AlbumInfo &y = albums[size_t(b)];
            if (x.year != y.year)
                return x.year < y.year;
            return a < b;
        });
        QVariantList albumList;
        for (int a : g.albums)
            albumList.append(a);
        QVariantMap m;
        m.insert(QStringLiteral("name"), g.name);
        m.insert(QStringLiteral("count"), int(g.tracks.size()));
        m.insert(QStringLiteral("albums"), albumList);
        m.insert(QStringLiteral("tracks"), g.tracks);
        m.insert(QStringLiteral("search"), g.name.toLower());
        out.append(m);
    }
    return out;
}

void addToGroup(QMap<QString, Group> &groups, const QString &name, int album, const QVariantList &tracks)
{
    Group &g = groups[name.toLower()];
    if (g.name.isEmpty())
        g.name = name;
    if (album >= 0 && !g.albums.contains(album))
        g.albums.append(album);
    g.tracks.append(tracks);
}

} // namespace

Player::Player(QObject *parent)
    : QObject(parent)
{
    m_player = new QMediaPlayer(this);
    m_audio = new QAudioOutput(this);
    m_player->setAudioOutput(m_audio);

#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
    m_bufferOutput = new QAudioBufferOutput(this);
    m_player->setAudioBufferOutput(m_bufferOutput);
    connect(m_bufferOutput, &QAudioBufferOutput::audioBufferReceived, this, &Player::onAudioBuffer);
#endif

    connect(m_player, &QMediaPlayer::positionChanged, this, &Player::positionChanged);
    connect(m_player, &QMediaPlayer::durationChanged, this, &Player::durationChanged);
    connect(m_player, &QMediaPlayer::playbackStateChanged, this, &Player::playbackStateChanged);
    connect(m_player, &QMediaPlayer::mediaStatusChanged, this, [this](QMediaPlayer::MediaStatus status) {
        if (status == QMediaPlayer::EndOfMedia) {
            m_failStreak = 0;
            advance(false);
        } else if (status == QMediaPlayer::BufferedMedia) {
            m_failStreak = 0;
        }
        if ((status == QMediaPlayer::LoadedMedia || status == QMediaPlayer::BufferedMedia) && m_pendingSeek >= 0) {
            const qint64 to = m_pendingSeek;
            m_pendingSeek = -1;
            m_player->setPosition(to);
        }
    });

    // Remember the song and position: every 10 s while playing, and on quit.
    m_resumeTimer = new QTimer(this);
    m_resumeTimer->setInterval(10000);
    connect(m_resumeTimer, &QTimer::timeout, this, [this] {
        if (m_player->playbackState() == QMediaPlayer::PlayingState)
            saveResumeState();
    });
    m_resumeTimer->start();
    connect(qApp, &QCoreApplication::aboutToQuit, this, [this] { saveResumeState(); });
    connect(m_player, &QMediaPlayer::errorOccurred, this, [this](QMediaPlayer::Error error, const QString &text) {
        if (error == QMediaPlayer::NoError)
            return;
        QString name;
        if (m_current >= 0 && m_current < qint64(m_tracks.size()))
            name = m_tracks[size_t(m_current)].title;
        setMessage(tr("Couldn't play \"%1\": %2").arg(name, text));
        if (++m_failStreak <= 5)
            QTimer::singleShot(400, this, [this] { advance(true); });
        else
            m_player->stop();
    });

    m_scanTimer = new QTimer(this);
    m_scanTimer->setInterval(150);
    connect(m_scanTimer, &QTimer::timeout, this, &Player::scanProgressChanged);

    m_messageTimer = new QTimer(this);
    m_messageTimer->setSingleShot(true);
    m_messageTimer->setInterval(7000);
    connect(m_messageTimer, &QTimer::timeout, this, [this] { setMessage(QString()); });

    m_bands.assign(size_t(m_bandCount), 0.f);
    for (int i = 0; i < m_bandCount; ++i)
        m_spectrumList.append(0.0);
    m_spectrumTimer = new QTimer(this);
    m_spectrumTimer->setInterval(33);
    connect(m_spectrumTimer, &QTimer::timeout, this, &Player::tickSpectrum);
    updateSpectrumTimer();

    qApp->installEventFilter(this);
    updateAccent();

    // Plasma rewrites kdeglobals when the colour scheme or accent changes.
    m_kdeglobalsWatcher = new QFileSystemWatcher(this);
    connect(m_kdeglobalsWatcher, &QFileSystemWatcher::fileChanged, this, [this] {
        QTimer::singleShot(250, this, [this] { updateTitleBarColor(); });
    });
    updateTitleBarColor();
}

Player::~Player()
{
    if (m_player)
        m_player->stop();
}

void Player::start()
{
    migrateFromTuneful();
    QSettings s;
    m_musicFolder = s.value(QStringLiteral("musicFolder"), QStandardPaths::writableLocation(QStandardPaths::MusicLocation)).toString();
    if (m_musicFolder.isEmpty())
        m_musicFolder = QDir::homePath() + QStringLiteral("/Music");
    m_volume = qBound(0.0, s.value(QStringLiteral("volume"), 0.7).toDouble(), 1.0);
    m_shuffle = s.value(QStringLiteral("shuffle"), false).toBool();
    m_repeat = qBound(0, s.value(QStringLiteral("repeat"), 0).toInt(), 2);
    m_lastTab = qBound(0, s.value(QStringLiteral("lastTab"), 4).toInt(), 6);
    m_frosted = s.value(QStringLiteral("frostedGlass"), false).toBool();
    m_accentHeader = s.value(QStringLiteral("accentHeader"), true).toBool();
    m_vizStyle = qBound(0, s.value(QStringLiteral("visualizer"), 1).toInt(), 3);
    m_appIcon = qBound(0, s.value(QStringLiteral("appIcon"), 2).toInt(), 2);
    m_resumeOnStart = s.value(QStringLiteral("resumeOnStart"), false).toBool();
    applyAppIcon(true);
    m_audio->setVolume(float(m_volume * m_volume));
    tn_queue_set_shuffle(m_shuffle);
    tn_queue_set_repeat(uint32_t(m_repeat));

    m_cacheDir = QStandardPaths::writableLocation(QStandardPaths::CacheLocation);
    if (m_cacheDir.isEmpty())
        m_cacheDir = QDir::homePath() + QStringLiteral("/.cache/sasha");
    QDir().mkpath(m_cacheDir);

    emit musicFolderChanged();
    emit volumeChanged();
    emit shuffleChanged();
    emit repeatModeChanged();
    emit lastTabChanged();
    emit frostedGlassChanged();
    emit accentHeaderChanged();
    loadPlaylists();
    emit vizStyleChanged();
    updateSpectrumTimer();
    applyBlur();
    emit resumeOnStartChanged();
    // Launch from the saved library; scan only the first time (or after the
    // music folder changes, or Rescan & Rebuild Library).
    if (!loadSavedLibrary())
        rescan();
}

void Player::saveSettings() const
{
    QSettings s;
    s.setValue(QStringLiteral("musicFolder"), m_musicFolder);
    s.setValue(QStringLiteral("volume"), m_volume);
    s.setValue(QStringLiteral("shuffle"), m_shuffle);
    s.setValue(QStringLiteral("repeat"), m_repeat);
    s.setValue(QStringLiteral("lastTab"), m_lastTab);
    s.setValue(QStringLiteral("frostedGlass"), m_frosted);
    s.setValue(QStringLiteral("accentHeader"), m_accentHeader);
    s.setValue(QStringLiteral("visualizer"), m_vizStyle);
    s.setValue(QStringLiteral("appIcon"), m_appIcon);
}

// Sasha used to be called Tuneful: bring its settings and playlists over once.
void Player::migrateFromTuneful()
{
    QSettings now;
    if (!now.value(QStringLiteral("migratedFromTuneful"), false).toBool()) {
        QSettings old(QStringLiteral("tuneful"), QStringLiteral("tuneful"));
        const QStringList keys = old.allKeys();
        if (!keys.isEmpty() && now.allKeys().isEmpty()) {
            for (const QString &k : keys)
                now.setValue(k, old.value(k));
        }
        now.setValue(QStringLiteral("migratedFromTuneful"), true);
        now.sync();
    }
    const QString data = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    const QString oldDir = data + QStringLiteral("/tuneful/playlists");
    if (!QDir(oldDir).exists())
        return;
    const QString newDir = playlistDir();
    QDir().mkpath(newDir);
    const QFileInfoList files = QDir(oldDir).entryInfoList(QDir::Files);
    for (const QFileInfo &fi : files) {
        const QString target = newDir + QLatin1Char('/') + fi.fileName();
        if (!QFile::exists(target))
            QFile::rename(fi.absoluteFilePath(), target);
    }
    // Remove the old folders if they're now empty.
    QDir().rmdir(oldDir);
    QDir().rmdir(data + QStringLiteral("/tuneful"));
}

// ------------------------------------------------------------------- icons --

static QString appIconFile(int icon)
{
    static const char *const names[3] = {"sasha-a.svg", "sasha-b.svg", "sasha-c.svg"};
    const QString name = QString::fromLatin1(names[qBound(0, icon, 2)]);
    const QStringList dirs = {QCoreApplication::applicationDirPath() + QStringLiteral("/icons"), QString::fromUtf8(TN_ASSET_DIR)};
    for (const QString &dir : dirs) {
        const QString path = dir + QLatin1Char('/') + name;
        if (QFile::exists(path))
            return path;
    }
    return QString();
}

QVariantList Player::appIcons() const
{
    const QStringList names = {tr("Bold"), tr("Flat"), tr("Spinning")};
    QVariantList out;
    for (int i = 0; i < 3; ++i) {
        QVariantMap m;
        m.insert(QStringLiteral("name"), names.at(i));
        const QString file = appIconFile(i);
        m.insert(QStringLiteral("url"), file.isEmpty() ? QString() : QUrl::fromLocalFile(file).toString());
        out.append(m);
    }
    return out;
}

void Player::setAppIcon(int icon)
{
    icon = qBound(0, icon, 2);
    if (icon == m_appIcon)
        return;
    m_appIcon = icon;
    saveSettings();
    emit appIconChanged();
    applyAppIcon(true);
}

// Sets the window icon and, when `syncFiles`, makes the installed icons (the
// launcher's next to the program, and the app menu's) match the choice.
void Player::applyAppIcon(bool syncFiles)
{
    const QString source = appIconFile(m_appIcon);
    if (source.isEmpty())
        return;
    QGuiApplication::setWindowIcon(QIcon(source));
    if (!syncFiles)
        return;
    QFile src(source);
    if (!src.open(QIODevice::ReadOnly))
        return;
    const QByteArray wanted = src.readAll();
    const QStringList targets = {
        QCoreApplication::applicationDirPath() + QStringLiteral("/sasha.svg"),
        QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/icons/hicolor/scalable/apps/sasha.svg"),
    };
    bool changed = false;
    for (const QString &target : targets) {
        QFile f(target);
        if (!f.exists() || !f.open(QIODevice::ReadOnly))
            continue; // only update icons the builder installed
        const bool same = f.readAll() == wanted;
        f.close();
        if (same)
            continue;
        QSaveFile out(target);
        if (out.open(QIODevice::WriteOnly) && out.write(wanted) == wanted.size() && out.commit())
            changed = true;
    }
    // Ask Plasma to pick up the new icon for the menu and task manager.
    if (changed) {
        const QString sycoca = QStandardPaths::findExecutable(QStringLiteral("kbuildsycoca6"));
        if (!sycoca.isEmpty())
            QProcess::startDetached(sycoca, {QStringLiteral("--noincremental")});
    }
}

void Player::setVizStyle(int style)
{
    style = qBound(0, style, 3);
    if (style == m_vizStyle)
        return;
    m_vizStyle = style;
    saveSettings();
    emit vizStyleChanged();
    updateSpectrumTimer();
}

void Player::cycleVizStyle()
{
    // small -> seek bar -> full panel -> off -> small
    static const int next[4] = {1, 2, 3, 0};
    setVizStyle(next[qBound(0, m_vizStyle, 3)]);
}

void Player::setSpectrumBands(int bands)
{
    bands = qBound(4, bands, kMaxBands);
    if (bands == m_bandCount)
        return;
    m_bandCount = bands;
    m_bands.assign(size_t(bands), 0.f);
    QVariantList zeros;
    zeros.reserve(bands);
    for (int i = 0; i < bands; ++i)
        zeros.append(0.0);
    m_spectrumList = zeros;
    emit spectrumBandsChanged();
    emit spectrumChanged();
}

// Runs the analyser only when something shows it: never while the style is
// "off" or the window is minimised, and at half rate while the window is in
// the background.
void Player::updateSpectrumTimer()
{
    bool run = spectrumAvailable() && m_vizStyle != 0;
    bool active = true;
    if (QQuickWindow *w = m_window.data()) {
        const QWindow::Visibility v = w->visibility();
        if (v == QWindow::Minimized || v == QWindow::Hidden)
            run = false;
        active = w->isActive();
    }
    if (!run) {
        m_spectrumTimer->stop();
        m_samples.clear();
        bool any = false;
        for (float &b : m_bands) {
            any = any || b != 0.f;
            b = 0.f;
        }
        if (any) {
            QVariantList zeros;
            for (size_t i = 0; i < m_bands.size(); ++i)
                zeros.append(0.0);
            m_spectrumList = zeros;
            emit spectrumChanged();
        }
        return;
    }
    m_spectrumTimer->setInterval(active ? 33 : 66);
    if (!m_spectrumTimer->isActive())
        m_spectrumTimer->start();
}

void Player::setFrostedGlass(bool on)
{
    if (on == m_frosted)
        return;
    m_frosted = on;
    saveSettings();
    emit frostedGlassChanged();
    applyBlur();
}

void Player::setAccentHeader(bool on)
{
    if (on == m_accentHeader)
        return;
    m_accentHeader = on;
    saveSettings();
    emit accentHeaderChanged();
}

bool Player::blurSupported() const
{
#ifdef TN_HAVE_KWINDOWSYSTEM
    return true;
#else
    return false;
#endif
}

// ---------------------------------------------------------------- library --

void Player::rescan()
{
    if (m_scanning) {
        m_rescanPending = true;
        return;
    }
    m_scanning = true;
    emit scanningChanged();
    m_libraryRoot = m_musicFolder;
    const QByteArray root = QFile::encodeName(m_musicFolder);
    const QByteArray cache = QFile::encodeName(m_cacheDir);
    QThread *thread = QThread::create([root, cache]() { tn_scan(root.constData(), cache.constData()); });
    connect(thread, &QThread::finished, this, &Player::onScanFinished);
    connect(thread, &QThread::finished, thread, &QObject::deleteLater);
    thread->start(QThread::LowPriority);
    m_scanTimer->start();
}

int Player::scanDone() const
{
    return int(tn_scan_progress());
}

int Player::scanTotal() const
{
    return int(tn_scan_total());
}

void Player::onScanFinished()
{
    m_scanTimer->stop();
    size_t len = 0;
    const uint8_t *data = tn_library_blob(&len);
    const QByteArray blob(reinterpret_cast<const char *>(data), qsizetype(len));
    saveLibrary(blob);
    m_scanning = false;
    applyLibrary(blob);
    emit scanningChanged();
    emit scanProgressChanged();

    if (m_rescanPending) {
        m_rescanPending = false;
        rescan();
    } else if (!m_pendingOpen.isEmpty()) {
        const QStringList paths = m_pendingOpen;
        m_pendingOpen.clear();
        openFiles(paths);
    }
}

// Installs a library (from a scan or the saved file) and keeps the playing
// song going if it's still there.
void Player::applyLibrary(const QByteArray &blob)
{
    QString playingPath;
    if (m_current >= 0 && m_current < qint64(m_tracks.size()))
        playingPath = m_tracks[size_t(m_current)].path;

    loadLibrary(blob);
    buildLists();
    buildPlaylistList();

    if (!playingPath.isEmpty()) {
        qint64 found = -1;
        for (size_t i = 0; i < m_tracks.size(); ++i) {
            if (m_tracks[i].path == playingPath) {
                found = qint64(i);
                break;
            }
        }
        m_current = found;
        if (found >= qint64(m_libraryCount)) {
            // An opened file outside the library: keep just that one queued.
            const uint32_t one = uint32_t(found);
            tn_queue_set(&one, 1, 0, false);
        } else if (found >= 0) {
            // The old queue's indices are stale: carry on through the whole library.
            std::vector<uint32_t> all(m_libraryCount);
            std::iota(all.begin(), all.end(), 0u);
            tn_queue_set(all.data(), all.size(), found, m_shuffle);
        } else {
            tn_queue_set(nullptr, 0, -1, m_shuffle);
            m_player->stop();
        }
    }

    emit libraryChanged();
    emit playlistsChanged();
    emit currentChanged();
    updateQueueInfo();

    if (!m_restored)
        restoreLastPlayed();
}

// ------------------------------------------------------ saved library --
// ~/.local/share/sasha/library.cache: a header line with the format version
// and the music folder it came from, then the scanner's records as they are.

static const QByteArray kLibraryMagic = QByteArrayLiteral("SASHA-LIBRARY 1");

QString Player::libraryFile() const
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/sasha/library.cache");
}

bool Player::loadSavedLibrary()
{
    QFile f(libraryFile());
    if (!f.open(QIODevice::ReadOnly))
        return false;
    const QByteArray all = f.readAll();
    const qsizetype eol = all.indexOf('\n');
    if (eol < 0)
        return false;
    const QList<QByteArray> head = all.left(eol).split('\x1f');
    if (head.size() < 2 || head[0] != kLibraryMagic)
        return false;
    const QString root = QString::fromUtf8(head[1]);
    if (root != m_musicFolder)
        return false; // saved for a different folder: scan this one
    // Cover art lives in ~/.cache, which can get cleaned out: if the first
    // album with a cover has lost it, scan again to bring the covers back.
    const QByteArray body = all.mid(eol + 1);
    for (const QByteArray &line : body.split('\n')) {
        if (!line.startsWith("A\x1f"))
            continue;
        const QList<QByteArray> f = line.split('\x1f');
        if (f.size() > 5 && !f[5].isEmpty()) {
            if (!QFile::exists(QString::fromUtf8(f[5])))
                return false;
            break;
        }
    }
    m_libraryRoot = root;
    applyLibrary(body);
    return true;
}

void Player::saveLibrary(const QByteArray &blob) const
{
    const QString file = libraryFile();
    QDir().mkpath(QFileInfo(file).absolutePath());
    QSaveFile out(file);
    if (!out.open(QIODevice::WriteOnly))
        return;
    out.write(kLibraryMagic + '\x1f' + m_libraryRoot.toUtf8() + '\n');
    out.write(blob);
    out.commit();
}

void Player::rebuildLibrary()
{
    if (m_scanning)
        return;
    QFile::remove(libraryFile());
    rescan();
}

// ------------------------------------------------- resume last played --

void Player::saveResumeState() const
{
    QSettings s;
    if (m_current < 0 || m_current >= qint64(m_tracks.size()))
        return;
    s.setValue(QStringLiteral("lastTrack"), m_tracks[size_t(m_current)].path);
    const bool stopped = m_player->playbackState() == QMediaPlayer::StoppedState;
    s.setValue(QStringLiteral("lastPosition"), stopped ? qint64(0) : m_player->position());
}

void Player::setResumeOnStart(bool on)
{
    if (on == m_resumeOnStart)
        return;
    m_resumeOnStart = on;
    QSettings().setValue(QStringLiteral("resumeOnStart"), on);
    emit resumeOnStartChanged();
}

// Puts the last song back in the header at its last position: playing if
// "resume on start" is on, otherwise paused there.
void Player::restoreLastPlayed()
{
    m_restored = true;
    if (m_current >= 0)
        return; // something is already playing
    QSettings s;
    const QString path = s.value(QStringLiteral("lastTrack")).toString();
    const qint64 position = s.value(QStringLiteral("lastPosition"), 0).toLongLong();
    if (path.isEmpty() || !QFileInfo::exists(path))
        return;
    int index = libraryIndexOf(path);
    if (index < 0) {
        index = addExternal(path);
        if (index < 0)
            return;
        m_songs.append(songMap(m_tracks[size_t(index)]));
        emit libraryChanged();
    }
    if (index >= int(m_libraryCount)) {
        const uint32_t one = uint32_t(index);
        tn_queue_set(&one, 1, 0, false);
    } else {
        // Carry on through the whole library from there, like after a rescan.
        std::vector<uint32_t> all(m_libraryCount);
        std::iota(all.begin(), all.end(), 0u);
        tn_queue_set(all.data(), all.size(), index, m_shuffle);
    }
    cueIndex(index, position, m_resumeOnStart);
}

void Player::cueIndex(qint64 index, qint64 positionMs, bool play)
{
    if (index < 0 || index >= qint64(m_tracks.size()))
        return;
    m_failStreak = 0;
    m_current = index;
    m_pendingSeek = positionMs > 0 ? positionMs : -1;
    m_player->setSource(QUrl::fromLocalFile(m_tracks[size_t(index)].path));
    if (play)
        m_player->play();
    else
        m_player->pause(); // loads the file and waits at the saved position
    emit currentChanged();
    emit durationChanged();
    updateQueueInfo();
}

void Player::loadLibrary(const QByteArray &blob)
{
    m_tracks.clear();
    m_albums2.clear();
    m_folders.clear();
    m_pathIndex.clear();
    const QList<QByteArray> lines = blob.split('\n');
    for (const QByteArray &line : lines) {
        if (line.isEmpty())
            continue;
        const QList<QByteArray> f = line.split('\x1f');
        auto str = [&f](int i) { return i < f.size() ? QString::fromUtf8(f[i]) : QString(); };
        auto num = [&f](int i) { return i < f.size() ? f[i].toLongLong() : 0LL; };
        if (f[0] == "T" && f.size() >= 18) {
            m_tracks.push_back(parseTrackRecord(f));
        } else if (f[0] == "A" && f.size() >= 10) {
            AlbumInfo a;
            a.title = str(1);
            a.artist = str(2);
            a.year = str(3);
            a.genre = str(4);
            a.cover = str(5);
            a.durationMs = num(6);
            a.size = num(7);
            a.codec = str(8);
            const QList<QByteArray> ids = f[9].split(',');
            for (const QByteArray &id : ids) {
                if (!id.isEmpty())
                    a.tracks.append(id.toInt());
            }
            m_albums2.push_back(a);
        } else if (f[0] == "F" && f.size() >= 8) {
            FolderInfo d;
            d.rel = str(1);
            d.name = str(2);
            d.parent = int(num(3));
            d.total = int(num(4));
            d.cover = str(5);
            for (const QByteArray &id : f[6].split(',')) {
                if (!id.isEmpty())
                    d.tracks.append(id.toInt());
            }
            for (const QByteArray &id : f[7].split(',')) {
                if (!id.isEmpty())
                    d.children.append(id.toInt());
            }
            m_folders.push_back(d);
        }
    }
    for (size_t i = 0; i < m_tracks.size(); ++i)
        m_pathIndex.insert(m_tracks[i].path, int(i));
    m_libraryCount = m_tracks.size();
    m_canonicalIndex.clear();

    // Files opened from outside the library stay playable across rescans,
    // unless they are in the library now.
    const QStringList externals = m_externals;
    m_externals.clear();
    for (const QString &path : externals) {
        if (libraryIndexOf(path) < 0 && QFileInfo::exists(path))
            addExternal(path);
    }
}

void Player::buildLists()
{
    m_songs.clear();
    m_albums.clear();
    qint64 totalMs = 0, totalSize = 0;
    const int albumCount = int(m_albums2.size());

    for (size_t i = 0; i < m_tracks.size(); ++i) {
        const TrackInfo &t = m_tracks[i];
        m_songs.append(songMap(t));
        if (i < m_libraryCount) {
            totalMs += t.durationMs;
            totalSize += t.size;
        }
    }

    QMap<QString, Group> artists, albumArtists, genres;
    for (int ai = 0; ai < albumCount; ++ai) {
        const AlbumInfo &a = m_albums2[size_t(ai)];
        QVariantList tracks;
        for (int ti : a.tracks)
            tracks.append(ti);
        QStringList meta;
        if (!a.codec.isEmpty())
            meta << a.codec;
        meta << plural(a.tracks.size(), tr("%1 track"), tr("%1 tracks"));
        meta << formatDuration(a.durationMs);
        QVariantMap m;
        m.insert(QStringLiteral("title"), a.title);
        m.insert(QStringLiteral("artist"), a.artist);
        m.insert(QStringLiteral("year"), a.year);
        m.insert(QStringLiteral("genre"), a.genre);
        m.insert(QStringLiteral("cover"), coverUrlFor(a.cover));
        m.insert(QStringLiteral("tracks"), tracks);
        m.insert(QStringLiteral("meta"), meta.join(QStringLiteral(" · ")));
        m.insert(QStringLiteral("search"), (a.title + QLatin1Char(' ') + a.artist + QLatin1Char(' ') + a.genre).toLower());
        m_albums.append(m);
        addToGroup(albumArtists, a.artist, ai, tracks);
    }

    for (size_t i = 0; i < m_libraryCount; ++i) {
        const TrackInfo &t = m_tracks[i];
        const QVariantList one{int(i)};
        addToGroup(artists, t.artist.isEmpty() ? tr("Unknown Artist") : t.artist, t.albumIndex, one);
        addToGroup(genres, t.genre.isEmpty() ? tr("Unknown Genre") : t.genre, t.albumIndex, one);
    }
    m_folderList.clear();
    std::vector<int> depth(m_folders.size(), 0);
    for (size_t i = 0; i < m_folders.size(); ++i) {
        const FolderInfo &d = m_folders[i];
        if (d.parent >= 0 && d.parent < int(i))
            depth[i] = depth[size_t(d.parent)] + 1;
        QVariantList tracks, children;
        for (int t : d.tracks)
            tracks.append(t);
        for (int c : d.children)
            children.append(c);
        QVariantMap m;
        m.insert(QStringLiteral("name"), d.name);
        m.insert(QStringLiteral("path"), d.rel);
        m.insert(QStringLiteral("parent"), d.parent);
        m.insert(QStringLiteral("depth"), depth[i]);
        m.insert(QStringLiteral("total"), d.total);
        m.insert(QStringLiteral("cover"), coverUrlFor(d.cover));
        m.insert(QStringLiteral("tracks"), tracks);
        m.insert(QStringLiteral("children"), children);
        m.insert(QStringLiteral("search"), d.name.toLower());
        m_folderList.append(m);
    }

    m_artists = groupsToList(artists, m_albums2);
    m_albumArtists = groupsToList(albumArtists, m_albums2);
    m_genres = groupsToList(genres, m_albums2);

    if (m_libraryCount == 0) {
        m_librarySummary.clear();
    } else {
        m_librarySummary = QStringList{
            plural(albumCount, tr("%1 album"), tr("%1 albums")),
            plural(qint64(m_libraryCount), tr("%1 song"), tr("%1 songs")),
            formatLong(totalMs),
            QLocale().formattedDataSize(totalSize, 1, QLocale::DataSizeTraditionalFormat),
        }.join(QStringLiteral(" · "));
    }
}

QString Player::musicFolderLabel() const
{
    const QString home = QDir::homePath();
    if (m_musicFolder == home)
        return QStringLiteral("~");
    if (m_musicFolder.startsWith(home + QLatin1Char('/')))
        return QStringLiteral("~") + m_musicFolder.mid(home.size());
    return m_musicFolder;
}

void Player::chooseMusicFolder()
{
    const QString dir = QFileDialog::getExistingDirectory(nullptr, tr("Choose your music folder"), m_musicFolder);
    if (dir.isEmpty() || dir == m_musicFolder)
        return;
    m_musicFolder = dir;
    saveSettings();
    emit musicFolderChanged();
    rescan();
}

// ------------------------------------------------------------- now playing --

QString Player::formatInfo() const
{
    if (m_current < 0 || m_current >= qint64(m_tracks.size()))
        return QString();
    const TrackInfo &t = m_tracks[size_t(m_current)];
    QStringList parts;
    if (!t.codec.isEmpty())
        parts << t.codec;
    if (t.sampleRate > 0) {
        const QString khz = (t.sampleRate % 1000 == 0) ? QString::number(t.sampleRate / 1000) : QString::number(t.sampleRate / 1000.0, 'f', 1);
        parts << khz + QStringLiteral(" kHz");
    }
    static const QStringList lossless = {QStringLiteral("FLAC"), QStringLiteral("ALAC"), QStringLiteral("WAV"), QStringLiteral("WAV (float)"),
                                         QStringLiteral("AIFF"), QStringLiteral("WavPack"), QStringLiteral("APE")};
    if (t.bits > 0 && lossless.contains(t.codec))
        parts << QStringLiteral("%1 bit").arg(t.bits);
    if (t.bitrate > 0)
        parts << QStringLiteral("%1 kbps").arg(t.bitrate);
    if (t.channels == 1)
        parts << tr("Mono");
    else if (t.channels == 2)
        parts << tr("Stereo");
    else if (t.channels > 2)
        parts << tr("%1 channels").arg(t.channels);
    return parts.join(QStringLiteral(" · "));
}

QString Player::coverUrl() const
{
    if (m_current < 0 || m_current >= qint64(m_tracks.size()))
        return QString();
    const TrackInfo &t = m_tracks[size_t(m_current)];
    const int album = t.albumIndex;
    if (album < 0 || album >= int(m_albums2.size()))
        return coverUrlFor(t.cover);
    return coverUrlFor(m_albums2[size_t(album)].cover);
}

int Player::playbackState() const
{
    return int(m_player->playbackState());
}

qint64 Player::position() const
{
    return m_player->position();
}

qint64 Player::duration() const
{
    const qint64 d = m_player->duration();
    if (d > 0)
        return d;
    if (m_current >= 0 && m_current < qint64(m_tracks.size()))
        return m_tracks[size_t(m_current)].durationMs;
    return 0;
}

QString Player::version() const
{
    return QStringLiteral(TN_VERSION);
}

// --------------------------------------------------------------- controls --

void Player::setShuffle(bool on)
{
    if (on == m_shuffle)
        return;
    m_shuffle = on;
    tn_queue_set_shuffle(on);
    saveSettings();
    emit shuffleChanged();
    updateQueueInfo();
}

void Player::setRepeatMode(int mode)
{
    mode = qBound(0, mode, 2);
    if (mode == m_repeat)
        return;
    m_repeat = mode;
    tn_queue_set_repeat(uint32_t(mode));
    saveSettings();
    emit repeatModeChanged();
    updateQueueInfo();
}

void Player::cycleRepeat()
{
    setRepeatMode((m_repeat + 1) % 3);
}

void Player::setVolume(qreal v)
{
    v = qBound(0.0, v, 1.0);
    if (qFuzzyCompare(v + 1.0, m_volume + 1.0))
        return;
    m_volume = v;
    // A squared curve feels closer to how loudness is heard than a linear one.
    m_audio->setVolume(float(v * v));
    saveSettings();
    emit volumeChanged();
}

void Player::setLastTab(int tab)
{
    tab = qBound(0, tab, 6);
    if (tab == m_lastTab)
        return;
    m_lastTab = tab;
    saveSettings();
    emit lastTabChanged();
}

void Player::playAll(bool shuffled)
{
    if (m_libraryCount == 0)
        return;
    if (shuffled != m_shuffle) {
        m_shuffle = shuffled;
        saveSettings();
        emit shuffleChanged();
    }
    std::vector<uint32_t> all(m_libraryCount);
    std::iota(all.begin(), all.end(), 0u);
    startQueue(all, -1, shuffled);
}

void Player::playList(const QVariantList &tracks, int startPos)
{
    std::vector<uint32_t> list;
    list.reserve(size_t(tracks.size()));
    for (const QVariant &v : tracks) {
        bool ok = false;
        const int i = v.toInt(&ok);
        if (ok && i >= 0 && i < int(m_tracks.size()))
            list.push_back(uint32_t(i));
    }
    if (list.empty())
        return;
    startQueue(list, startPos, m_shuffle);
}

void Player::shuffleList(const QVariantList &tracks)
{
    if (tracks.isEmpty())
        return;
    if (!m_shuffle) {
        m_shuffle = true;
        saveSettings();
        emit shuffleChanged();
    }
    playList(tracks, -1);
}

void Player::playAlbum(int album, int startTrack)
{
    if (album < 0 || album >= int(m_albums2.size()))
        return;
    const AlbumInfo &a = m_albums2[size_t(album)];
    std::vector<uint32_t> list;
    qint64 startPos = -1;
    for (int t : a.tracks) {
        if (t < 0 || t >= int(m_tracks.size()))
            continue;
        if (t == startTrack)
            startPos = qint64(list.size());
        list.push_back(uint32_t(t));
    }
    if (list.empty())
        return;
    // Starting an album from the top plays it in order unless shuffle is on.
    startQueue(list, startPos, m_shuffle);
}

void Player::startQueue(const std::vector<uint32_t> &tracks, qint64 startPos, bool shuffled)
{
    m_failStreak = 0;
    const int64_t first = tn_queue_set(tracks.data(), tracks.size(), startPos, shuffled);
    playIndex(first);
}

void Player::playIndex(qint64 index)
{
    if (index < 0 || index >= qint64(m_tracks.size())) {
        m_player->stop();
        updateQueueInfo();
        return;
    }
    m_current = index;
    m_pendingSeek = -1;
    m_player->setSource(QUrl::fromLocalFile(m_tracks[size_t(index)].path));
    m_player->play();
    {
        QSettings s;
        s.setValue(QStringLiteral("lastTrack"), m_tracks[size_t(index)].path);
        s.setValue(QStringLiteral("lastPosition"), qint64(0));
    }
    emit currentChanged();
    emit durationChanged();
    updateQueueInfo();
}

void Player::advance(bool user)
{
    const int64_t next = tn_queue_next(user);
    if (next < 0) {
        m_player->stop();
        updateQueueInfo();
        return;
    }
    playIndex(next);
}

void Player::togglePlay()
{
    if (m_player->playbackState() == QMediaPlayer::PlayingState) {
        m_player->pause();
        return;
    }
    if (m_current < 0 || m_player->source().isEmpty()) {
        playAll(m_shuffle);
        return;
    }
    m_player->play();
}

void Player::stop()
{
    m_player->stop();
}

void Player::next()
{
    advance(true);
}

void Player::previous()
{
    if (m_player->position() > 3000) {
        m_player->setPosition(0);
        return;
    }
    const int64_t prev = tn_queue_prev();
    if (prev >= 0)
        playIndex(prev);
}

void Player::seek(qint64 ms)
{
    m_player->setPosition(qMax<qint64>(0, ms));
}

void Player::updateQueueInfo()
{
    QString info;
    const uint32_t len = tn_queue_len();
    if (len > 0 && m_current >= 0) {
        info = plural(len, tr("Queue: %1 song"), tr("Queue: %1 songs"));
        if (tn_queue_shuffled() && len > 1)
            info += tr(", shuffled");
        const int64_t next = tn_queue_peek();
        if (m_repeat == 2)
            info += QStringLiteral(" · ") + tr("repeating this song");
        else if (next >= 0 && next < int64_t(m_tracks.size()) && next != m_current)
            info += QStringLiteral(" · ") + tr("next: %1").arg(m_tracks[size_t(next)].title);
        else if (next < 0)
            info += QStringLiteral(" · ") + tr("last song");
    }
    if (info != m_queueInfo) {
        m_queueInfo = info;
        emit queueChanged();
    }
}

void Player::setMessage(const QString &text)
{
    if (text == m_message)
        return;
    m_message = text;
    emit messageChanged();
    if (!text.isEmpty())
        m_messageTimer->start();
}

// ------------------------------------------------------- desktop integration --

bool Player::eventFilter(QObject *watched, QEvent *event)
{
    // (The title bar colour has its own file watcher.)
    if (event->type() == QEvent::ApplicationPaletteChange)
        updateAccent();
    return QObject::eventFilter(watched, event);
}

void Player::updateAccent()
{
    const QPalette pal = QGuiApplication::palette();
#if QT_VERSION >= QT_VERSION_CHECK(6, 6, 0)
    QColor c = pal.color(QPalette::Active, QPalette::Accent);
#else
    QColor c = pal.color(QPalette::Active, QPalette::Highlight);
#endif
    if (!c.isValid())
        c = QColor(0x3d, 0xae, 0xe9);
    if (c != m_accent) {
        m_accent = c;
        emit accentChanged();
    }
}

// kdeglobals as section -> key -> value. KDE section names such as
// "[Colors:Header][Inactive]" have nested brackets that QSettings mangles,
// so this reads the file directly.
static QHash<QString, QHash<QString, QString>> readKdeConfig(const QString &path)
{
    QHash<QString, QHash<QString, QString>> out;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly | QIODevice::Text))
        return out;
    QString section;
    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine()).trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        if (line.startsWith(QLatin1Char('[')) && line.endsWith(QLatin1Char(']'))) {
            section = line.mid(1, line.size() - 2);
            continue;
        }
        const int eq = line.indexOf(QLatin1Char('='));
        if (eq <= 0)
            continue;
        QString key = line.left(eq).trimmed();
        const int flags = key.indexOf(QLatin1String("[$"));
        if (flags >= 0)
            key = key.left(flags).trimmed();
        out[section].insert(key, line.mid(eq + 1).trimmed());
    }
    return out;
}

// "r,g,b" (or "r,g,b,a") from kdeglobals.
static QColor kdeColor(const QString &value)
{
    const QStringList parts = value.split(QLatin1Char(','));
    if (parts.size() < 3)
        return QColor();
    bool okR = false, okG = false, okB = false;
    const int r = parts.at(0).trimmed().toInt(&okR);
    const int g = parts.at(1).trimmed().toInt(&okG);
    const int b = parts.at(2).trimmed().toInt(&okB);
    if (!okR || !okG || !okB)
        return QColor();
    return QColor(qBound(0, r, 255), qBound(0, g, 255), qBound(0, b, 255));
}

void Player::updateTitleBarColor()
{
    const QString path = QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + QStringLiteral("/kdeglobals");
    QColor active, inactive;
    if (QFile::exists(path)) {
        const auto cfg = readKdeConfig(path);
        auto value = [&cfg](const QString &section, const QString &key) {
            return cfg.value(section).value(key);
        };
        // Breeze paints the title bar from the colour scheme's Header colours
        // when the scheme has them (that's also where the accent-coloured
        // title bar and its inactive tint end up), else from [WM].
        active = kdeColor(value(QStringLiteral("Colors:Header"), QStringLiteral("BackgroundNormal")));
        if (!active.isValid())
            active = kdeColor(value(QStringLiteral("WM"), QStringLiteral("activeBackground")));
        inactive = kdeColor(value(QStringLiteral("Colors:Header][Inactive"), QStringLiteral("BackgroundNormal")));
        if (!inactive.isValid())
            inactive = kdeColor(value(QStringLiteral("WM"), QStringLiteral("inactiveBackground")));
        // The file is replaced on save, which drops it from the watch list.
        if (m_kdeglobalsWatcher && !m_kdeglobalsWatcher->files().contains(path))
            m_kdeglobalsWatcher->addPath(path);
    }
    if (active != m_titleBarColor || inactive != m_inactiveTitleBarColor) {
        m_titleBarColor = active;
        m_inactiveTitleBarColor = inactive;
        emit titleBarColorChanged();
    }
}

void Player::attachWindow(QQuickWindow *window)
{
    m_window = window;
    if (!window)
        return;
    connect(window, &QWindow::visibleChanged, this, [this](bool) { applyBlur(); });
    connect(window, &QWindow::activeChanged, this, [this] { updateSpectrumTimer(); });
    connect(window, &QWindow::visibilityChanged, this, [this](QWindow::Visibility) { updateSpectrumTimer(); });
    updateSpectrumTimer();
    // On Wayland the blur protocol can show up a moment after start-up.
    QTimer::singleShot(300, this, [this] { applyBlur(); });
    QTimer::singleShot(2000, this, [this] { applyBlur(); });
}

void Player::setBlurRect(qreal x, qreal y, qreal w, qreal h)
{
    const QRect r = QRectF(x, y, w, h).toAlignedRect();
    if (r == m_blurRect)
        return;
    m_blurRect = r;
    applyBlur();
}

void Player::applyBlur()
{
#ifdef TN_HAVE_KWINDOWSYSTEM
    QQuickWindow *w = m_window.data();
    bool available = false;
    if (w && !qEnvironmentVariableIsSet("SASHA_NO_BLUR"))
        available = KWindowEffects::isEffectAvailable(KWindowEffects::BlurBehind);
    // Only blur when the user opted in (it's experimental); otherwise make
    // sure any earlier blur region is removed.
    if (w && w->isVisible())
        KWindowEffects::enableBlurBehind(w, m_frosted && available && !m_blurRect.isEmpty(), QRegion(m_blurRect));
    if (available != m_blurAvailable) {
        m_blurAvailable = available;
        emit blurAvailableChanged();
    }
#endif
}

// ---------------------------------------------------------------- spectrum --

bool Player::spectrumAvailable() const
{
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
    return true;
#else
    return false;
#endif
}

void Player::onAudioBuffer(const QAudioBuffer &buffer)
{
#if QT_VERSION >= QT_VERSION_CHECK(6, 8, 0)
    const QAudioFormat fmt = buffer.format();
    const int channels = fmt.channelCount();
    const int bytes = fmt.bytesPerSample();
    if (channels <= 0 || bytes <= 0)
        return;
    const char *data = buffer.constData<char>();
    const qsizetype frames = buffer.frameCount();
    m_sampleRate = fmt.sampleRate();
    for (qsizetype i = 0; i < frames; ++i) {
        float sum = 0.f;
        for (int c = 0; c < channels; ++c)
            sum += fmt.normalizedSampleValue(data + (i * channels + c) * bytes);
        m_samples.push_back(sum / float(channels));
    }
    const size_t keep = 4096;
    if (m_samples.size() > keep)
        m_samples.erase(m_samples.begin(), m_samples.end() - std::ptrdiff_t(keep));
#else
    Q_UNUSED(buffer);
#endif
}

void Player::tickSpectrum()
{
    const int bands = m_bandCount;
    if (int(m_bands.size()) != bands)
        m_bands.assign(size_t(bands), 0.f);
    std::vector<float> fresh(size_t(bands), 0.f);
    const bool playing = m_player->playbackState() == QMediaPlayer::PlayingState;
    // More bands need a longer window for enough low-frequency resolution.
    const size_t window = bands > 32 ? 2048 : 1024;
    if (playing && m_samples.size() >= window)
        tn_spectrum(m_samples.data() + (m_samples.size() - window), window, uint32_t(m_sampleRate), fresh.data(), size_t(bands));
    if (!playing)
        m_samples.clear();

    bool changed = false;
    for (int i = 0; i < bands; ++i) {
        float v = fresh[size_t(i)] > m_bands[size_t(i)] ? fresh[size_t(i)] : m_bands[size_t(i)] * 0.86f;
        if (v < 0.01f)
            v = 0.f;
        if (v != m_bands[size_t(i)]) {
            m_bands[size_t(i)] = v;
            changed = true;
        }
    }
    if (!changed)
        return;
    QVariantList list;
    list.reserve(bands);
    for (float v : m_bands)
        list.append(double(v));
    m_spectrumList = list;
    emit spectrumChanged();
}

// ------------------------------------------------------------- play next --

std::vector<uint32_t> Player::toTrackList(const QVariantList &tracks) const
{
    std::vector<uint32_t> list;
    list.reserve(size_t(tracks.size()));
    for (const QVariant &v : tracks) {
        bool ok = false;
        const int i = v.toInt(&ok);
        if (ok && i >= 0 && i < int(m_tracks.size()))
            list.push_back(uint32_t(i));
    }
    return list;
}

void Player::playNext(const QVariantList &tracks)
{
    const std::vector<uint32_t> list = toTrackList(tracks);
    if (list.empty())
        return;
    if (m_current < 0 || tn_queue_len() == 0) {
        startQueue(list, -1, false);
        return;
    }
    tn_queue_insert_next(list.data(), list.size());
    updateQueueInfo();
}

// ------------------------------------------------------------ file manager --

void Player::showInFileManager(const QVariantList &tracks)
{
    QStringList uris;
    for (uint32_t t : toTrackList(tracks)) {
        uris << QUrl::fromLocalFile(m_tracks[t].path).toString();
        if (uris.size() >= 50)
            break;
    }
    if (uris.isEmpty())
        return;
    // org.freedesktop.FileManager1 opens the folder with the files selected
    // (Dolphin, Nautilus, Nemo, Thunar...); otherwise just open the folder.
    QDBusMessage call = QDBusMessage::createMethodCall(QStringLiteral("org.freedesktop.FileManager1"),
                                                       QStringLiteral("/org/freedesktop/FileManager1"),
                                                       QStringLiteral("org.freedesktop.FileManager1"),
                                                       QStringLiteral("ShowItems"));
    call << uris << QString();
    const QDBusMessage reply = QDBusConnection::sessionBus().call(call, QDBus::Block, 3000);
    if (reply.type() == QDBusMessage::ErrorMessage) {
        const QString first = QUrl(uris.first()).toLocalFile();
        QDesktopServices::openUrl(QUrl::fromLocalFile(QFileInfo(first).absolutePath()));
    }
}

void Player::showFolderInFileManager(int folder)
{
    if (folder < 0 || folder >= int(m_folders.size()))
        return;
    const QString rel = m_folders[size_t(folder)].rel;
    const QString path = rel.isEmpty() ? m_libraryRoot : m_libraryRoot + QLatin1Char('/') + rel;
    QDesktopServices::openUrl(QUrl::fromLocalFile(path));
}

// ----------------------------------------------------------------- folders --

QVariantList Player::folderTracks(int folder, bool recursive) const
{
    QVariantList out;
    if (folder < 0 || folder >= int(m_folders.size()))
        return out;
    // Depth-first: a folder's own songs, then each subfolder in name order.
    std::vector<int> stack{folder};
    while (!stack.empty()) {
        const int f = stack.back();
        stack.pop_back();
        const FolderInfo &d = m_folders[size_t(f)];
        for (int t : d.tracks)
            out.append(t);
        if (!recursive)
            break;
        for (int k = int(d.children.size()) - 1; k >= 0; --k) {
            const int c = d.children[k];
            if (c > f && c < int(m_folders.size()))
                stack.push_back(c);
        }
    }
    return out;
}

// --------------------------------------------------------------- playlists --

QString Player::playlistDir() const
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/sasha/playlists");
}

int Player::playlistIndexByName(const QString &name) const
{
    for (size_t i = 0; i < m_playlists.size(); ++i) {
        if (m_playlists[i].name.compare(name, Qt::CaseInsensitive) == 0)
            return int(i);
    }
    return -1;
}

static bool playlistLess(const PlaylistInfo &a, const PlaylistInfo &b)
{
    return a.name.compare(b.name, Qt::CaseInsensitive) < 0;
}

void Player::loadPlaylists()
{
    const QString dir = playlistDir();
    QDir().mkpath(dir);
    m_playlists.clear();
    const QFileInfoList files = QDir(dir).entryInfoList({QStringLiteral("*.m3u8"), QStringLiteral("*.m3u")}, QDir::Files | QDir::Readable);
    const QByteArray base = QFile::encodeName(dir);
    for (const QFileInfo &fi : files) {
        QFile f(fi.absoluteFilePath());
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QByteArray text = f.readAll();
        PlaylistInfo p;
        p.name = fi.completeBaseName();
        p.file = fi.absoluteFilePath();
        size_t len = 0;
        uint8_t *buf = tn_m3u_parse(reinterpret_cast<const uint8_t *>(text.constData()), size_t(text.size()), base.constData(), &len);
        const QByteArray paths(reinterpret_cast<const char *>(buf), qsizetype(len));
        tn_free_buffer(buf, len);
        for (const QByteArray &line : paths.split('\n')) {
            if (!line.isEmpty())
                p.paths << QFile::decodeName(line);
        }
        if (playlistIndexByName(p.name) < 0)
            m_playlists.push_back(p);
    }
    std::sort(m_playlists.begin(), m_playlists.end(), playlistLess);
    buildPlaylistList();
    emit playlistsChanged();
}

void Player::buildPlaylistList()
{
    m_playlistList.clear();
    for (const PlaylistInfo &p : m_playlists) {
        qint64 ms = 0;
        for (const QString &path : p.paths) {
            const int t = m_pathIndex.value(path, -1);
            if (t >= 0)
                ms += m_tracks[size_t(t)].durationMs;
        }
        QVariantMap m;
        m.insert(QStringLiteral("name"), p.name);
        m.insert(QStringLiteral("count"), int(p.paths.size()));
        m.insert(QStringLiteral("durationMs"), double(ms));
        m.insert(QStringLiteral("meta"), plural(p.paths.size(), tr("%1 song"), tr("%1 songs")) + QStringLiteral(" · ") + formatLong(ms));
        m_playlistList.append(m);
    }
}

bool Player::savePlaylist(int playlist)
{
    if (playlist < 0 || playlist >= int(m_playlists.size()))
        return false;
    const PlaylistInfo &p = m_playlists[size_t(playlist)];
    QSaveFile f(p.file);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Text)) {
        setMessage(tr("Couldn't save the playlist \"%1\"").arg(p.name));
        return false;
    }
    QByteArray out("#EXTM3U\n");
    for (const QString &path : p.paths) {
        const int t = m_pathIndex.value(path, -1);
        if (t >= 0) {
            const TrackInfo &ti = m_tracks[size_t(t)];
            const QString label = ti.artist.isEmpty() ? ti.title : ti.artist + QStringLiteral(" - ") + ti.title;
            out += "#EXTINF:" + QByteArray::number(ti.durationMs / 1000) + ',' + label.toUtf8() + '\n';
        }
        out += QFile::encodeName(path) + '\n';
    }
    f.write(out);
    if (!f.commit()) {
        setMessage(tr("Couldn't save the playlist \"%1\"").arg(p.name));
        return false;
    }
    return true;
}

QString Player::uniquePlaylistName(const QString &base) const
{
    QString clean = base.trimmed();
    clean.replace(QLatin1Char('/'), QLatin1Char('-'));
    if (clean.isEmpty() || clean == QStringLiteral(".") || clean == QStringLiteral(".."))
        clean = tr("New playlist");
    QString name = clean;
    for (int n = 2; playlistIndexByName(name) >= 0; ++n)
        name = QStringLiteral("%1 %2").arg(clean).arg(n);
    return name;
}

QVariantList Player::playlistEntries(int playlist) const
{
    QVariantList out;
    if (playlist < 0 || playlist >= int(m_playlists.size()))
        return out;
    for (const QString &path : m_playlists[size_t(playlist)].paths) {
        const int t = m_pathIndex.value(path, -1);
        QVariantMap m;
        m.insert(QStringLiteral("track"), t);
        if (t >= 0) {
            const TrackInfo &ti = m_tracks[size_t(t)];
            m.insert(QStringLiteral("title"), ti.title);
            m.insert(QStringLiteral("artist"), ti.artist.isEmpty() ? tr("Unknown Artist") : ti.artist);
            m.insert(QStringLiteral("album"), ti.album);
            m.insert(QStringLiteral("time"), formatDuration(ti.durationMs));
        } else {
            m.insert(QStringLiteral("title"), QFileInfo(path).fileName());
            m.insert(QStringLiteral("artist"), QString());
            m.insert(QStringLiteral("album"), tr("not in your library"));
            m.insert(QStringLiteral("time"), QString());
        }
        out.append(m);
    }
    return out;
}

int Player::createPlaylist(const QString &name, const QVariantList &tracks)
{
    PlaylistInfo p;
    p.name = uniquePlaylistName(name);
    p.file = playlistDir() + QLatin1Char('/') + p.name + QStringLiteral(".m3u8");
    for (uint32_t t : toTrackList(tracks))
        p.paths << m_tracks[t].path;
    QDir().mkpath(playlistDir());
    m_playlists.push_back(p);
    std::sort(m_playlists.begin(), m_playlists.end(), playlistLess);
    const int index = playlistIndexByName(p.name);
    savePlaylist(index);
    buildPlaylistList();
    emit playlistsChanged();
    return index;
}

int Player::renamePlaylist(int playlist, const QString &name)
{
    if (playlist < 0 || playlist >= int(m_playlists.size()))
        return playlist;
    PlaylistInfo &p = m_playlists[size_t(playlist)];
    if (name.trimmed() == p.name || name.trimmed().isEmpty())
        return playlist;
    const QString newName = uniquePlaylistName(name);
    const QString newFile = QFileInfo(p.file).absolutePath() + QLatin1Char('/') + newName + QLatin1Char('.') + QFileInfo(p.file).suffix();
    if (!QFile::rename(p.file, newFile)) {
        setMessage(tr("Couldn't rename \"%1\"").arg(p.name));
        return playlist;
    }
    p.name = newName;
    p.file = newFile;
    std::sort(m_playlists.begin(), m_playlists.end(), playlistLess);
    buildPlaylistList();
    emit playlistsChanged();
    return playlistIndexByName(newName);
}

void Player::deletePlaylist(int playlist)
{
    if (playlist < 0 || playlist >= int(m_playlists.size()))
        return;
    const PlaylistInfo p = m_playlists[size_t(playlist)];
    // To the trash, so a slip of the mouse can be undone from Dolphin.
    if (!QFile::moveToTrash(p.file) && !QFile::remove(p.file) && QFile::exists(p.file)) {
        setMessage(tr("Couldn't delete \"%1\"").arg(p.name));
        return;
    }
    m_playlists.erase(m_playlists.begin() + playlist);
    buildPlaylistList();
    emit playlistsChanged();
    setMessage(tr("Moved \"%1\" to the trash").arg(p.name));
}

void Player::addToPlaylist(int playlist, const QVariantList &tracks, int atRow)
{
    if (playlist < 0 || playlist >= int(m_playlists.size()))
        return;
    PlaylistInfo &p = m_playlists[size_t(playlist)];
    const std::vector<uint32_t> list = toTrackList(tracks);
    if (list.empty())
        return;
    int at = (atRow < 0 || atRow > p.paths.size()) ? int(p.paths.size()) : atRow;
    for (uint32_t t : list)
        p.paths.insert(at++, m_tracks[t].path);
    savePlaylist(playlist);
    buildPlaylistList();
    emit playlistsChanged();
}

void Player::removeFromPlaylist(int playlist, const QVariantList &rows)
{
    if (playlist < 0 || playlist >= int(m_playlists.size()))
        return;
    PlaylistInfo &p = m_playlists[size_t(playlist)];
    QList<int> sorted;
    for (const QVariant &v : rows) {
        const int r = v.toInt();
        if (r >= 0 && r < p.paths.size() && !sorted.contains(r))
            sorted << r;
    }
    if (sorted.isEmpty())
        return;
    std::sort(sorted.begin(), sorted.end(), std::greater<int>());
    for (int r : sorted)
        p.paths.removeAt(r);
    savePlaylist(playlist);
    buildPlaylistList();
    emit playlistsChanged();
}

void Player::moveInPlaylist(int playlist, const QVariantList &rows, int toRow)
{
    if (playlist < 0 || playlist >= int(m_playlists.size()))
        return;
    PlaylistInfo &p = m_playlists[size_t(playlist)];
    QList<int> picked;
    for (const QVariant &v : rows) {
        const int r = v.toInt();
        if (r >= 0 && r < p.paths.size() && !picked.contains(r))
            picked << r;
    }
    if (picked.isEmpty())
        return;
    std::sort(picked.begin(), picked.end());
    toRow = qBound(0, toRow, int(p.paths.size()));
    QStringList moving;
    for (int r : picked)
        moving << p.paths.at(r);
    int before = 0; // picked rows above the drop point shift it up
    for (int r : picked) {
        if (r < toRow)
            ++before;
    }
    for (int k = picked.size() - 1; k >= 0; --k)
        p.paths.removeAt(picked[k]);
    int at = toRow - before;
    for (const QString &path : moving)
        p.paths.insert(at++, path);
    savePlaylist(playlist);
    buildPlaylistList();
    emit playlistsChanged();
}

void Player::playPlaylist(int playlist, int startRow, bool shuffled)
{
    if (playlist < 0 || playlist >= int(m_playlists.size()))
        return;
    const PlaylistInfo &p = m_playlists[size_t(playlist)];
    std::vector<uint32_t> list;
    qint64 startPos = -1;
    for (int r = 0; r < p.paths.size(); ++r) {
        const int t = m_pathIndex.value(p.paths.at(r), -1);
        if (t < 0)
            continue;
        if (r == startRow)
            startPos = qint64(list.size());
        list.push_back(uint32_t(t));
    }
    if (list.empty()) {
        setMessage(tr("None of the songs in \"%1\" are in your library").arg(p.name));
        return;
    }
    if (shuffled && !m_shuffle) {
        m_shuffle = true;
        saveSettings();
        emit shuffleChanged();
    }
    startQueue(list, startPos, shuffled || m_shuffle);
}

// ------------------------------------------------------- opening files --

QVariantMap Player::songMap(const TrackInfo &t) const
{
    const int albumCount = int(m_albums2.size());
    const QString artist = t.artist.isEmpty() ? tr("Unknown Artist") : t.artist;
    QVariantMap m;
    m.insert(QStringLiteral("title"), t.title);
    m.insert(QStringLiteral("artist"), artist);
    m.insert(QStringLiteral("album"), t.album);
    m.insert(QStringLiteral("year"), t.year);
    m.insert(QStringLiteral("genre"), t.genre);
    m.insert(QStringLiteral("track"), t.track);
    m.insert(QStringLiteral("disc"), t.disc);
    m.insert(QStringLiteral("durationMs"), double(t.durationMs));
    m.insert(QStringLiteral("time"), formatDuration(t.durationMs));
    m.insert(QStringLiteral("albumIndex"), (t.albumIndex >= 0 && t.albumIndex < albumCount) ? t.albumIndex : -1);
    m.insert(QStringLiteral("codec"), t.codec);
    m.insert(QStringLiteral("search"), QStringList{t.title, artist, t.album, t.genre}.join(QStringLiteral(" ")).toLower());
    // Opened files outside the library play and show in the header, but stay
    // out of All Songs.
    m.insert(QStringLiteral("external"), t.external);
    return m;
}

// Files as given, folders as every audio file inside them (sorted by path),
// .m3u/.m3u8 playlists as the files they list.
QStringList Player::expandOpenPaths(const QStringList &paths) const
{
    static const QStringList audioGlobs = {
        QStringLiteral("*.mp3"), QStringLiteral("*.mp2"), QStringLiteral("*.mp1"), QStringLiteral("*.flac"),
        QStringLiteral("*.ogg"), QStringLiteral("*.oga"), QStringLiteral("*.opus"), QStringLiteral("*.m4a"),
        QStringLiteral("*.m4b"), QStringLiteral("*.mp4"), QStringLiteral("*.alac"), QStringLiteral("*.aac"),
        QStringLiteral("*.wav"), QStringLiteral("*.aif"), QStringLiteral("*.aiff"), QStringLiteral("*.wv"),
        QStringLiteral("*.ape"), QStringLiteral("*.wma"), QStringLiteral("*.mpc"), QStringLiteral("*.dsf"),
    };
    QStringList out;
    for (const QString &given : paths) {
        const QFileInfo fi(given);
        if (fi.isDir()) {
            QStringList found;
            QDirIterator it(fi.absoluteFilePath(), audioGlobs, QDir::Files | QDir::Readable,
                            QDirIterator::Subdirectories | QDirIterator::FollowSymlinks);
            while (it.hasNext())
                found << it.next();
            found.sort(Qt::CaseInsensitive);
            out << found;
        } else if (fi.isFile()) {
            const QString suffix = fi.suffix().toLower();
            if (suffix == QLatin1String("m3u") || suffix == QLatin1String("m3u8")) {
                QFile f(fi.absoluteFilePath());
                if (!f.open(QIODevice::ReadOnly))
                    continue;
                const QByteArray text = f.readAll();
                const QByteArray base = QFile::encodeName(fi.absolutePath());
                size_t len = 0;
                uint8_t *buf = tn_m3u_parse(reinterpret_cast<const uint8_t *>(text.constData()), size_t(text.size()),
                                            base.constData(), &len);
                const QByteArray list(reinterpret_cast<const char *>(buf), qsizetype(len));
                tn_free_buffer(buf, len);
                for (const QByteArray &line : list.split('\n')) {
                    if (!line.isEmpty())
                        out << QFile::decodeName(line);
                }
            } else {
                out << fi.absoluteFilePath();
            }
        }
    }
    return out;
}

// The library track for `path`, matching through symlinks too
// (e.g. /home -> /var/home on Fedora Atomic), or -1.
int Player::libraryIndexOf(const QString &path)
{
    const int direct = m_pathIndex.value(path, -1);
    if (direct >= 0)
        return direct;
    const QString canonical = QFileInfo(path).canonicalFilePath();
    if (canonical.isEmpty())
        return -1;
    if (m_canonicalIndex.isEmpty()) {
        for (size_t i = 0; i < m_libraryCount; ++i) {
            const QString c = QFileInfo(m_tracks[i].path).canonicalFilePath();
            if (!c.isEmpty())
                m_canonicalIndex.insert(c, int(i));
        }
    }
    const int viaLink = m_canonicalIndex.value(canonical, -1);
    if (viaLink >= 0)
        return viaLink;
    const int external = m_pathIndex.value(canonical, -1);
    return external;
}

// Reads a file outside the library and appends it to m_tracks.
int Player::addExternal(const QString &path)
{
    const QByteArray p = QFile::encodeName(path);
    const QByteArray cache = QFile::encodeName(m_cacheDir);
    size_t len = 0;
    uint8_t *buf = tn_read_track(p.constData(), cache.constData(), &len);
    const QByteArray rec(reinterpret_cast<const char *>(buf), qsizetype(len));
    tn_free_buffer(buf, len);
    const QList<QByteArray> f = rec.split('\x1f');
    if (f.size() < 18 || f[0] != "T")
        return -1;
    TrackInfo t = parseTrackRecord(f);
    t.path = path;
    t.albumIndex = -1;
    t.external = true;
    const int index = int(m_tracks.size());
    m_tracks.push_back(t);
    m_pathIndex.insert(path, index);
    m_externals << path;
    return index;
}

void Player::openFiles(const QStringList &paths)
{
    if (paths.isEmpty())
        return;
    if (m_scanning || m_cacheDir.isEmpty()) {
        // Not started yet, or track indices are about to change: open them
        // once the scan lands.
        m_pendingOpen << paths;
        return;
    }
    const QStringList files = expandOpenPaths(paths);
    std::vector<uint32_t> list;
    bool added = false;
    for (const QString &file : files) {
        int index = libraryIndexOf(file);
        if (index < 0) {
            index = addExternal(QFileInfo(file).absoluteFilePath());
            if (index < 0)
                continue;
            m_songs.append(songMap(m_tracks[size_t(index)]));
            added = true;
        }
        list.push_back(uint32_t(index));
    }
    if (added)
        emit libraryChanged();
    if (list.empty()) {
        setMessage(tr("Nothing playable in what was opened"));
        return;
    }
    // Plays what was opened, first file first; with shuffle on, the rest are shuffled.
    startQueue(list, 0, m_shuffle);
}

void Player::Open(const QStringList &paths, const QString &activationToken)
{
    raiseWindow(activationToken);
    openFiles(paths);
}

void Player::Activate(const QString &activationToken)
{
    raiseWindow(activationToken);
}

void Player::raiseWindow(const QString &activationToken)
{
    if (!m_window)
        return;
    if (m_window->visibility() == QWindow::Minimized || !m_window->isVisible())
        m_window->showNormal();
#ifdef TN_HAVE_KWINDOWSYSTEM
    if (!activationToken.isEmpty())
        KWindowSystem::setCurrentXdgActivationToken(activationToken);
    KWindowSystem::activateWindow(m_window);
#else
    if (!activationToken.isEmpty())
        qputenv("XDG_ACTIVATION_TOKEN", activationToken.toUtf8());
    m_window->raise();
    m_window->requestActivate();
#endif
}
