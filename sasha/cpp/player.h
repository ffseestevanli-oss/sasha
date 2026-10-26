// Player: the object QML talks to (as the context property "player").
// Owns playback (Qt Multimedia), the library snapshot handed over by the
// Rust scanner, the queue (kept in Rust), the spectrum, the KDE accent
// colour and the frosted-glass blur.

#pragma once

#include <QColor>
#include <QObject>
#include <QPointer>
#include <QRect>
#include <QHash>
#include <QString>
#include <QStringList>
#include <QVariant>
#include <QVector>
#include <QtGlobal>

#include <cstdint>
#include <vector>

class QAudioBuffer;
class QAudioBufferOutput;
class QAudioOutput;
class QFileSystemWatcher;
class QMediaPlayer;
class QQuickWindow;
class QTimer;

struct TrackInfo {
    QString path, title, artist, album, albumArtist, genre, year, codec;
    int track = 0, disc = 0, sampleRate = 0, bits = 0, bitrate = 0, channels = 0, albumIndex = -1;
    qint64 durationMs = 0, size = 0;
    QString cover;          // only for files outside the library
    bool external = false;  // opened from a file manager, not in the music folder
};

struct PlaylistInfo {
    QString name;
    QString file;
    QStringList paths;
};

struct FolderInfo {
    QString rel, name, cover;
    int parent = -1;
    int total = 0;
    QVector<int> tracks;   // directly in this folder
    QVector<int> children; // subfolders
};

struct AlbumInfo {
    QString title, artist, year, genre, cover, codec;
    qint64 durationMs = 0, size = 0;
    QVector<int> tracks;
};

class Player : public QObject {
    Q_OBJECT
    // Single instance: a second launch hands its files to the running one over D-Bus.
    Q_CLASSINFO("D-Bus Interface", "io.github.sasha.Sasha")
    Q_PROPERTY(QVariantList songs READ songs NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList albums READ albums NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList artists READ artists NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList albumArtists READ albumArtists NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList genres READ genres NOTIFY libraryChanged)
    Q_PROPERTY(int trackCount READ trackCount NOTIFY libraryChanged)
    Q_PROPERTY(QString librarySummary READ librarySummary NOTIFY libraryChanged)
    Q_PROPERTY(bool scanning READ scanning NOTIFY scanningChanged)
    Q_PROPERTY(int scanDone READ scanDone NOTIFY scanProgressChanged)
    Q_PROPERTY(int scanTotal READ scanTotal NOTIFY scanProgressChanged)
    Q_PROPERTY(QString musicFolder READ musicFolder NOTIFY musicFolderChanged)
    Q_PROPERTY(QString musicFolderLabel READ musicFolderLabel NOTIFY musicFolderChanged)
    Q_PROPERTY(int currentIndex READ currentIndex NOTIFY currentChanged)
    Q_PROPERTY(QString formatInfo READ formatInfo NOTIFY currentChanged)
    Q_PROPERTY(QString coverUrl READ coverUrl NOTIFY currentChanged)
    Q_PROPERTY(int playbackState READ playbackState NOTIFY playbackStateChanged)
    Q_PROPERTY(qint64 position READ position NOTIFY positionChanged)
    Q_PROPERTY(qint64 duration READ duration NOTIFY durationChanged)
    Q_PROPERTY(bool shuffle READ shuffle WRITE setShuffle NOTIFY shuffleChanged)
    Q_PROPERTY(int repeatMode READ repeatMode WRITE setRepeatMode NOTIFY repeatModeChanged)
    Q_PROPERTY(qreal volume READ volume WRITE setVolume NOTIFY volumeChanged)
    Q_PROPERTY(QString queueInfo READ queueInfo NOTIFY queueChanged)
    Q_PROPERTY(QVariantList spectrum READ spectrum NOTIFY spectrumChanged)
    Q_PROPERTY(bool spectrumAvailable READ spectrumAvailable CONSTANT)
    Q_PROPERTY(bool blurAvailable READ blurAvailable NOTIFY blurAvailableChanged)
    Q_PROPERTY(bool blurSupported READ blurSupported CONSTANT)
    Q_PROPERTY(bool frostedGlass READ frostedGlass WRITE setFrostedGlass NOTIFY frostedGlassChanged)
    Q_PROPERTY(bool accentHeader READ accentHeader WRITE setAccentHeader NOTIFY accentHeaderChanged)
    Q_PROPERTY(bool resumeOnStart READ resumeOnStart WRITE setResumeOnStart NOTIFY resumeOnStartChanged)
    Q_PROPERTY(QColor titleBarColor READ titleBarColor NOTIFY titleBarColorChanged)
    Q_PROPERTY(bool hasTitleBarColor READ hasTitleBarColor NOTIFY titleBarColorChanged)
    Q_PROPERTY(QColor inactiveTitleBarColor READ inactiveTitleBarColor NOTIFY titleBarColorChanged)
    Q_PROPERTY(bool hasInactiveTitleBarColor READ hasInactiveTitleBarColor NOTIFY titleBarColorChanged)
    Q_PROPERTY(int vizStyle READ vizStyle WRITE setVizStyle NOTIFY vizStyleChanged)
    Q_PROPERTY(int spectrumBands READ spectrumBands WRITE setSpectrumBands NOTIFY spectrumBandsChanged)
    Q_PROPERTY(QColor accent READ accent NOTIFY accentChanged)
    Q_PROPERTY(QString message READ message NOTIFY messageChanged)
    Q_PROPERTY(int lastTab READ lastTab WRITE setLastTab NOTIFY lastTabChanged)
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QVariantList folders READ folders NOTIFY libraryChanged)
    Q_PROPERTY(QVariantList playlists READ playlists NOTIFY playlistsChanged)
    Q_PROPERTY(int appIcon READ appIcon WRITE setAppIcon NOTIFY appIconChanged)
    Q_PROPERTY(QVariantList appIcons READ appIcons CONSTANT)

public:
    explicit Player(QObject *parent = nullptr);
    ~Player() override;

    // Loads settings and starts the first library scan.
    void start();
    // The main window: used for KWin's blur-behind.
    void attachWindow(QQuickWindow *window);

    QVariantList songs() const { return m_songs; }
    QVariantList albums() const { return m_albums; }
    QVariantList artists() const { return m_artists; }
    QVariantList albumArtists() const { return m_albumArtists; }
    QVariantList genres() const { return m_genres; }
    int trackCount() const { return int(m_libraryCount); }
    QString librarySummary() const { return m_librarySummary; }
    bool scanning() const { return m_scanning; }
    int scanDone() const;
    int scanTotal() const;
    QString musicFolder() const { return m_musicFolder; }
    QString musicFolderLabel() const;
    int currentIndex() const { return m_current; }
    QString formatInfo() const;
    QString coverUrl() const;
    int playbackState() const;
    qint64 position() const;
    qint64 duration() const;
    bool shuffle() const { return m_shuffle; }
    void setShuffle(bool on);
    int repeatMode() const { return m_repeat; }
    void setRepeatMode(int mode);
    qreal volume() const { return m_volume; }
    void setVolume(qreal v);
    QString queueInfo() const { return m_queueInfo; }
    QVariantList spectrum() const { return m_spectrumList; }
    bool spectrumAvailable() const;
    // KWin can blur behind windows right now.
    bool blurAvailable() const { return m_blurAvailable; }
    // This build includes KF6 WindowSystem.
    bool blurSupported() const;
    // Experimental: the user turned the frosted-glass panel on.
    bool frostedGlass() const { return m_frosted; }
    void setFrostedGlass(bool on);
    // The player panel is tinted with the accent colour (the default look).
    bool accentHeader() const { return m_accentHeader; }
    void setAccentHeader(bool on);
    // Start playing the last song where it left off (otherwise it's just cued, paused).
    bool resumeOnStart() const { return m_resumeOnStart; }
    void setResumeOnStart(bool on);
    // Plasma's active title bar colour ([WM] activeBackground in kdeglobals).
    QColor titleBarColor() const { return m_titleBarColor; }
    bool hasTitleBarColor() const { return m_titleBarColor.isValid(); }
    // ... and the one for unfocused windows ([WM] inactiveBackground).
    QColor inactiveTitleBarColor() const { return m_inactiveTitleBarColor; }
    bool hasInactiveTitleBarColor() const { return m_inactiveTitleBarColor.isValid(); }
    // Visualizer: 0 = off, 1 = small box, 2 = seek bar, 3 = full panel.
    int vizStyle() const { return m_vizStyle; }
    void setVizStyle(int style);
    // How many bars the current visualizer draws (QML sets it).
    int spectrumBands() const { return m_bandCount; }
    void setSpectrumBands(int bands);
    QColor accent() const { return m_accent; }
    QString message() const { return m_message; }
    int lastTab() const { return m_lastTab; }
    void setLastTab(int tab);
    QString version() const;
    // [{name, path, parent, depth, total, cover, tracks, children, search}], root first
    QVariantList folders() const { return m_folderList; }
    // [{name, count, durationMs, meta}], sorted by name
    QVariantList playlists() const { return m_playlistList; }
    // App icon: 0 = A (bold outline), 1 = B (flat), 2 = C (tilted, the default).
    int appIcon() const { return m_appIcon; }
    void setAppIcon(int icon);
    // [{name, url}] for the Settings picker
    QVariantList appIcons() const;

    // Plays every song in library order (shuffled if asked).
    Q_INVOKABLE void playAll(bool shuffled);
    // Plays the given track indices, starting at position `startPos` in that list (-1 = top).
    Q_INVOKABLE void playList(const QVariantList &tracks, int startPos);
    // Plays the given tracks with shuffle turned on (e.g. a whole genre).
    Q_INVOKABLE void shuffleList(const QVariantList &tracks);
    // Plays an album, starting at track index `startTrack` (-1 = first track).
    Q_INVOKABLE void playAlbum(int album, int startTrack);
    Q_INVOKABLE void togglePlay();
    Q_INVOKABLE void stop();
    Q_INVOKABLE void next();
    Q_INVOKABLE void previous();
    Q_INVOKABLE void seek(qint64 ms);
    Q_INVOKABLE void cycleRepeat();
    Q_INVOKABLE void cycleVizStyle();
    Q_INVOKABLE void chooseMusicFolder();
    Q_INVOKABLE void rescan();
    // Deletes the saved library file, scans the music folder again and saves the result.
    Q_INVOKABLE void rebuildLibrary();
    // Inserts tracks right after the current song (or plays them if nothing is queued).
    Q_INVOKABLE void playNext(const QVariantList &tracks);
    // Shows the files in the file manager (Dolphin selects them).
    Q_INVOKABLE void showInFileManager(const QVariantList &tracks);
    Q_INVOKABLE void showFolderInFileManager(int folder);
    // Track indices in a folder, optionally including everything below it.
    Q_INVOKABLE QVariantList folderTracks(int folder, bool recursive) const;

    // Playlists (.m3u8 files in ~/.local/share/sasha/playlists).
    // Entries: [{track (index or -1 when the file isn't in the library), title, artist, album, time}]
    Q_INVOKABLE QVariantList playlistEntries(int playlist) const;
    Q_INVOKABLE QString uniquePlaylistName(const QString &base) const;
    // Returns the new playlist's index.
    Q_INVOKABLE int createPlaylist(const QString &name, const QVariantList &tracks);
    Q_INVOKABLE int renamePlaylist(int playlist, const QString &name);
    Q_INVOKABLE void deletePlaylist(int playlist);
    // Inserts tracks at `atRow` (-1 = at the end).
    Q_INVOKABLE void addToPlaylist(int playlist, const QVariantList &tracks, int atRow);
    Q_INVOKABLE void removeFromPlaylist(int playlist, const QVariantList &rows);
    // Moves the given rows so they start at `toRow` (a position in the list before the move).
    Q_INVOKABLE void moveInPlaylist(int playlist, const QVariantList &rows, int toRow);
    // Plays the playlist from `startRow`; `shuffled` turns shuffle on.
    Q_INVOKABLE void playPlaylist(int playlist, int startRow, bool shuffled);

    // The header's rectangle in window coordinates, for the blur.
    Q_INVOKABLE void setBlurRect(qreal x, qreal y, qreal w, qreal h);

    // Plays files, folders or .m3u playlists given on the command line or by a
    // file manager. Files outside the library are added to the queue anyway.
    void openFiles(const QStringList &paths);

public Q_SLOTS:
    // Called over D-Bus by a second launch (e.g. "Open with Sasha" in Dolphin).
    Q_SCRIPTABLE void Open(const QStringList &paths, const QString &activationToken);
    // Brings the window to the front.
    Q_SCRIPTABLE void Activate(const QString &activationToken);

signals:
    void libraryChanged();
    void scanningChanged();
    void scanProgressChanged();
    void musicFolderChanged();
    void currentChanged();
    void playbackStateChanged();
    void positionChanged();
    void durationChanged();
    void shuffleChanged();
    void repeatModeChanged();
    void volumeChanged();
    void queueChanged();
    void spectrumChanged();
    void blurAvailableChanged();
    void frostedGlassChanged();
    void accentHeaderChanged();
    void titleBarColorChanged();
    void vizStyleChanged();
    void spectrumBandsChanged();
    void accentChanged();
    void messageChanged();
    void lastTabChanged();
    void playlistsChanged();
    void appIconChanged();
    void resumeOnStartChanged();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    void onScanFinished();
    void loadLibrary(const QByteArray &blob);
    void applyLibrary(const QByteArray &blob);
    QString libraryFile() const;
    bool loadSavedLibrary();
    void saveLibrary(const QByteArray &blob) const;
    void saveResumeState() const;
    void restoreLastPlayed();
    void cueIndex(qint64 index, qint64 positionMs, bool play);
    void buildLists();
    void startQueue(const std::vector<uint32_t> &tracks, qint64 startPos, bool shuffled);
    void playIndex(qint64 index);
    void advance(bool user);
    void updateQueueInfo();
    void updateAccent();
    void updateTitleBarColor();
    void applyBlur();
    void setMessage(const QString &text);
    void tickSpectrum();
    void updateSpectrumTimer();
    void onAudioBuffer(const QAudioBuffer &buffer);
    void saveSettings() const;
    void loadPlaylists();
    void migrateFromTuneful();
    void applyAppIcon(bool syncFiles);
    void buildPlaylistList();
    bool savePlaylist(int playlist);
    QString playlistDir() const;
    int playlistIndexByName(const QString &name) const;
    std::vector<uint32_t> toTrackList(const QVariantList &tracks) const;
    QVariantMap songMap(const TrackInfo &t) const;
    QStringList expandOpenPaths(const QStringList &paths) const;
    int libraryIndexOf(const QString &path);
    int addExternal(const QString &path);
    void raiseWindow(const QString &activationToken);

    QMediaPlayer *m_player = nullptr;
    QAudioOutput *m_audio = nullptr;
    QAudioBufferOutput *m_bufferOutput = nullptr;
    QTimer *m_scanTimer = nullptr;
    QTimer *m_spectrumTimer = nullptr;
    QTimer *m_messageTimer = nullptr;
    QPointer<QQuickWindow> m_window;

    std::vector<TrackInfo> m_tracks;
    std::vector<AlbumInfo> m_albums2;
    QVariantList m_songs, m_albums, m_artists, m_albumArtists, m_genres;
    QString m_librarySummary;
    QString m_libraryRoot;                // the folder the library was scanned from
    QHash<QString, int> m_pathIndex;      // file path -> track index
    QHash<QString, int> m_canonicalIndex; // resolved path -> track index (built when first needed)
    size_t m_libraryCount = 0;            // m_tracks past this are opened files outside the library
    QStringList m_externals;              // those files, kept across rescans
    QStringList m_pendingOpen;            // files to open once the scan finishes
    std::vector<FolderInfo> m_folders;
    QVariantList m_folderList;
    std::vector<PlaylistInfo> m_playlists;
    QVariantList m_playlistList;
    int m_appIcon = 2;

    bool m_scanning = false;
    bool m_rescanPending = false;
    QString m_musicFolder;
    QString m_cacheDir;
    qint64 m_current = -1;
    int m_failStreak = 0;
    bool m_shuffle = false;
    int m_repeat = 0;
    qreal m_volume = 0.7;
    int m_lastTab = 4;
    QString m_queueInfo;
    QString m_message;
    QColor m_accent;
    QColor m_titleBarColor;
    QColor m_inactiveTitleBarColor;
    int m_vizStyle = 1;
    int m_bandCount = 24;
    QFileSystemWatcher *m_kdeglobalsWatcher = nullptr;

    bool m_blurAvailable = false;
    bool m_frosted = false;
    bool m_accentHeader = true;
    bool m_resumeOnStart = false;
    bool m_restored = false;      // the last-played song has been put back (once per run)
    qint64 m_pendingSeek = -1;    // position to seek to once the cued file has loaded
    QTimer *m_resumeTimer = nullptr;
    QRect m_blurRect;

    std::vector<float> m_samples;
    int m_sampleRate = 44100;
    std::vector<float> m_bands;
    QVariantList m_spectrumList;
};
