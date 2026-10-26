// Sasha's main window. Compiled into the binary; run with
// SASHA_QML=/path/to/qml/main.qml to load this file directly while tweaking.
//
// `player` is the C++ Player object (cpp/player.h).

import QtQuick
import QtQuick.Window
import QtQuick.Controls.Basic
import QtQuick.Templates as T

Window {
    id: win
    width: 1120
    height: 760
    minimumWidth: 880
    minimumHeight: 500
    visible: true
    color: "transparent"
    title: {
        var s = song(player.currentIndex)
        return s ? s.title + " — Sasha" : "Sasha"
    }

    // Library snapshot, read once per scan so delegates index plain JS arrays.
    property var songs: player.songs
    property var albums: player.albums
    property var spec: player.spectrum

    // Dark theme with the desktop's accent colour.
    readonly property color accent: player.accent
    readonly property color inkOnAccent: luminance(accent) > 0.55 ? "#0f1720" : "#ffffff"
    readonly property color ground: "#1b1d21"
    readonly property color panel: "#22252a"
    readonly property color raised: "#2c3138"
    readonly property color line: "#2e3238"
    readonly property color divider: "#262a2f"
    readonly property color rowAlt: "#1f2125"
    readonly property color textMain: "#e6e8eb"
    readonly property color textRow: "#d3d7dc"
    readonly property color textSoft: "#aab1bb"
    readonly property color textDim: "#8f97a3"
    readonly property color playingRow: Qt.rgba(accent.r, accent.g, accent.b, 0.22)

    // The player panel: accent-tinted by default, frosted glass when the
    // experimental setting is on and KWin can blur, plain dark otherwise.
    readonly property bool frosted: player.frostedGlass && player.blurAvailable
    readonly property bool tinted: !frosted && player.accentHeader
    // Tinted: Plasma's active title bar colour when we can read it, else the accent.
    // While the window is unfocused it follows the inactive title bar colour.
    readonly property color titleBarNow: (!win.active && player.hasInactiveTitleBarColor) ? player.inactiveTitleBarColor
                                                                                        : player.titleBarColor
    readonly property color tintColor: player.hasTitleBarColor ? titleBarNow
                                                               : Qt.tint(panel, Qt.rgba(accent.r, accent.g, accent.b, 0.38))
    readonly property color headerColor: frosted ? Qt.rgba(0.11, 0.12, 0.14, 0.55) : (tinted ? tintColor : panel)
    // Text and controls on the panel follow its brightness (light title bars exist too).
    readonly property bool headerLight: !frosted && luminance(headerColor) > 0.6
    readonly property color headerText: headerLight ? "#16181c" : "#ffffff"
    readonly property color headerSoft: headerLight ? "#3d434b" : Qt.rgba(1, 1, 1, 0.80)
    readonly property color headerDim: headerLight ? "#5c636c" : Qt.rgba(1, 1, 1, 0.60)
    readonly property color headerTrack: headerLight ? Qt.rgba(0, 0, 0, 0.16) : Qt.rgba(1, 1, 1, 0.20)
    readonly property color headerTrackStrong: headerLight ? Qt.rgba(0, 0, 0, 0.24) : Qt.rgba(1, 1, 1, 0.28)
    readonly property color headerWash: headerLight ? "#000000" : "#ffffff"
    // Accent used on top of the panel: shifted so it stands out against a tinted panel.
    readonly property color hiBase: tinted ? (headerLight ? Qt.darker(accent, 1.5) : Qt.lighter(accent, 1.5)) : accent
    // Softened while the window is in the background, like Breeze's inactive title bar buttons.
    readonly property color hiAccent: win.active ? hiBase : Qt.tint(hiBase, Qt.rgba(headerColor.r, headerColor.g, headerColor.b, 0.45))

    // Visualizer: 0 off, 1 small box, 2 seek bar, 3 full panel.
    readonly property int viz: player.spectrumAvailable ? player.vizStyle : 0
    readonly property int wantBands: viz === 2 ? Math.max(32, Math.min(140, Math.floor(seekBars.width / 9)))
                                               : (viz === 3 ? 64 : 24)
    readonly property color inkOnHi: luminance(hiAccent) > 0.55 ? "#0f1720" : "#ffffff"
    readonly property string mono: "monospace"

    property int tab: player.lastTab
    property string filter: ""
    property string sortKey: ""
    property bool sortAsc: true

    property var songRows: computeSongRows(songs, filter, sortKey, sortAsc)
    property var albumRows: filterRows(albums, filter)

    function luminance(c) { return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b }
    function song(i) { return (i >= 0 && i < songs.length) ? songs[i] : null }
    function setTab(i) {
        tab = i
        player.lastTab = i
        clearSel()
    }

    function fmt(ms) {
        if (!(ms > 0))
            return "0:00"
        var s = Math.floor(ms / 1000)
        var h = Math.floor(s / 3600)
        var m = Math.floor((s % 3600) / 60)
        var sec = s % 60
        return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (sec < 10 ? "0" : "") + sec
    }

    function filterRows(list, f) {
        var rows = []
        for (var i = 0; i < list.length; ++i)
            if (!list[i].external && (f === "" || list[i].search.indexOf(f) >= 0))
                rows.push(i)
        return rows
    }

    function computeSongRows(list, f, key, asc) {
        var rows = filterRows(list, f)
        if (key !== "") {
            var keyed = rows.map(function (i) {
                var v = list[i][key]
                return { i: i, v: (typeof v === "string") ? v.toLowerCase() : v }
            })
            keyed.sort(function (a, b) { return a.v < b.v ? -1 : (a.v > b.v ? 1 : a.i - b.i) })
            rows = keyed.map(function (k) { return k.i })
        }
        if (!asc)
            rows.reverse()
        return rows
    }

    function sortBy(key) {
        if (key === "") {
            sortKey = ""
            sortAsc = true
        } else if (sortKey === key) {
            sortAsc = !sortAsc
        } else {
            sortKey = key
            sortAsc = true
        }
    }

    function updateBlur() { player.setBlurRect(header.x, header.y, header.width, header.height) }

    // Mouse-wheel scrolling for lists whose rows can be dragged (those lists
    // turn off flicking so a drag moves songs instead of the list).
    function wheelScroll(view, event) {
        var dy = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y / 120 * 66
        var maxY = view.originY + Math.max(0, view.contentHeight - view.height)
        view.contentY = Math.max(view.originY, Math.min(maxY, view.contentY - dy))
    }

    // ---------------------------------------------------------- selection --
    // Selected track indices (as keys), the list they were picked from (so
    // Shift+click can select a range) and the anchor row in that list.
    readonly property color selectedRow: Qt.rgba(accent.r, accent.g, accent.b, 0.38)
    property var sel: ({})
    property int selCount: 0
    property var selList: []
    property int selAnchor: -1

    function clearSel() {
        sel = ({})
        selCount = 0
        selAnchor = -1
        selList = []
    }
    function clickSel(list, pos, mods) {
        var t = list[pos]
        var s
        if ((mods & Qt.ShiftModifier) && selList === list && selAnchor >= 0) {
            s = (mods & Qt.ControlModifier) ? Object.assign({}, sel) : ({})
            for (var i = Math.min(selAnchor, pos); i <= Math.max(selAnchor, pos); ++i)
                s[list[i]] = true
        } else if (mods & Qt.ControlModifier) {
            s = (selList === list) ? Object.assign({}, sel) : ({})
            if (s[t] === true)
                delete s[t]
            else
                s[t] = true
            selAnchor = pos
        } else {
            s = ({})
            s[t] = true
            selAnchor = pos
        }
        selList = list
        sel = s
        selCount = Object.keys(s).length
    }
    function selectAll(list) {
        var s = ({})
        for (var i = 0; i < list.length; ++i)
            s[list[i]] = true
        selList = list
        sel = s
        selCount = list.length
    }
    function selectedTracks() {
        var out = []
        for (var i = 0; i < selList.length; ++i)
            if (sel[selList[i]] === true)
                out.push(selList[i])
        return out
    }
    // What a right-click or drag acts on: the selection when the row is part
    // of it, otherwise just that row (which becomes the selection).
    function targetsFor(list, pos) {
        var t = list[pos]
        if (sel[t] === true && selList === list)
            return selectedTracks()
        clickSel(list, pos, 0)
        return [t]
    }

    // ----------------------------------------------------------- song menu --
    property var playlistModel: player.playlists
    property var menuTracks: []
    property int menuFolder: -1
    property int menuPlaylist: -1
    property var menuRows: []
    property int menuPlaylistTarget: -1
    readonly property string menuHeading: {
        if (menuFolder >= 0)
            return qsTr("Folder · %1 songs").arg(menuTracks.length)
        if (menuTracks.length === 1)
            return song(menuTracks[0]) ? song(menuTracks[0]).title : ""
        return qsTr("%1 songs selected").arg(menuTracks.length)
    }

    function openSongMenu(tracks) {
        menuTracks = tracks
        menuFolder = -1
        menuPlaylist = -1
        menuRows = []
        songMenu.removeAction(removeFromPlaylistAction)
        songMenu.popup()
    }
    function openPlaylistRowsMenu(playlist, rows, tracks) {
        menuTracks = tracks
        menuFolder = -1
        menuPlaylist = playlist
        menuRows = rows
        songMenu.removeAction(removeFromPlaylistAction)
        songMenu.addAction(removeFromPlaylistAction)
        songMenu.popup()
    }
    function openFolderMenu(folder) {
        menuTracks = player.folderTracks(folder, true)
        menuFolder = folder
        menuPlaylist = -1
        menuRows = []
        songMenu.removeAction(removeFromPlaylistAction)
        songMenu.popup()
    }

    // ------------------------------------------------------- new playlist --
    property var pendingTracks: []
    function askNewPlaylist(tracks) {
        pendingTracks = tracks
        newNameInput.text = player.uniquePlaylistName(qsTr("New playlist"))
        newPlaylistPopup.open()
        newNameInput.selectAll()
        newNameInput.forceActiveFocus()
    }
    function acceptNewPlaylist() {
        var i = player.createPlaylist(newNameInput.text, pendingTracks)
        newPlaylistPopup.close()
        pendingTracks = []
        if (i >= 0 && tab === 0)
            plPage.selected = i
    }

    // -------------------------------------------------------- drag & drop --
    // A drag carries track indices; dragging rows out of a playlist also
    // carries the playlist and its rows (to reorder, or remove when dropped
    // outside any list).
    property bool dragging: false
    property var dragTracks: []
    property int dragFromPlaylist: -1
    property var dragRows: []
    function startDrag(tracks, fromPlaylist, rows) {
        dragTracks = tracks
        dragFromPlaylist = fromPlaylist
        dragRows = rows
        dragging = true
    }
    function moveDrag(p) {
        dragGhost.x = p.x + 14
        dragGhost.y = p.y + 10
    }
    function endDrag() {
        if (!dragging)
            return
        var result = dragGhost.Drag.drop()
        if (result === Qt.IgnoreAction && dragFromPlaylist >= 0 && dragRows.length > 0)
            player.removeFromPlaylist(dragFromPlaylist, dragRows)
        dragging = false
        dragTracks = []
        dragRows = []
        dragFromPlaylist = -1
    }
    Component.onCompleted: updateBlur()

    Binding {
        target: player
        property: "spectrumBands"
        value: win.wantBands
    }

    Timer {
        id: filterTimer
        interval: 200
        onTriggered: win.filter = searchInput.text.trim().toLowerCase()
    }

    // Banner cover -> Albums tab, scrolled to the playing album, which glows briefly.
    property int flashAlbum: -1
    Timer {
        id: flashTimer
        interval: 1600
        onTriggered: win.flashAlbum = -1
    }
    function goToAlbum(ai) {
        if (ai === undefined || ai < 0 || ai >= albums.length)
            return
        if (albumRows.indexOf(ai) < 0) {  // hidden by the search: clear it
            searchInput.text = ""
            filterTimer.stop()
            filter = ""
        }
        setTab(4)
        flashAlbum = ai
        flashTimer.restart()
        Qt.callLater(function () {
            var row = albumRows.indexOf(ai)
            if (row >= 0)
                albumsView.positionViewAtIndex(row, ListView.Beginning)
        })
    }

    Shortcut { sequence: "Space"; onActivated: player.togglePlay() }
    Shortcut { sequence: "Ctrl+F"; onActivated: searchInput.forceActiveFocus() }
    Shortcut { sequence: "Ctrl+Right"; onActivated: player.next() }
    Shortcut { sequence: "Ctrl+Left"; onActivated: player.previous() }
    Shortcut { sequence: "Toggle Media Play/Pause"; onActivated: player.togglePlay() }
    Shortcut { sequence: "Media Play"; onActivated: player.togglePlay() }
    Shortcut { sequence: "Media Next"; onActivated: player.next() }
    Shortcut { sequence: "Media Previous"; onActivated: player.previous() }
    Shortcut { sequence: "Media Stop"; onActivated: player.stop() }
    Shortcut {
        sequence: StandardKey.SelectAll
        onActivated: {
            if (win.tab === 1)
                win.selectAll(win.songRows)
            else if (win.tab === 6)
                win.selectAll(fdPage.songList)
            else if (win.tab === 0)
                plPage.selectAllRows()
        }
    }
    Shortcut {
        sequence: StandardKey.Delete
        enabled: win.tab === 0
        onActivated: plPage.removeSelected()
    }

    // ================================================================ header ==
    // Matches the title bar by default; frosted glass when that experimental
    // setting is on; plain dark when tinting is turned off.
    Rectangle {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 176
        color: win.headerColor
        clip: true
        onWidthChanged: win.updateBlur()
        onHeightChanged: win.updateBlur()
        // Fade with the title bar when the window gains or loses focus.
        Behavior on color { ColorAnimation { duration: 150 } }

        // Full-panel visualizer, behind everything else in the panel.
        Row {
            id: fullViz
            visible: win.viz === 3
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            height: parent.height - 8
            spacing: 4
            opacity: 0.38
            readonly property int count: win.spec.length
            readonly property real barW: (width - spacing * (count - 1)) / Math.max(1, count)
            Repeater {
                model: fullViz.visible ? fullViz.count : 0
                Rectangle {
                    required property int index
                    width: fullViz.barW
                    height: Math.max(3, fullViz.height * (win.spec[index] || 0))
                    y: fullViz.height - height
                    radius: 2
                    color: win.hiAccent
                }
            }
        }

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: win.headerLight ? Qt.rgba(0, 0, 0, 0.10) : Qt.rgba(1, 1, 1, 0.08)
        }

        Rectangle {
            id: cover
            x: 20
            anchors.verticalCenter: parent.verticalCenter
            width: 136
            height: 136
            radius: 4
            color: win.headerLight ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(0, 0, 0, 0.25)
            clip: true
            Image {
                anchors.fill: parent
                source: player.coverUrl
                sourceSize.width: 272
                sourceSize.height: 272
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                visible: status === Image.Ready
            }
            Glyph {
                anchors.centerIn: parent
                width: 44
                height: 44
                kind: "note"
                tint: win.headerDim
                visible: player.coverUrl === ""
            }
            MouseArea {
                id: coverMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: win.song(player.currentIndex) !== null
                onClicked: {
                    var s = win.song(player.currentIndex)
                    if (s)
                        win.goToAlbum(s.albumIndex)
                }
            }
            ToolTip.visible: coverMouse.containsMouse && coverMouse.enabled
            ToolTip.delay: 900
            ToolTip.text: qsTr("Go to this album")
        }

        Item {
            id: info
            anchors.left: cover.right
            anchors.leftMargin: 20
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.top: parent.top
            anchors.topMargin: 18
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 16

            Column {
                anchors.left: parent.left
                anchors.right: spectrumBox.visible ? spectrumBox.left : parent.right
                anchors.rightMargin: 16
                spacing: 2
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    color: win.headerText
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                    text: {
                        var s = win.song(player.currentIndex)
                        if (s)
                            return s.title
                        return player.scanning ? qsTr("Scanning your music…") : qsTr("Nothing playing")
                    }
                }
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    color: win.headerSoft
                    font.pixelSize: 13
                    text: {
                        var s = win.song(player.currentIndex)
                        if (!s)
                            return player.trackCount > 0 ? qsTr("Double-click a song, or press Space to shuffle everything") : ""
                        return s.artist + " — " + s.album + (s.year !== "" ? " (" + s.year + ")" : "")
                    }
                }
                Item { width: 1; height: 4 }
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    color: win.headerDim
                    font.family: win.mono
                    font.pixelSize: 11
                    text: player.formatInfo
                }
            }

            Rectangle {
                id: spectrumBox
                visible: win.viz === 1 && info.width > 560
                anchors.right: parent.right
                anchors.top: parent.top
                width: 24 * 6 + 23 * 3 + 16
                height: 54
                radius: 4
                color: win.headerLight ? Qt.rgba(0, 0, 0, 0.08) : Qt.rgba(0, 0, 0, 0.25)
                Accessible.role: Accessible.Button
                Accessible.name: qsTr("Spectrum analyzer: change style")
                MouseArea {
                    id: spectrumMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: player.cycleVizStyle()
                }
                ToolTip.visible: spectrumMouse.containsMouse
                ToolTip.delay: 900
                ToolTip.text: qsTr("Click to change the visualizer style")
                Row {
                    x: 8
                    y: 6
                    height: 42
                    spacing: 3
                    Repeater {
                        model: 24
                        Rectangle {
                            required property int index
                            width: 6
                            radius: 1
                            height: Math.max(2, 42 * (win.spec.length > index ? win.spec[index] : 0))
                            y: 42 - height
                            color: win.hiAccent
                            opacity: height > 21 ? 1 : 0.75
                        }
                    }
                }
            }

            // seek bar (plain)
            Item {
                visible: win.viz !== 2
                anchors.left: parent.left
                anchors.right: parent.right
                y: 78
                height: 18
                Text {
                    id: elapsed
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(40, implicitWidth)
                    color: win.headerText
                    font.family: win.mono
                    font.pixelSize: 12
                    text: win.fmt(seekBar.dragging ? seekBar.dragValue * player.duration : player.position)
                }
                Bar {
                    id: seekBar
                    anchors.left: elapsed.right
                    anchors.leftMargin: 6
                    anchors.right: total.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    height: 16
                    value: player.duration > 0 ? player.position / player.duration : 0
                    fill: win.hiAccent
                    knob: win.headerText
                    trackColor: win.headerTrack
                    onMoved: (v) => player.seek(Math.round(v * player.duration))
                }
                Text {
                    id: total
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    color: win.headerSoft
                    font.family: win.mono
                    font.pixelSize: 12
                    text: win.fmt(player.duration)
                }
            }

            // seek bar (visualizer style): the bars are the seek bar
            Item {
                id: seekViz
                visible: win.viz === 2
                anchors.left: parent.left
                anchors.right: parent.right
                y: 66
                height: 30
                property real dragValue: 0
                Text {
                    id: elapsed2
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    width: Math.max(40, implicitWidth)
                    color: win.headerText
                    font.family: win.mono
                    font.pixelSize: 12
                    text: win.fmt(seekVizMouse.pressed ? seekViz.dragValue * player.duration : player.position)
                }
                Text {
                    id: total2
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    color: win.headerSoft
                    font.family: win.mono
                    font.pixelSize: 12
                    text: win.fmt(player.duration)
                }
                Item {
                    id: seekBars
                    anchors.left: elapsed2.right
                    anchors.leftMargin: 6
                    anchors.right: total2.left
                    anchors.rightMargin: 10
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    readonly property real progress: seekVizMouse.pressed ? seekViz.dragValue
                                                                          : (player.duration > 0 ? Math.min(1, player.position / player.duration) : 0)
                    Accessible.role: Accessible.Slider
                    Accessible.name: qsTr("Seek")
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 3
                        height: 2
                        radius: 1
                        color: win.headerTrack
                    }
                    Row {
                        id: seekBarRow
                        visible: player.playbackState === 1
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 3
                        height: 26
                        spacing: 3
                        readonly property int count: win.spec.length
                        readonly property real barW: (width - spacing * (count - 1)) / Math.max(1, count)
                        Repeater {
                            model: seekViz.visible ? seekBarRow.count : 0
                            Rectangle {
                                required property int index
                                width: seekBarRow.barW
                                height: Math.max(2, seekBarRow.height * (win.spec[index] || 0))
                                y: seekBarRow.height - height
                                radius: 1
                                color: (index + 0.5) / seekBarRow.count <= seekBars.progress ? win.hiAccent : win.headerTrackStrong
                            }
                        }
                    }
                    // playhead
                    Rectangle {
                        x: seekBars.width * seekBars.progress - 1
                        anchors.bottom: parent.bottom
                        width: 2
                        height: parent.height
                        radius: 1
                        color: win.headerText
                    }
                    MouseArea {
                        id: seekVizMouse
                        anchors.fill: parent
                        function at(mx) { return Math.max(0, Math.min(1, mx / width)) }
                        onPressed: (mouse) => { seekViz.dragValue = at(mouse.x) }
                        onPositionChanged: (mouse) => { if (pressed) seekViz.dragValue = at(mouse.x) }
                        onReleased: (mouse) => player.seek(Math.round(at(mouse.x) * player.duration))
                    }
                }
            }

            // transport, centred under the seek bar
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                height: 44
                spacing: 4
                IconButton {
                    y: 2; size: 40; kind: "prev"; tip: qsTr("Previous")
                    ink: win.headerText; wash: win.headerWash
                    onClicked: player.previous()
                }
                IconButton {
                    size: 44
                    kind: player.playbackState === 1 ? "pause" : "play"
                    tip: player.playbackState === 1 ? qsTr("Pause") : qsTr("Play")
                    primary: true
                    // over the full-panel bars, a solid button in the text colour reads best
                    accent: win.viz === 3 ? win.headerText : win.hiAccent
                    inkOnAccent: win.viz === 3 ? win.headerColor : win.inkOnHi
                    onClicked: player.togglePlay()
                }
                IconButton {
                    y: 2; size: 40; kind: "stop"; tip: qsTr("Stop")
                    ink: win.headerText; wash: win.headerWash
                    onClicked: player.stop()
                }
                IconButton {
                    y: 2; size: 40; kind: "next"; tip: qsTr("Next")
                    ink: win.headerText; wash: win.headerWash
                    onClicked: player.next()
                }
                Item {
                    width: 17
                    height: 44
                    Rectangle { x: 8; y: 11; width: 1; height: 22; color: win.headerTrack }
                }
                IconButton {
                    y: 4
                    kind: "shuffle"
                    tip: player.shuffle ? qsTr("Shuffle is on") : qsTr("Shuffle is off")
                    active: player.shuffle
                    ink: win.headerText; dimInk: win.headerDim; wash: win.headerWash
                    onClicked: player.shuffle = !player.shuffle
                }
                IconButton {
                    y: 4
                    kind: "repeat"
                    tip: [qsTr("Repeat is off"), qsTr("Repeating the queue"), qsTr("Repeating this song")][player.repeatMode]
                    active: player.repeatMode > 0
                    badge: player.repeatMode === 2 ? "1" : ""
                    ink: win.headerText; dimInk: win.headerDim; wash: win.headerWash
                    onClicked: player.cycleRepeat()
                }
            }

            // volume
            Row {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 44
                spacing: 8
                Glyph {
                    y: 13
                    width: 18
                    height: 18
                    kind: player.volume > 0 ? "volume" : "mute"
                    tint: win.headerSoft
                }
                Bar {
                    y: 14
                    width: 110
                    height: 16
                    trackHeight: 4
                    live: true
                    value: player.volume
                    fill: win.headerSoft
                    knob: win.headerText
                    trackColor: win.headerTrack
                    onMoved: (v) => player.volume = v
                    Accessible.name: qsTr("Volume")
                }
            }
        }
    }

    // ================================================================== body ==
    Rectangle {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        anchors.bottom: parent.bottom
        color: win.ground

        // ---- category tabs + search
        Item {
            id: tabBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 42

            // Tabs that don't fit move into the "More" menu at the end of the row.
            readonly property var tabNames: [qsTr("Playlists"), qsTr("All Songs"), qsTr("Artists"), qsTr("Album Artists"), qsTr("Albums"), qsTr("Genres"), qsTr("Folders")]
            FontMetrics { id: tabFm; font.pixelSize: 13 }
            function tabWidth(i) { return Math.ceil(tabFm.advanceWidth(tabNames[i])) + 28 }
            readonly property real moreWidth: Math.ceil(tabFm.advanceWidth(qsTr("More"))) + 28 + 16
            readonly property real rightUsed: searchBox.width + 12 + 16
                                              + (genreShuffle.visible ? genreShuffle.width + 12 : 0)
            readonly property int shownTabs: {
                var avail = width - 12 - rightUsed
                var n = tabNames.length
                var total = 0
                for (var i = 0; i < n; ++i)
                    total += tabWidth(i) + (i > 0 ? 2 : 0)
                if (total <= avail)
                    return n
                var used = moreWidth
                var k = 0
                while (k < n && used + tabWidth(k) + 2 <= avail) {
                    used += tabWidth(k) + 2
                    ++k
                }
                return k
            }

            Row {
                x: 12
                anchors.bottom: parent.bottom
                spacing: 2
                Repeater {
                    model: tabBar.tabNames
                    delegate: Rectangle {
                        id: tabItem
                        required property int index
                        required property string modelData
                        visible: index < tabBar.shownTabs
                        width: tabLabel.implicitWidth + 26
                        height: 34
                        radius: 4
                        color: win.tab === index ? win.panel : (tabMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.04) : "transparent")
                        Accessible.role: Accessible.PageTab
                        Accessible.name: modelData
                        Text {
                            id: tabLabel
                            anchors.centerIn: parent
                            anchors.verticalCenterOffset: -1
                            text: tabItem.modelData
                            color: win.tab === tabItem.index ? win.textMain : win.textDim
                            font.pixelSize: 13
                        }
                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 2
                            color: win.tab === tabItem.index ? win.accent : "transparent"
                        }
                        MouseArea {
                            id: tabMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: win.setTab(tabItem.index)
                        }
                        // Dragging songs over a tab opens it (e.g. Playlists).
                        DropArea {
                            anchors.fill: parent
                            keys: ["sasha-tracks"]
                            onEntered: tabHoverTimer.restart()
                            onExited: tabHoverTimer.stop()
                            onDropped: (drop) => drop.accept(Qt.CopyAction)
                        }
                        Timer {
                            id: tabHoverTimer
                            interval: 550
                            onTriggered: win.setTab(tabItem.index)
                        }
                    }
                }

                // "More": holds the tabs that didn't fit.
                Rectangle {
                    id: moreTab
                    readonly property bool holdsCurrent: win.tab >= tabBar.shownTabs
                    visible: tabBar.shownTabs < tabBar.tabNames.length
                    width: tabBar.moreWidth
                    height: 34
                    radius: 4
                    color: holdsCurrent ? win.panel : ((moreMouse.containsMouse || overflowMenu.visible) ? Qt.rgba(1, 1, 1, 0.04) : "transparent")
                    Accessible.role: Accessible.ButtonMenu
                    Accessible.name: qsTr("More categories")
                    Row {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -1
                        spacing: 4
                        Text {
                            id: moreLabel
                            text: qsTr("More")
                            color: moreTab.holdsCurrent ? win.textMain : win.textDim
                            font.pixelSize: 13
                        }
                        Glyph {
                            width: 12
                            height: 12
                            y: (moreLabel.height - height) / 2 + 1
                            kind: "chevron-down"
                            tint: moreTab.holdsCurrent ? win.textMain : win.textDim
                        }
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 2
                        color: moreTab.holdsCurrent ? win.accent : "transparent"
                    }
                    MouseArea {
                        id: moreMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: overflowMenu.visible ? overflowMenu.close() : overflowMenu.popup(moreTab, 0, moreTab.height + 2)
                    }
                    // Dragging songs over "More" opens the menu.
                    DropArea {
                        anchors.fill: parent
                        keys: ["sasha-tracks"]
                        onEntered: moreHoverTimer.restart()
                        onExited: moreHoverTimer.stop()
                        onDropped: (drop) => drop.accept(Qt.CopyAction)
                    }
                    Timer {
                        id: moreHoverTimer
                        interval: 550
                        onTriggered: if (!overflowMenu.visible) overflowMenu.popup(moreTab, 0, moreTab.height + 2)
                    }
                }
            }

            // Genres: shuffle every song in the chosen genre.
            PillButton {
                id: genreShuffle
                readonly property var genre: genresView.shown.length > genresView.selected
                                             ? genresView.shown[genresView.selected] : null
                visible: win.tab === 5 && genre !== null && player.trackCount > 0
                anchors.right: searchBox.left
                anchors.rightMargin: 12
                anchors.verticalCenter: searchBox.verticalCenter
                height: 32
                text: qsTr("Shuffle all")
                icon: "shuffle"
                primary: true
                accent: win.accent
                inkOnAccent: win.inkOnAccent
                onClicked: if (genre) player.shuffleList(genre.tracks)
                ToolTip.visible: genreHover.hovered
                ToolTip.delay: 700
                ToolTip.text: genre ? qsTr("Shuffle all %1 songs in %2").arg(genre.count).arg(genre.name) : ""
                HoverHandler { id: genreHover }
            }

            Rectangle {
                id: searchBox
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 6
                width: 200
                height: 28
                radius: 4
                color: "#24272c"
                border.width: searchInput.activeFocus ? 1 : 0
                border.color: win.accent
                Glyph {
                    x: 9
                    y: 7
                    width: 14
                    height: 14
                    kind: "search"
                    tint: win.textDim
                }
                TextInput {
                    id: searchInput
                    anchors.left: parent.left
                    anchors.leftMargin: 30
                    anchors.right: clearSearch.left
                    anchors.verticalCenter: parent.verticalCenter
                    color: win.textMain
                    selectionColor: win.accent
                    selectedTextColor: win.inkOnAccent
                    font.pixelSize: 13
                    clip: true
                    selectByMouse: true
                    Accessible.role: Accessible.EditableText
                    Accessible.name: qsTr("Search")
                    onTextChanged: filterTimer.restart()
                    Keys.onEscapePressed: { text = ""; focus = false }
                }
                Text {
                    anchors.left: searchInput.left
                    anchors.verticalCenter: parent.verticalCenter
                    visible: searchInput.text === "" && !searchInput.activeFocus
                    text: qsTr("Search")
                    color: win.textDim
                    font.pixelSize: 13
                }
                Item {
                    id: clearSearch
                    anchors.right: parent.right
                    width: searchInput.text === "" ? 6 : 26
                    height: parent.height
                    Glyph {
                        anchors.centerIn: parent
                        width: 12
                        height: 12
                        kind: "close"
                        tint: win.textDim
                        visible: searchInput.text !== ""
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: searchInput.text !== ""
                        onClicked: searchInput.text = ""
                    }
                }
            }

            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 1
                color: win.line
            }
        }

        // ---- pages
        Item {
            id: content
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: tabBar.bottom
            anchors.bottom: statusBar.top

            // Empty library / first scan
            Column {
                anchors.centerIn: parent
                spacing: 14
                visible: player.trackCount === 0 && win.tab !== 0
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    color: win.textSoft
                    font.pixelSize: 15
                    text: player.scanning ? qsTr("Scanning %1…").arg(player.musicFolderLabel)
                                          : qsTr("No music found in %1").arg(player.musicFolderLabel)
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: player.scanning && player.scanTotal > 0
                    color: win.textDim
                    font.family: win.mono
                    font.pixelSize: 12
                    text: player.scanDone + " / " + player.scanTotal
                }
                PillButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: !player.scanning
                    text: qsTr("Choose music folder…")
                    primary: true
                    accent: win.accent
                    inkOnAccent: win.inkOnAccent
                    onClicked: player.chooseMusicFolder()
                }
            }

            // ---- Playlists
            Item {
                id: plPage
                anchors.fill: parent
                visible: win.tab === 0

                property int selected: 0
                property var entries: []
                property var rowSel: ({})
                property int rowAnchor: -1
                property int renaming: -1
                property int dropRow: -1
                readonly property int count: win.playlistModel.length
                readonly property var info: (selected >= 0 && selected < count) ? win.playlistModel[selected] : null

                function refresh() {
                    entries = player.playlistEntries(selected)
                    rowSel = ({})
                    rowAnchor = -1
                }
                function rowsSelected() {
                    var out = []
                    for (var i = 0; i < entries.length; ++i)
                        if (rowSel[i] === true)
                            out.push(i)
                    return out
                }
                function tracksOfRows(rows) {
                    var out = []
                    for (var i = 0; i < rows.length; ++i) {
                        var e = entries[rows[i]]
                        if (e && e.track >= 0)
                            out.push(e.track)
                    }
                    return out
                }
                function clickRow(pos, mods) {
                    var s
                    if ((mods & Qt.ShiftModifier) && rowAnchor >= 0) {
                        s = (mods & Qt.ControlModifier) ? Object.assign({}, rowSel) : ({})
                        for (var i = Math.min(rowAnchor, pos); i <= Math.max(rowAnchor, pos); ++i)
                            s[i] = true
                    } else if (mods & Qt.ControlModifier) {
                        s = Object.assign({}, rowSel)
                        if (s[pos] === true)
                            delete s[pos]
                        else
                            s[pos] = true
                        rowAnchor = pos
                    } else {
                        s = ({})
                        s[pos] = true
                        rowAnchor = pos
                    }
                    rowSel = s
                }
                function targetRows(pos) {
                    if (rowSel[pos] === true)
                        return rowsSelected()
                    clickRow(pos, 0)
                    return [pos]
                }
                function selectAllRows() {
                    var s = ({})
                    for (var i = 0; i < entries.length; ++i)
                        s[i] = true
                    rowSel = s
                }
                function removeSelected() {
                    var rows = rowsSelected()
                    if (rows.length > 0)
                        player.removeFromPlaylist(selected, rows)
                }

                Connections {
                    target: player
                    function onPlaylistsChanged() {
                        var n = player.playlists.length
                        if (plPage.selected >= n)
                            plPage.selected = Math.max(0, n - 1)
                        plPage.refresh()
                    }
                    function onLibraryChanged() { plPage.refresh() }
                }
                onSelectedChanged: refresh()
                Component.onCompleted: refresh()

                // left: the playlists
                Item {
                    id: plLeft
                    width: 260
                    height: parent.height
                    Text {
                        x: 14
                        y: 12
                        text: qsTr("PLAYLISTS")
                        color: win.textDim
                        font.pixelSize: 11
                        font.letterSpacing: 0.6
                    }
                    ListView {
                        id: plNames
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.topMargin: 34
                        anchors.bottom: newPlBox.top
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: win.playlistModel
                        ScrollBar.vertical: ScrollBar { }
                        delegate: Rectangle {
                            id: plRow
                            required property int index
                            required property var modelData
                            readonly property bool chosen: plPage.selected === index
                            width: plNames.width
                            height: 34
                            color: plDrop.containsDrag ? Qt.rgba(win.accent.r, win.accent.g, win.accent.b, 0.30)
                                                       : (chosen ? win.panel : (plRowMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.04) : "transparent"))
                            Rectangle {
                                width: 2
                                height: parent.height
                                color: plRow.chosen ? win.accent : "transparent"
                            }
                            Glyph {
                                x: 14
                                y: 9
                                width: 16
                                height: 16
                                kind: "list"
                                tint: win.textDim
                            }
                            Text {
                                visible: plPage.renaming !== plRow.index
                                x: 40
                                width: parent.width - 40 - 52
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: plRow.modelData.name
                                color: plRow.chosen ? win.textMain : win.textRow
                                font.pixelSize: 13
                            }
                            Rectangle {
                                visible: plPage.renaming === plRow.index
                                x: 36
                                width: parent.width - 36 - 10
                                height: 26
                                anchors.verticalCenter: parent.verticalCenter
                                radius: 3
                                color: "#24272c"
                                border.width: 1
                                border.color: win.accent
                                TextInput {
                                    id: renameInput
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    verticalAlignment: TextInput.AlignVCenter
                                    color: win.textMain
                                    selectionColor: win.accent
                                    selectedTextColor: win.inkOnAccent
                                    font.pixelSize: 13
                                    clip: true
                                    selectByMouse: true
                                    onVisibleChanged: {
                                        if (visible) {
                                            text = plRow.modelData.name
                                            selectAll()
                                            forceActiveFocus()
                                        }
                                    }
                                    onAccepted: {
                                        var i = player.renamePlaylist(plRow.index, text)
                                        plPage.renaming = -1
                                        plPage.selected = i
                                    }
                                    onActiveFocusChanged: {
                                        if (!activeFocus && plPage.renaming === plRow.index)
                                            plPage.renaming = -1
                                    }
                                    Keys.onEscapePressed: plPage.renaming = -1
                                }
                            }
                            Text {
                                visible: plPage.renaming !== plRow.index
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                text: plRow.modelData.count
                                color: win.textDim
                                font.family: win.mono
                                font.pixelSize: 11
                            }
                            MouseArea {
                                id: plRowMouse
                                anchors.fill: parent
                                enabled: plPage.renaming !== plRow.index
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (mouse) => {
                                    plPage.selected = plRow.index
                                    if (mouse.button === Qt.RightButton) {
                                        win.menuPlaylistTarget = plRow.index
                                        playlistMenu.popup()
                                    }
                                }
                                onDoubleClicked: (mouse) => {
                                    if (mouse.button === Qt.LeftButton)
                                        plPage.renaming = plRow.index
                                }
                            }
                            DropArea {
                                id: plDrop
                                anchors.fill: parent
                                keys: ["sasha-tracks"]
                                onDropped: (drop) => {
                                    if (win.dragFromPlaylist !== plRow.index)
                                        player.addToPlaylist(plRow.index, win.dragTracks, -1)
                                    drop.accept(Qt.CopyAction)
                                }
                            }
                        }
                    }
                    Text {
                        visible: plPage.count === 0
                        x: 14
                        y: 44
                        width: parent.width - 28
                        wrapMode: Text.WordWrap
                        color: win.textDim
                        font.pixelSize: 13
                        text: qsTr("No playlists yet.")
                    }
                    Item {
                        id: newPlBox
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 58
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 1
                            color: win.divider
                        }
                        Rectangle {
                            x: 14
                            y: 12
                            width: parent.width - 28
                            height: 34
                            radius: 17
                            color: newPlMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent"
                            border.width: 1
                            border.color: "#4a4f57"
                            Accessible.role: Accessible.Button
                            Accessible.name: qsTr("New playlist")
                            Row {
                                anchors.centerIn: parent
                                spacing: 8
                                Glyph {
                                    y: 1
                                    width: 14
                                    height: 14
                                    kind: "plus"
                                    tint: win.textRow
                                }
                                Text {
                                    text: qsTr("New playlist")
                                    color: win.textRow
                                    font.pixelSize: 13
                                }
                            }
                            MouseArea {
                                id: newPlMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: win.askNewPlaylist([])
                            }
                        }
                    }
                }
                Rectangle {
                    x: 260
                    width: 1
                    height: parent.height
                    color: win.line
                }

                // right: the open playlist
                Item {
                    id: plRight
                    x: 261
                    width: parent.width - 261
                    height: parent.height

                    Text {
                        anchors.centerIn: parent
                        visible: plPage.info === null
                        horizontalAlignment: Text.AlignHCenter
                        color: win.textDim
                        font.pixelSize: 14
                        text: qsTr("Make a playlist with “New playlist”, or right-click songs\nanywhere and choose Add to playlist.")
                    }

                    Item {
                        id: plHead
                        visible: plPage.info !== null
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 64
                        Column {
                            x: 16
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 16 - plButtons.width - 28
                            spacing: 1
                            Text {
                                width: parent.width
                                elide: Text.ElideRight
                                text: plPage.info ? plPage.info.name : ""
                                color: win.textMain
                                font.pixelSize: 18
                                font.weight: Font.DemiBold
                            }
                            Text {
                                text: plPage.info ? plPage.info.meta : ""
                                color: win.textDim
                                font.pixelSize: 12
                            }
                        }
                        Row {
                            id: plButtons
                            anchors.right: parent.right
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10
                            PillButton {
                                text: qsTr("Play")
                                icon: "play"
                                primary: true
                                accent: win.accent
                                inkOnAccent: win.inkOnAccent
                                onClicked: player.playPlaylist(plPage.selected, -1, false)
                            }
                            PillButton {
                                text: qsTr("Shuffle")
                                icon: "shuffle"
                                onClicked: player.playPlaylist(plPage.selected, -1, true)
                            }
                        }
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 1
                            color: win.divider
                        }
                    }

                    Item {
                        id: plColumns
                        visible: plPage.info !== null
                        anchors.top: plHead.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 28
                        readonly property real avail: Math.max(200, width - 28 - 18 - 34 - 64 - 12 * 5)
                        Row {
                            x: 12
                            y: 7
                            spacing: 12
                            Item { width: 18; height: 14 }
                            Text { width: 34; horizontalAlignment: Text.AlignRight; text: "#"; color: win.textDim; font.pixelSize: 11 }
                            Text { width: plColumns.avail * 0.42; text: qsTr("TITLE"); color: win.textDim; font.pixelSize: 11; font.letterSpacing: 0.6 }
                            Text { width: plColumns.avail * 0.27; text: qsTr("ARTIST"); color: win.textDim; font.pixelSize: 11; font.letterSpacing: 0.6 }
                            Text { width: plColumns.avail * 0.31; text: qsTr("ALBUM"); color: win.textDim; font.pixelSize: 11; font.letterSpacing: 0.6 }
                            Text { width: 64; horizontalAlignment: Text.AlignRight; text: qsTr("TIME"); color: win.textDim; font.pixelSize: 11; font.letterSpacing: 0.6 }
                        }
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 1
                            color: win.divider
                        }
                    }

                    ListView {
                        id: plList
                        visible: plPage.info !== null
                        anchors.top: plColumns.bottom
                        anchors.bottom: plFoot.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        anchors.topMargin: 2
                        clip: true
                        interactive: false
                        model: plPage.entries
                        ScrollBar.vertical: ScrollBar { }
                        WheelHandler { onWheel: (event) => win.wheelScroll(plList, event) }
                        delegate: Rectangle {
                            id: plEntry
                            required property int index
                            required property var modelData
                            readonly property bool missing: modelData.track < 0
                            readonly property bool current: !missing && modelData.track === player.currentIndex
                            readonly property bool selected: plPage.rowSel[index] === true
                            width: plList.width
                            height: 28
                            radius: 3
                            opacity: win.dragging && win.dragFromPlaylist === plPage.selected && selected ? 0.45 : 1
                            color: selected ? win.selectedRow
                                            : (current ? win.playingRow : (plEntryMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : (index % 2 ? win.rowAlt : "transparent")))
                            Row {
                                x: 6
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 12
                                Glyph {
                                    y: 1
                                    width: 18
                                    height: 14
                                    kind: "grip"
                                    tint: "#6b727c"
                                }
                                Text {
                                    width: 34
                                    horizontalAlignment: Text.AlignRight
                                    text: plEntry.index + 1
                                    color: (plEntry.current || plEntry.selected) ? "#ffffff" : win.textDim
                                    font.family: win.mono
                                    font.pixelSize: 11
                                }
                                Text {
                                    width: plColumns.avail * 0.42
                                    elide: Text.ElideRight
                                    text: plEntry.modelData.title
                                    color: plEntry.missing ? win.textDim : ((plEntry.current || plEntry.selected) ? "#ffffff" : win.textRow)
                                    font.pixelSize: 13
                                    font.italic: plEntry.missing
                                    font.weight: plEntry.current ? Font.DemiBold : Font.Normal
                                }
                                Text {
                                    width: plColumns.avail * 0.27
                                    elide: Text.ElideRight
                                    text: plEntry.modelData.artist
                                    color: plEntry.selected ? "#f2e6eb" : win.textSoft
                                    font.pixelSize: 13
                                }
                                Text {
                                    width: plColumns.avail * 0.31
                                    elide: Text.ElideRight
                                    text: plEntry.modelData.album
                                    color: plEntry.missing ? win.textDim : (plEntry.selected ? "#f2e6eb" : win.textSoft)
                                    font.pixelSize: 13
                                    font.italic: plEntry.missing
                                }
                                Text {
                                    width: 64
                                    horizontalAlignment: Text.AlignRight
                                    text: plEntry.modelData.time
                                    color: (plEntry.current || plEntry.selected) ? "#ffffff" : win.textDim
                                    font.family: win.mono
                                    font.pixelSize: 12
                                }
                            }
                            MouseArea {
                                id: plEntryMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (mouse) => {
                                    if (mouse.button === Qt.RightButton) {
                                        var rows = plPage.targetRows(plEntry.index)
                                        win.openPlaylistRowsMenu(plPage.selected, rows, plPage.tracksOfRows(rows))
                                    } else {
                                        plPage.clickRow(plEntry.index, mouse.modifiers)
                                    }
                                }
                                onDoubleClicked: (mouse) => {
                                    if (mouse.button === Qt.LeftButton && !plEntry.missing)
                                        player.playPlaylist(plPage.selected, plEntry.index, false)
                                }
                            }
                            DragHandler {
                                target: null
                                acceptedButtons: Qt.LeftButton
                                onActiveChanged: {
                                    if (active) {
                                        var rows = plPage.targetRows(plEntry.index)
                                        win.startDrag(plPage.tracksOfRows(rows), plPage.selected, rows)
                                    } else {
                                        win.endDrag()
                                    }
                                }
                                onCentroidChanged: {
                                    if (active)
                                        win.moveDrag(centroid.scenePosition)
                                }
                            }
                        }
                    }

                    // where a dragged song will land
                    Rectangle {
                        visible: plListDrop.containsDrag && plPage.dropRow >= 0
                        x: plList.x + 4
                        width: plList.width - 8
                        height: 2
                        radius: 1
                        color: win.accent
                        y: plList.y + plPage.dropRow * 28 - (plList.contentY - plList.originY) - 1
                        Rectangle {
                            x: -3
                            y: -3
                            width: 8
                            height: 8
                            radius: 4
                            color: win.accent
                        }
                    }
                    DropArea {
                        id: plListDrop
                        enabled: plPage.info !== null
                        anchors.fill: plList
                        keys: ["sasha-tracks"]
                        function rowAt(y) {
                            return Math.max(0, Math.min(plPage.entries.length, Math.floor((y + plList.contentY - plList.originY + 14) / 28)))
                        }
                        onEntered: (drag) => { plPage.dropRow = rowAt(drag.y) }
                        onPositionChanged: (drag) => { plPage.dropRow = rowAt(drag.y) }
                        onExited: plPage.dropRow = -1
                        onDropped: (drop) => {
                            var at = rowAt(drop.y)
                            if (win.dragFromPlaylist === plPage.selected)
                                player.moveInPlaylist(plPage.selected, win.dragRows, at)
                            else
                                player.addToPlaylist(plPage.selected, win.dragTracks, at)
                            plPage.dropRow = -1
                            drop.accept(Qt.MoveAction)
                        }
                    }

                    Text {
                        anchors.centerIn: plList
                        visible: plPage.info !== null && plPage.entries.length === 0
                        horizontalAlignment: Text.AlignHCenter
                        color: win.textDim
                        font.pixelSize: 14
                        text: qsTr("This playlist is empty.\nDrag songs here from any tab, or right-click songs → Add to playlist.")
                    }

                    Item {
                        id: plFoot
                        visible: plPage.info !== null
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 30
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            height: 1
                            color: win.divider
                        }
                        Text {
                            x: 16
                            anchors.verticalCenter: parent.verticalCenter
                            color: win.textDim
                            font.pixelSize: 12
                            text: qsTr("Drag songs here from any tab · drag to reorder · Delete or drag out to remove")
                        }
                    }
                }
            }

            // ---- All Songs
            Item {
                id: songsPage
                anchors.fill: parent
                visible: win.tab === 1 && player.trackCount > 0

                Item {
                    id: actions
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: 60
                    Row {
                        x: 14
                        y: 12
                        height: 36
                        spacing: 14
                        PillButton {
                            text: qsTr("Shuffle all")
                            icon: "shuffle"
                            primary: true
                            accent: win.accent
                            inkOnAccent: win.inkOnAccent
                            onClicked: player.playAll(true)
                        }
                        Text {
                            y: 9
                            color: win.textDim
                            font.pixelSize: 13
                            text: win.filter === "" ? player.librarySummary
                                                    : qsTr("%1 of %2 songs match").arg(win.songRows.length).arg(player.trackCount)
                        }
                    }
                    Text {
                        anchors.right: parent.right
                        anchors.rightMargin: 16
                        y: 21
                        visible: win.selCount > 1
                        color: win.accent
                        font.pixelSize: 13
                        text: qsTr("%1 selected").arg(win.selCount)
                    }
                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        height: 1
                        color: win.divider
                    }
                }

                SongColumns {
                    id: songHeader
                    anchors.top: actions.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    app: win
                    sortable: true
                }

                ListView {
                    id: songList
                    anchors.top: songHeader.bottom
                    anchors.bottom: parent.bottom
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    clip: true
                    interactive: false
                    reuseItems: true
                    model: win.songRows
                    ScrollBar.vertical: ScrollBar { }
                    WheelHandler { onWheel: (event) => win.wheelScroll(songList, event) }
                    delegate: TrackRow {
                        required property int index
                        app: win
                        trackList: win.songRows
                        pos: index
                        avail: songHeader.avail
                        width: songList.width
                    }
                }
            }

            // ---- Artists / Album Artists / Albums / Genres
            NamedAlbums {
                anchors.fill: parent
                visible: win.tab === 2 && player.trackCount > 0
                app: win
                names: player.artists
            }
            NamedAlbums {
                anchors.fill: parent
                visible: win.tab === 3 && player.trackCount > 0
                app: win
                names: player.albumArtists
            }
            AlbumList {
                id: albumsView
                anchors.fill: parent
                visible: win.tab === 4 && player.trackCount > 0
                app: win
                rows: win.albumRows
            }
            NamedAlbums {
                id: genresView
                anchors.fill: parent
                visible: win.tab === 5 && player.trackCount > 0
                app: win
                names: player.genres
            }

            // ---- Folders
            Item {
                id: fdPage
                anchors.fill: parent
                visible: win.tab === 6 && player.trackCount > 0

                property var folders: player.folders
                property var expanded: ({ "0": true })
                property int current: 0
                readonly property var treeRows: computeTree(folders, expanded, win.filter)
                readonly property var info: (current >= 0 && current < folders.length) ? folders[current] : null
                // every song in the selected folder and below it, in tree order
                readonly property var songList: info ? player.folderTracks(current, true) : []
                readonly property var crumbs: {
                    var out = []
                    for (var i = current; i >= 0 && i < folders.length; i = folders[i].parent)
                        out.unshift(i)
                    return out
                }
                onFoldersChanged: {
                    if (current >= folders.length)
                        current = 0
                }

                function toggle(i) {
                    var e = Object.assign({}, expanded)
                    e[i] = !(e[i] === true)
                    expanded = e
                }
                function open(i) {
                    current = i
                    var e = Object.assign({}, expanded)
                    for (var p = folders[i].parent; p >= 0; p = folders[p].parent)
                        e[p] = true
                    expanded = e
                }
                function computeTree(list, open, f) {
                    var rows = []
                    if (list.length === 0)
                        return rows
                    var keep = null
                    if (f !== "") {
                        keep = {}
                        for (var i = 0; i < list.length; ++i) {
                            var hit = list[i].search.indexOf(f) >= 0
                            var ts = list[i].tracks
                            for (var k = 0; k < ts.length && !hit; ++k)
                                hit = win.songs[ts[k]].search.indexOf(f) >= 0
                            if (hit)
                                for (var p = i; p >= 0 && keep[p] !== true; p = list[p].parent)
                                    keep[p] = true
                        }
                    }
                    var walk = function (n) {
                        if (keep !== null && keep[n] !== true)
                            return
                        rows.push(n)
                        if (keep !== null || open[n] === true) {
                            var c = list[n].children
                            for (var j = 0; j < c.length; ++j)
                                walk(c[j])
                        }
                    }
                    walk(0)
                    return rows
                }
                function playFolder(i, shuffled) {
                    if (shuffled)
                        player.shuffle = true
                    player.playList(player.folderTracks(i, true), shuffled ? -1 : 0)
                }

                // left: the tree
                ListView {
                    id: tree
                    width: 300
                    height: parent.height
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    model: fdPage.treeRows
                    topMargin: 6
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Rectangle {
                        id: treeRow
                        required property int modelData
                        readonly property var f: fdPage.folders[modelData]
                        readonly property bool chosen: fdPage.current === modelData
                        readonly property bool hasKids: f.children.length > 0
                        readonly property bool isOpen: win.filter !== "" || fdPage.expanded[modelData] === true
                        width: tree.width
                        height: 30
                        color: chosen ? win.panel : (treeMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.04) : "transparent")
                        Rectangle {
                            width: 2
                            height: parent.height
                            color: treeRow.chosen ? win.accent : "transparent"
                        }
                        MouseArea {
                            id: treeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            onClicked: (mouse) => {
                                fdPage.current = treeRow.modelData
                                if (mouse.button === Qt.RightButton)
                                    win.openFolderMenu(treeRow.modelData)
                            }
                            onDoubleClicked: (mouse) => {
                                if (mouse.button === Qt.LeftButton)
                                    fdPage.playFolder(treeRow.modelData, false)
                            }
                        }
                        Item {
                            id: chevron
                            x: 8 + treeRow.f.depth * 16
                            width: 20
                            height: parent.height
                            Glyph {
                                anchors.centerIn: parent
                                width: 12
                                height: 12
                                visible: treeRow.hasKids
                                kind: treeRow.isOpen ? "chevron-down" : "chevron-right"
                                tint: win.textDim
                            }
                            MouseArea {
                                anchors.fill: parent
                                enabled: treeRow.hasKids && win.filter === ""
                                onClicked: fdPage.toggle(treeRow.modelData)
                            }
                        }
                        Glyph {
                            anchors.left: chevron.right
                            anchors.leftMargin: 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 16
                            height: 16
                            kind: "folder"
                            tint: treeRow.chosen ? win.accent : win.textDim
                        }
                        Text {
                            anchors.left: chevron.right
                            anchors.leftMargin: 24
                            anchors.right: treeCount.left
                            anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            text: treeRow.f.name
                            color: treeRow.chosen ? win.textMain : win.textRow
                            font.pixelSize: 13
                        }
                        Text {
                            id: treeCount
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            text: treeRow.f.total
                            color: win.textDim
                            font.family: win.mono
                            font.pixelSize: 11
                        }
                    }
                }
                Rectangle {
                    x: 300
                    width: 1
                    height: parent.height
                    color: win.line
                }

                // right: what's in the folder
                Item {
                    x: 301
                    width: parent.width - 301
                    height: parent.height

                    Item {
                        id: fdHead
                        anchors.left: parent.left
                        anchors.right: parent.right
                        height: 64
                        Column {
                            x: 16
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - 16 - fdButtons.width - 28
                            spacing: 3
                            Row {
                                spacing: 6
                                Repeater {
                                    model: fdPage.crumbs
                                    delegate: Row {
                                        id: crumb
                                        required property int index
                                        required property int modelData
                                        readonly property bool last: index === fdPage.crumbs.length - 1
                                        spacing: 6
                                        Text {
                                            visible: crumb.index > 0
                                            text: "›"
                                            color: win.textDim
                                            font.pixelSize: crumb.last ? 18 : 13
                                        }
                                        Text {
                                            text: fdPage.folders[crumb.modelData] ? fdPage.folders[crumb.modelData].name : ""
                                            color: crumb.last ? win.textMain : (crumbMouse.containsMouse ? win.textMain : win.textDim)
                                            font.pixelSize: crumb.last ? 18 : 13
                                            font.weight: crumb.last ? Font.DemiBold : Font.Normal
                                            MouseArea {
                                                id: crumbMouse
                                                anchors.fill: parent
                                                enabled: !crumb.last
                                                hoverEnabled: true
                                                onClicked: fdPage.open(crumb.modelData)
                                            }
                                        }
                                    }
                                }
                            }
                            Text {
                                color: win.textDim
                                font.pixelSize: 12
                                text: {
                                    if (!fdPage.info)
                                        return ""
                                    var parts = [qsTr("%1 songs").arg(fdPage.info.total)]
                                    if (fdPage.info.children.length > 0)
                                        parts.push(qsTr("%1 folders").arg(fdPage.info.children.length))
                                    return parts.join(" · ")
                                }
                            }
                        }
                        Row {
                            id: fdButtons
                            anchors.right: parent.right
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 10
                            PillButton {
                                text: qsTr("Play")
                                icon: "play"
                                primary: true
                                accent: win.accent
                                inkOnAccent: win.inkOnAccent
                                onClicked: fdPage.playFolder(fdPage.current, false)
                            }
                            PillButton {
                                text: qsTr("Shuffle")
                                icon: "shuffle"
                                onClicked: fdPage.playFolder(fdPage.current, true)
                            }
                        }
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 1
                            color: win.divider
                        }
                    }

                    SongColumns {
                        id: fdColumns
                        anchors.top: fdHead.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        app: win
                        sortable: false
                    }

                    ListView {
                        id: fdList
                        anchors.top: fdColumns.bottom
                        anchors.bottom: parent.bottom
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        clip: true
                        interactive: false
                        model: fdPage.songList.length
                        ScrollBar.vertical: ScrollBar { }
                        WheelHandler { onWheel: (event) => win.wheelScroll(fdList, event) }
                        delegate: TrackRow {
                            required property int index
                            app: win
                            trackList: fdPage.songList
                            pos: index
                            avail: fdColumns.avail
                            width: fdList.width
                        }
                    }
                }
            }
        }

        // ---- status bar
        Rectangle {
            id: statusBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 28
            color: "#16181b"
            Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                height: 1
                color: "#2a2d33"
            }
            Text {
                x: 14
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - statusLinks.width - 44
                elide: Text.ElideRight
                font.pixelSize: 12
                color: player.message !== "" ? "#f0b35a" : win.textDim
                text: {
                    if (player.message !== "")
                        return player.message
                    if (player.scanning)
                        return qsTr("Scanning… %1 of %2 files").arg(player.scanDone).arg(player.scanTotal)
                    return player.queueInfo !== "" ? player.queueInfo : player.librarySummary
                }
            }
            Row {
                id: statusLinks
                anchors.right: parent.right
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                spacing: 16
                Text {
                    text: qsTr("Music: %1").arg(player.musicFolderLabel)
                    width: Math.min(implicitWidth, 340)
                    elide: Text.ElideMiddle
                    font.pixelSize: 12
                    color: folderMouse.containsMouse ? win.textMain : win.textDim
                    MouseArea {
                        id: folderMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: player.chooseMusicFolder()
                    }
                    ToolTip.visible: folderMouse.containsMouse
                    ToolTip.delay: 700
                    ToolTip.text: qsTr("Choose a different music folder")
                }
                Text {
                    visible: !player.scanning
                    text: qsTr("Rescan & Rebuild Library")
                    font.pixelSize: 12
                    color: rescanMouse.containsMouse ? win.textMain : win.textDim
                    MouseArea {
                        id: rescanMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: player.rebuildLibrary()
                    }
                    ToolTip.visible: rescanMouse.containsMouse
                    ToolTip.delay: 700
                    ToolTip.text: qsTr("Sasha starts from a saved copy of your library. Use this after you edit tags or add music.")
                }
                Text {
                    text: qsTr("Settings")
                    font.pixelSize: 12
                    color: settingsMouse.containsMouse ? win.textMain : win.textDim
                    MouseArea {
                        id: settingsMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: settingsPopup.open()
                    }
                }
            }
        }
    }

    // ============================================================== settings ==
    Popup {
        id: settingsPopup
        modal: true
        focus: true
        width: 440
        x: Math.round((win.width - width) / 2)
        y: Math.round((win.height - height) / 2)
        padding: 22
        background: Rectangle {
            color: win.panel
            radius: 8
            border.width: 1
            border.color: win.line
        }
        contentItem: Column {
            spacing: 18
            Text {
                text: qsTr("Settings")
                color: win.textMain
                font.pixelSize: 16
                font.weight: Font.DemiBold
            }
            SettingRow {
                title: qsTr("Color the player panel to match the title bar")
                note: win.frosted ? qsTr("Not used while the frosted-glass panel is on.")
                                  : qsTr("Uses your Plasma title bar color, or your accent color when that isn't available.")
                checked: player.accentHeader
                accent: win.accent
                enabled: !win.frosted
                onToggled: player.accentHeader = !player.accentHeader
            }
            SettingRow {
                title: qsTr("Resume playback when Sasha starts")
                note: qsTr("Sasha always reopens on the last song you played, paused where you left off. Turn this on to have it keep playing.")
                checked: player.resumeOnStart
                accent: win.accent
                onToggled: player.resumeOnStart = !player.resumeOnStart
            }
            SettingRow {
                title: qsTr("Frosted-glass player panel (experimental)")
                note: {
                    if (!player.blurSupported)
                        return qsTr("This build doesn't include KF6 WindowSystem, which the blur needs.")
                    if (!player.blurAvailable)
                        return qsTr("Turn on Blur in System Settings → Window Management → Desktop Effects to use this.")
                    return qsTr("Uses KWin's blur. The panel can turn see-through for a moment while the window moves.")
                }
                checked: player.frostedGlass
                accent: win.accent
                enabled: player.blurSupported
                onToggled: player.frostedGlass = !player.frostedGlass
            }
            Column {
                width: parent.width
                spacing: 8
                Text {
                    text: qsTr("Visualizer")
                    color: "#e6e8eb"
                    font.pixelSize: 13
                }
                Row {
                    spacing: 8
                    enabled: player.spectrumAvailable
                    opacity: enabled ? 1 : 0.45
                    Repeater {
                        model: [qsTr("Off"), qsTr("Small"), qsTr("Seek bar"), qsTr("Full panel")]
                        delegate: PillButton {
                            required property int index
                            required property string modelData
                            text: modelData
                            primary: player.vizStyle === index
                            accent: win.accent
                            inkOnAccent: win.inkOnAccent
                            onClicked: player.vizStyle = index
                        }
                    }
                }
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: "#8f97a3"
                    font.pixelSize: 11
                    text: player.spectrumAvailable ? qsTr("Tip: click the small visualizer to switch styles.")
                                                   : qsTr("The visualizer needs Qt 6.8 or newer.")
                }
            }
            Column {
                width: parent.width
                spacing: 8
                Text {
                    text: qsTr("App icon")
                    color: "#e6e8eb"
                    font.pixelSize: 13
                }
                Row {
                    spacing: 12
                    Repeater {
                        model: player.appIcons
                        delegate: Item {
                            id: iconChoice
                            required property int index
                            required property var modelData
                            readonly property bool chosen: player.appIcon === index
                            width: 76
                            height: 92
                            Accessible.role: Accessible.RadioButton
                            Accessible.name: modelData.name
                            Accessible.checked: chosen
                            Rectangle {
                                width: 76
                                height: 76
                                radius: 12
                                color: iconChoice.chosen ? Qt.rgba(win.accent.r, win.accent.g, win.accent.b, 0.18)
                                                         : (iconMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent")
                                border.width: iconChoice.chosen ? 2 : 1
                                border.color: iconChoice.chosen ? win.accent : "#3a3f47"
                                Image {
                                    anchors.centerIn: parent
                                    width: 56
                                    height: 56
                                    sourceSize.width: 112
                                    sourceSize.height: 112
                                    source: iconChoice.modelData.url
                                }
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                anchors.bottom: parent.bottom
                                text: iconChoice.modelData.name
                                color: iconChoice.chosen ? "#e6e8eb" : "#8f97a3"
                                font.pixelSize: 11
                            }
                            MouseArea {
                                id: iconMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: player.appIcon = iconChoice.index
                            }
                        }
                    }
                }
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    color: "#8f97a3"
                    font.pixelSize: 11
                    text: qsTr("The app menu and task manager may keep the old icon until Plasma refreshes.")
                }
            }
            Item {
                width: parent.width
                height: 36
                PillButton {
                    anchors.right: parent.right
                    text: qsTr("Done")
                    primary: true
                    accent: win.accent
                    inkOnAccent: win.inkOnAccent
                    onClicked: settingsPopup.close()
                }
            }
        }
    }

    // ================================================================ menus ==
    Component {
        id: menuItemDelegate
        MenuItem {
            id: mi
            implicitWidth: 240
            implicitHeight: 30
            leftPadding: 10
            rightPadding: 24
            indicator: Item {}
            arrow: Text {
                x: mi.width - width - 10
                y: (mi.height - height) / 2
                visible: mi.subMenu !== null
                text: "›"
                color: mi.highlighted ? win.inkOnAccent : win.textDim
                font.pixelSize: 16
            }
            contentItem: Text {
                text: mi.text
                color: !mi.enabled ? win.textDim : (mi.highlighted ? win.inkOnAccent : win.textMain)
                font.pixelSize: mi.enabled ? 13 : 11
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
            }
            background: Rectangle {
                implicitWidth: 240
                implicitHeight: 30
                radius: 4
                color: (mi.highlighted && mi.enabled) ? win.accent : "transparent"
            }
        }
    }

    T.Action {
        id: removeFromPlaylistAction
        text: qsTr("Remove from playlist")
        onTriggered: player.removeFromPlaylist(win.menuPlaylist, win.menuRows)
    }

    // Category tabs that don't fit in the tab row.
    Menu {
        id: overflowMenu
        delegate: menuItemDelegate
        padding: 4
        background: Rectangle {
            implicitWidth: 200
            color: "#2a2e32"
            border.width: 1
            border.color: "#3a3f45"
            radius: 6
        }
        Instantiator {
            model: tabBar.tabNames.length - tabBar.shownTabs
            delegate: T.Action {
                required property int index
                readonly property int tabIndex: tabBar.shownTabs + index
                text: (win.tab === tabIndex ? "● " : "") + tabBar.tabNames[tabIndex]
                onTriggered: win.setTab(tabIndex)
            }
            onObjectAdded: (index, object) => overflowMenu.insertAction(index, object)
            onObjectRemoved: (index, object) => overflowMenu.removeAction(object)
        }
    }

    Menu {
        id: songMenu
        delegate: menuItemDelegate
        padding: 4
        background: Rectangle {
            implicitWidth: 248
            color: "#2a2e32"
            border.width: 1
            border.color: "#3a3f45"
            radius: 6
        }
        T.Action { text: win.menuHeading; enabled: false }
        MenuSeparator {
            contentItem: Rectangle { implicitHeight: 1; color: "#3a3f45" }
        }
        T.Action {
            text: qsTr("Play")
            onTriggered: player.playList(win.menuTracks, 0)
        }
        T.Action {
            text: qsTr("Play next")
            onTriggered: player.playNext(win.menuTracks)
        }
        MenuSeparator {
            contentItem: Rectangle { implicitHeight: 1; color: "#3a3f45" }
        }
        Menu {
            id: addMenu
            title: qsTr("Add to playlist")
            delegate: menuItemDelegate
            padding: 4
            background: Rectangle {
                implicitWidth: 230
                color: "#2a2e32"
                border.width: 1
                border.color: "#3a3f45"
                radius: 6
            }
            Instantiator {
                model: win.playlistModel
                delegate: T.Action {
                    required property int index
                    required property var modelData
                    text: modelData.name + "  (" + modelData.count + ")"
                    onTriggered: player.addToPlaylist(index, win.menuTracks, -1)
                }
                onObjectAdded: (index, object) => addMenu.insertAction(index, object)
                onObjectRemoved: (index, object) => addMenu.removeAction(object)
            }
            MenuSeparator {
                contentItem: Rectangle { implicitHeight: 1; color: "#3a3f45" }
            }
            T.Action {
                text: qsTr("New playlist…")
                onTriggered: win.askNewPlaylist(win.menuTracks)
            }
        }
        MenuSeparator {
            contentItem: Rectangle { implicitHeight: 1; color: "#3a3f45" }
        }
        T.Action {
            text: win.menuFolder >= 0 ? qsTr("Open in file manager") : qsTr("Open file location")
            onTriggered: {
                if (win.menuFolder >= 0)
                    player.showFolderInFileManager(win.menuFolder)
                else
                    player.showInFileManager(win.menuTracks)
            }
        }
    }

    // Right-click on a playlist name.
    Menu {
        id: playlistMenu
        delegate: menuItemDelegate
        padding: 4
        background: Rectangle {
            implicitWidth: 200
            color: "#2a2e32"
            border.width: 1
            border.color: "#3a3f45"
            radius: 6
        }
        T.Action {
            text: qsTr("Play")
            onTriggered: player.playPlaylist(win.menuPlaylistTarget, -1, false)
        }
        T.Action {
            text: qsTr("Shuffle")
            onTriggered: player.playPlaylist(win.menuPlaylistTarget, -1, true)
        }
        MenuSeparator {
            contentItem: Rectangle { implicitHeight: 1; color: "#3a3f45" }
        }
        T.Action {
            text: qsTr("Rename")
            onTriggered: plPage.renaming = win.menuPlaylistTarget
        }
        T.Action {
            text: qsTr("Delete (move to trash)")
            onTriggered: player.deletePlaylist(win.menuPlaylistTarget)
        }
    }

    Popup {
        id: newPlaylistPopup
        modal: true
        focus: true
        width: 380
        x: Math.round((win.width - width) / 2)
        y: Math.round((win.height - height) / 2)
        padding: 22
        background: Rectangle {
            color: win.panel
            radius: 8
            border.width: 1
            border.color: win.line
        }
        contentItem: Column {
            spacing: 16
            Text {
                text: win.pendingTracks.length > 0 ? qsTr("New playlist with %1 songs").arg(win.pendingTracks.length)
                                                   : qsTr("New playlist")
                color: win.textMain
                font.pixelSize: 16
                font.weight: Font.DemiBold
            }
            Rectangle {
                width: parent.width
                height: 32
                radius: 4
                color: "#24272c"
                border.width: 1
                border.color: newNameInput.activeFocus ? win.accent : win.line
                TextInput {
                    id: newNameInput
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: win.textMain
                    selectionColor: win.accent
                    selectedTextColor: win.inkOnAccent
                    font.pixelSize: 14
                    clip: true
                    selectByMouse: true
                    Accessible.role: Accessible.EditableText
                    Accessible.name: qsTr("Playlist name")
                    onAccepted: win.acceptNewPlaylist()
                    Keys.onEscapePressed: newPlaylistPopup.close()
                }
            }
            Item {
                width: parent.width
                height: 36
                Row {
                    anchors.right: parent.right
                    spacing: 10
                    PillButton {
                        text: qsTr("Cancel")
                        onClicked: newPlaylistPopup.close()
                    }
                    PillButton {
                        text: qsTr("Create")
                        primary: true
                        accent: win.accent
                        inkOnAccent: win.inkOnAccent
                        onClicked: win.acceptNewPlaylist()
                    }
                }
            }
        }
    }

    // What follows the pointer while songs are dragged.
    Rectangle {
        id: dragGhost
        visible: win.dragging
        z: 1000
        width: Math.min(320, ghostText.implicitWidth + 28)
        height: 30
        radius: 15
        color: win.accent
        Drag.active: win.dragging
        Drag.keys: ["sasha-tracks"]
        Drag.hotSpot.x: -14
        Drag.hotSpot.y: -10
        Text {
            id: ghostText
            anchors.centerIn: parent
            width: Math.min(implicitWidth, 292)
            elide: Text.ElideRight
            color: win.inkOnAccent
            font.pixelSize: 13
            font.weight: Font.DemiBold
            text: {
                if (win.dragTracks.length === 1 && win.song(win.dragTracks[0]))
                    return win.song(win.dragTracks[0]).title
                return qsTr("%1 songs").arg(win.dragTracks.length)
            }
        }
    }

    // ============================================================ components ==

    // Line icons drawn on an 18×18 grid.
    component Glyph: Canvas {
        id: glyph
        property string kind: "play"
        property color tint: "#e6e8eb"
        implicitWidth: 18
        implicitHeight: 18
        onKindChanged: requestPaint()
        onTintChanged: requestPaint()
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            var c = getContext("2d")
            c.reset()
            if (width <= 0 || height <= 0)
                return
            c.save()
            c.scale(width / 18, height / 18)
            c.strokeStyle = String(tint)
            c.fillStyle = String(tint)
            c.lineWidth = 1.6
            c.lineCap = "round"
            c.lineJoin = "round"
            c.beginPath()
            switch (kind) {
            case "play":
                c.moveTo(5, 3); c.lineTo(15, 9); c.lineTo(5, 15); c.closePath(); c.fill()
                break
            case "pause":
                c.lineWidth = 2.4
                c.moveTo(6, 4); c.lineTo(6, 14); c.moveTo(12, 4); c.lineTo(12, 14); c.stroke()
                break
            case "stop":
                c.rect(4, 4, 10, 10); c.stroke()
                break
            case "prev":
                c.moveTo(4, 3); c.lineTo(4, 15); c.stroke()
                c.beginPath(); c.moveTo(15, 3); c.lineTo(6, 9); c.lineTo(15, 15); c.closePath(); c.stroke()
                break
            case "next":
                c.moveTo(14, 3); c.lineTo(14, 15); c.stroke()
                c.beginPath(); c.moveTo(3, 3); c.lineTo(12, 9); c.lineTo(3, 15); c.closePath(); c.stroke()
                break
            case "shuffle":
                c.lineWidth = 1.4
                c.moveTo(2, 5); c.lineTo(5, 5); c.lineTo(11, 13); c.lineTo(15, 13)
                c.moveTo(2, 13); c.lineTo(5, 13); c.lineTo(11, 5); c.lineTo(15, 5)
                c.moveTo(13, 3); c.lineTo(15, 5); c.lineTo(13, 7)
                c.moveTo(13, 11); c.lineTo(15, 13); c.lineTo(13, 15)
                c.stroke()
                break
            case "repeat":
                c.lineWidth = 1.4
                c.moveTo(3, 8); c.lineTo(3, 6); c.lineTo(14, 6)
                c.moveTo(12, 4); c.lineTo(14, 6); c.lineTo(12, 8)
                c.moveTo(15, 10); c.lineTo(15, 12); c.lineTo(4, 12)
                c.moveTo(6, 10); c.lineTo(4, 12); c.lineTo(6, 14)
                c.stroke()
                break
            case "volume":
            case "mute":
                c.lineWidth = 1.4
                c.moveTo(2, 7); c.lineTo(5, 7); c.lineTo(9, 4); c.lineTo(9, 14); c.lineTo(5, 11); c.lineTo(2, 11); c.closePath(); c.stroke()
                c.beginPath()
                if (kind === "volume") {
                    c.arc(9, 9, 4, -0.9, 0.9, false); c.stroke()
                    c.beginPath(); c.arc(9, 9, 7, -0.9, 0.9, false); c.stroke()
                } else {
                    c.moveTo(12, 7); c.lineTo(16, 11); c.moveTo(16, 7); c.lineTo(12, 11); c.stroke()
                }
                break
            case "search":
                c.lineWidth = 1.5
                c.arc(7.5, 7.5, 5, 0, 2 * Math.PI, false); c.stroke()
                c.beginPath(); c.moveTo(11.5, 11.5); c.lineTo(16, 16); c.stroke()
                break
            case "close":
                c.moveTo(4, 4); c.lineTo(14, 14); c.moveTo(14, 4); c.lineTo(4, 14); c.stroke()
                break
            case "chevron-right":
                c.moveTo(7, 4); c.lineTo(12, 9); c.lineTo(7, 14); c.stroke()
                break
            case "chevron-down":
                c.moveTo(4, 7); c.lineTo(9, 12); c.lineTo(14, 7); c.stroke()
                break
            case "folder":
                c.lineWidth = 1.4
                c.moveTo(2, 5); c.lineTo(2, 15); c.lineTo(16, 15); c.lineTo(16, 6); c.lineTo(8.5, 6); c.lineTo(7, 4); c.lineTo(3, 4); c.closePath(); c.stroke()
                break
            case "list":
                c.lineWidth = 1.4
                c.moveTo(2, 5); c.lineTo(12, 5); c.moveTo(2, 9); c.lineTo(12, 9); c.moveTo(2, 13); c.lineTo(9, 13)
                c.moveTo(15, 9); c.lineTo(15, 15); c.stroke()
                c.beginPath(); c.arc(13.5, 15, 1.8, 0, 2 * Math.PI, false); c.fill()
                break
            case "plus":
                c.moveTo(9, 3); c.lineTo(9, 15); c.moveTo(3, 9); c.lineTo(15, 9); c.stroke()
                break
            case "grip":
                for (var gy = 4; gy <= 14; gy += 5) {
                    c.beginPath(); c.arc(7, gy, 1.3, 0, 2 * Math.PI, false); c.fill()
                    c.beginPath(); c.arc(11, gy, 1.3, 0, 2 * Math.PI, false); c.fill()
                }
                break
            case "note":
                c.lineWidth = 1.5
                c.moveTo(7.5, 13.5); c.lineTo(7.5, 3.5); c.lineTo(14.5, 2); c.lineTo(14.5, 12); c.stroke()
                c.beginPath(); c.arc(5.5, 13.5, 2.2, 0, 2 * Math.PI, false); c.fill()
                c.beginPath(); c.arc(12.5, 12, 2.2, 0, 2 * Math.PI, false); c.fill()
                break
            }
            c.restore()
        }
    }

    component IconButton: Item {
        id: ib
        property string kind: "play"
        property string tip: ""
        property bool active: false
        property bool primary: false
        property int size: 36
        property color accent: "#3daee9"
        property color inkOnAccent: "#0f1720"
        // icon colour, the dimmer colour for a toggle that is off, and the
        // base colour of the hover/active highlight
        property color ink: "#e6e8eb"
        property color dimInk: "#8f97a3"
        property color wash: "#ffffff"
        property string badge: ""
        // shuffle and repeat are toggles: dimmed while off
        readonly property bool toggle: kind === "shuffle" || kind === "repeat"
        signal clicked()
        width: size
        height: size
        Accessible.role: Accessible.Button
        Accessible.name: tip
        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: ib.primary ? (ibMouse.pressed ? Qt.darker(ib.accent, 1.15) : ib.accent)
                              : (ib.active ? Qt.rgba(ib.wash.r, ib.wash.g, ib.wash.b, 0.18)
                                           : (ibMouse.containsMouse ? Qt.rgba(ib.wash.r, ib.wash.g, ib.wash.b, 0.09) : "transparent"))
        }
        Glyph {
            anchors.centerIn: parent
            width: 18
            height: 18
            kind: ib.kind
            tint: ib.primary ? ib.inkOnAccent : ((ib.toggle && !ib.active) ? ib.dimInk : ib.ink)
        }
        Text {
            visible: ib.badge !== ""
            text: ib.badge
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: 6
            anchors.topMargin: 4
            font.pixelSize: 9
            font.bold: true
            color: ib.ink
        }
        MouseArea {
            id: ibMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: ib.clicked()
        }
        ToolTip.visible: tip !== "" && ibMouse.containsMouse
        ToolTip.delay: 700
        ToolTip.text: tip
    }

    component PillButton: Item {
        id: pb
        property string text: ""
        property string icon: ""
        property bool primary: false
        property color accent: "#3daee9"
        property color inkOnAccent: "#0f1720"
        signal clicked()
        width: pbRow.implicitWidth + 32
        height: 36
        Accessible.role: Accessible.Button
        Accessible.name: text
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: pb.primary ? (pbMouse.pressed ? Qt.darker(pb.accent, 1.15) : pb.accent)
                              : (pbMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.06) : "transparent")
            border.width: pb.primary ? 0 : 1
            border.color: "#3a3f47"
        }
        Row {
            id: pbRow
            anchors.centerIn: parent
            spacing: 8
            Glyph {
                visible: pb.icon !== ""
                width: 16
                height: 16
                y: (pbLabel.height - height) / 2
                kind: pb.icon
                tint: pb.primary ? pb.inkOnAccent : "#d3d7dc"
            }
            Text {
                id: pbLabel
                text: pb.text
                color: pb.primary ? pb.inkOnAccent : "#d3d7dc"
                font.pixelSize: 13
                font.weight: pb.primary ? Font.DemiBold : Font.Normal
            }
        }
        MouseArea {
            id: pbMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: pb.clicked()
        }
    }

    // Column headings for song lists (All Songs, Folders).
    component SongColumns: Item {
        id: sc
        required property var app
        property bool sortable: false
        // width shared by the title / artist / album columns
        readonly property real avail: Math.max(200, width - 28 - 44 - 60 - 64 - 12 * 5)
        height: 30
        Row {
            x: 14
            y: 8
            spacing: 12
            Repeater {
                model: [
                    { label: "#", key: "", w: 44, right: true },
                    { label: qsTr("TITLE"), key: "title", w: -0.42, right: false },
                    { label: qsTr("ARTIST"), key: "artist", w: -0.27, right: false },
                    { label: qsTr("ALBUM"), key: "album", w: -0.31, right: false },
                    { label: qsTr("YEAR"), key: "year", w: 60, right: false },
                    { label: qsTr("TIME"), key: "durationMs", w: 64, right: true }
                ]
                delegate: Item {
                    id: hc
                    required property var modelData
                    readonly property bool sorted: sc.sortable && modelData.key !== "" && sc.app.sortKey === modelData.key
                    width: modelData.w > 0 ? modelData.w : sc.avail * -modelData.w
                    height: 16
                    Text {
                        anchors.fill: parent
                        horizontalAlignment: hc.modelData.right ? Text.AlignRight : Text.AlignLeft
                        elide: Text.ElideRight
                        color: hc.sorted ? "#e6e8eb" : "#8f97a3"
                        font.pixelSize: 11
                        font.letterSpacing: 0.6
                        text: hc.modelData.label + (hc.sorted ? (sc.app.sortAsc ? "  ▲" : "  ▼") : "")
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: sc.sortable
                        onClicked: sc.app.sortBy(hc.modelData.key)
                    }
                }
            }
        }
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: 1
            color: "#262a2f"
        }
    }

    // One song in a list: click / Ctrl+click / Shift+click select, right-click
    // opens the song menu, double-click plays the list from here, drag adds
    // the song (or the selection) to a playlist.
    component TrackRow: Rectangle {
        id: tr
        required property var app
        required property var trackList   // track indices of the whole list
        required property int pos    // this row's position in `trackList`
        property real avail: 400     // shared width of the title / artist / album columns
        readonly property int track: (pos >= 0 && pos < trackList.length) ? trackList[pos] : -1
        readonly property var s: track >= 0 ? app.songs[track] : null
        readonly property bool current: track >= 0 && track === player.currentIndex
        readonly property bool selected: track >= 0 && app.sel[track] === true
        height: 26
        radius: 3
        color: selected ? app.selectedRow
                        : (current ? app.playingRow : (rowMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : (pos % 2 ? app.rowAlt : "transparent")))
        Row {
            x: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 12
            Text {
                width: 44
                horizontalAlignment: Text.AlignRight
                text: tr.pos + 1
                color: (tr.current || tr.selected) ? "#ffffff" : "#8f97a3"
                font.family: "monospace"
                font.pixelSize: 11
            }
            Text {
                width: tr.avail * 0.42
                elide: Text.ElideRight
                text: tr.s ? tr.s.title : ""
                color: (tr.current || tr.selected) ? "#ffffff" : "#d3d7dc"
                font.pixelSize: 13
                font.weight: tr.current ? Font.DemiBold : Font.Normal
            }
            Text {
                width: tr.avail * 0.27
                elide: Text.ElideRight
                text: tr.s ? tr.s.artist : ""
                color: tr.selected ? "#f2e6eb" : "#aab1bb"
                font.pixelSize: 13
            }
            Text {
                width: tr.avail * 0.31
                elide: Text.ElideRight
                text: tr.s ? tr.s.album : ""
                color: tr.selected ? "#f2e6eb" : "#aab1bb"
                font.pixelSize: 13
            }
            Text {
                width: 60
                text: tr.s ? tr.s.year : ""
                color: tr.selected ? "#f2e6eb" : "#aab1bb"
                font.family: "monospace"
                font.pixelSize: 12
            }
            Text {
                width: 64
                horizontalAlignment: Text.AlignRight
                text: tr.s ? tr.s.time : ""
                color: (tr.current || tr.selected) ? "#ffffff" : "#8f97a3"
                font.family: "monospace"
                font.pixelSize: 12
            }
        }
        MouseArea {
            id: rowMouse
            anchors.fill: parent
            enabled: tr.track >= 0
            hoverEnabled: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: (mouse) => {
                if (mouse.button === Qt.RightButton)
                    tr.app.openSongMenu(tr.app.targetsFor(tr.trackList, tr.pos))
                else
                    tr.app.clickSel(tr.trackList, tr.pos, mouse.modifiers)
            }
            onDoubleClicked: (mouse) => {
                if (mouse.button === Qt.LeftButton)
                    player.playList(tr.trackList, tr.pos)
            }
        }
        DragHandler {
            target: null
            enabled: tr.track >= 0
            acceptedButtons: Qt.LeftButton
            onActiveChanged: {
                if (active)
                    tr.app.startDrag(tr.app.targetsFor(tr.trackList, tr.pos), -1, [])
                else
                    tr.app.endDrag()
            }
            onCentroidChanged: {
                if (active)
                    tr.app.moveDrag(centroid.scenePosition)
            }
        }
    }

    // A labelled on/off switch for the settings panel.
    component SettingRow: Item {
        id: sr
        property string title: ""
        property string note: ""
        property bool checked: false
        property color accent: "#3daee9"
        signal toggled()
        width: parent ? parent.width : 380
        height: Math.max(srText.height, 22) + 2
        opacity: enabled ? 1 : 0.45
        Accessible.role: Accessible.CheckBox
        Accessible.name: title
        Accessible.checked: checked
        Column {
            id: srText
            anchors.left: parent.left
            anchors.right: srSwitch.left
            anchors.rightMargin: 16
            spacing: 3
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                text: sr.title
                color: "#e6e8eb"
                font.pixelSize: 13
            }
            Text {
                width: parent.width
                wrapMode: Text.WordWrap
                visible: sr.note !== ""
                text: sr.note
                color: "#8f97a3"
                font.pixelSize: 11
            }
        }
        Rectangle {
            id: srSwitch
            anchors.right: parent.right
            y: 1
            width: 40
            height: 22
            radius: 11
            color: sr.checked ? sr.accent : "#3a3f47"
            Rectangle {
                y: 3
                x: sr.checked ? parent.width - width - 3 : 3
                width: 16
                height: 16
                radius: 8
                color: "#ffffff"
                Behavior on x { NumberAnimation { duration: 120 } }
            }
        }
        MouseArea {
            anchors.fill: parent
            onClicked: sr.toggled()
        }
    }

    // A horizontal slider: `moved` fires on release, or while dragging when `live`.
    component Bar: Item {
        id: bar
        property real value: 0
        property color fill: "#3daee9"
        property color knob: "#e6e8eb"
        property int trackHeight: 6
        property bool live: false
        property color trackColor: "#343840"
        property real dragValue: 0
        readonly property bool dragging: barMouse.pressed
        readonly property real shown: Math.max(0, Math.min(1, dragging ? dragValue : value))
        signal moved(real v)
        implicitHeight: 16
        Accessible.role: Accessible.Slider
        Rectangle {
            id: barTrack
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: bar.trackHeight
            radius: height / 2
            color: bar.trackColor
            Rectangle {
                width: parent.width * bar.shown
                height: parent.height
                radius: parent.radius
                color: bar.fill
            }
        }
        Rectangle {
            visible: barMouse.containsMouse || bar.dragging
            anchors.verticalCenter: parent.verticalCenter
            x: barTrack.width * bar.shown - 7
            width: 14
            height: 14
            radius: 7
            color: bar.knob
        }
        MouseArea {
            id: barMouse
            anchors.fill: parent
            hoverEnabled: true
            function at(mx) { return Math.max(0, Math.min(1, mx / width)) }
            onPressed: (mouse) => {
                bar.dragValue = at(mouse.x)
                if (bar.live)
                    bar.moved(bar.dragValue)
            }
            onPositionChanged: (mouse) => {
                if (!pressed)
                    return
                bar.dragValue = at(mouse.x)
                if (bar.live)
                    bar.moved(bar.dragValue)
            }
            onReleased: (mouse) => bar.moved(at(mouse.x))
        }
    }

    // Albums with their cover art and track lists. `rows` are album indices.
    component AlbumList: ListView {
        id: al
        property var app
        property var rows: []
        model: rows
        clip: true
        interactive: false
        cacheBuffer: 600
        ScrollBar.vertical: ScrollBar { }
        WheelHandler { onWheel: (event) => al.app.wheelScroll(al, event) }
        delegate: Item {
            id: albumItem
            required property int modelData
            readonly property var a: al.app.albums[modelData]
            width: al.width
            height: Math.max(84, albumHead.height + trackCol.height) + 24

            Rectangle {  // glow after jumping here from the banner cover
                anchors.fill: parent
                color: al.app.accent
                opacity: al.app.flashAlbum === albumItem.modelData ? 0.16 : 0
                Behavior on opacity { NumberAnimation { duration: 450 } }
            }
            Rectangle {
                anchors.bottom: parent.bottom
                width: parent.width
                height: 1
                color: al.app.divider
            }
            Rectangle {
                x: 14
                y: 12
                width: 84
                height: 84
                radius: 3
                color: al.app.raised
                clip: true
                Image {
                    anchors.fill: parent
                    source: albumItem.a ? albumItem.a.cover : ""
                    sourceSize.width: 168
                    sourceSize.height: 168
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    visible: status === Image.Ready
                }
                Glyph {
                    anchors.centerIn: parent
                    width: 28
                    height: 28
                    kind: "note"
                    tint: al.app.textDim
                    visible: !albumItem.a || albumItem.a.cover === ""
                }
                MouseArea {
                    id: artMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onDoubleClicked: player.playAlbum(albumItem.modelData, -1)
                }
                ToolTip.visible: artMouse.containsMouse
                ToolTip.delay: 900
                ToolTip.text: qsTr("Double-click to play the album")
            }
            Column {
                x: 112
                y: 12
                width: parent.width - 112 - 14
                Item {
                    id: albumHead
                    width: parent.width
                    height: 26
                    Text {
                        id: albumTitle
                        width: Math.min(implicitWidth, parent.width - albumMeta.implicitWidth - albumSub.implicitWidth - 30)
                        elide: Text.ElideRight
                        text: albumItem.a ? albumItem.a.artist + " — " + albumItem.a.title : ""
                        color: al.app.textMain
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }
                    Text {
                        id: albumSub
                        anchors.left: albumTitle.right
                        anchors.leftMargin: 10
                        anchors.baseline: albumTitle.baseline
                        color: al.app.textDim
                        font.pixelSize: 13
                        text: albumItem.a ? [albumItem.a.year, albumItem.a.genre].filter(function (x) { return x !== "" }).join(" · ") : ""
                    }
                    Text {
                        id: albumMeta
                        anchors.right: parent.right
                        anchors.baseline: albumTitle.baseline
                        color: al.app.textDim
                        font.family: al.app.mono
                        font.pixelSize: 11
                        text: albumItem.a ? albumItem.a.meta : ""
                    }
                }
                Column {
                    id: trackCol
                    width: parent.width
                    Repeater {
                        model: albumItem.a ? albumItem.a.tracks : []
                        delegate: Rectangle {
                            id: trackRow
                            required property int index
                            required property int modelData
                            readonly property var t: al.app.songs[modelData]
                            readonly property bool current: modelData === player.currentIndex
                            readonly property bool selected: al.app.sel[modelData] === true
                            width: trackCol.width
                            height: 24
                            radius: 3
                            color: selected ? al.app.selectedRow
                                            : (current ? al.app.playingRow : (trackMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.05) : "transparent"))
                            Text {
                                x: 4
                                width: 22
                                anchors.verticalCenter: parent.verticalCenter
                                horizontalAlignment: Text.AlignRight
                                text: (trackRow.t && trackRow.t.track > 0) ? (trackRow.t.track < 10 ? "0" + trackRow.t.track : "" + trackRow.t.track) : ""
                                color: trackRow.current ? "#ffffff" : al.app.textDim
                                font.family: al.app.mono
                                font.pixelSize: 11
                            }
                            Text {
                                x: 38
                                width: parent.width - 38 - 70
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: {
                                    if (!trackRow.t)
                                        return ""
                                    var various = albumItem.a && albumItem.a.artist !== trackRow.t.artist
                                    return trackRow.t.title + (various ? "  ·  " + trackRow.t.artist : "")
                                }
                                color: trackRow.current ? "#ffffff" : al.app.textRow
                                font.pixelSize: 13
                                font.weight: trackRow.current ? Font.DemiBold : Font.Normal
                            }
                            Text {
                                anchors.right: parent.right
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                text: trackRow.t ? trackRow.t.time : ""
                                color: trackRow.current ? "#ffffff" : al.app.textDim
                                font.family: al.app.mono
                                font.pixelSize: 12
                            }
                            MouseArea {
                                id: trackMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                onClicked: (mouse) => {
                                    if (mouse.button === Qt.RightButton)
                                        al.app.openSongMenu(al.app.targetsFor(albumItem.a.tracks, trackRow.index))
                                    else
                                        al.app.clickSel(albumItem.a.tracks, trackRow.index, mouse.modifiers)
                                }
                                onDoubleClicked: (mouse) => {
                                    if (mouse.button === Qt.LeftButton)
                                        player.playAlbum(albumItem.modelData, trackRow.modelData)
                                }
                            }
                            DragHandler {
                                target: null
                                acceptedButtons: Qt.LeftButton
                                onActiveChanged: {
                                    if (active)
                                        al.app.startDrag(al.app.targetsFor(albumItem.a.tracks, trackRow.index), -1, [])
                                    else
                                        al.app.endDrag()
                                }
                                onCentroidChanged: {
                                    if (active)
                                        al.app.moveDrag(centroid.scenePosition)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // A list of names (artists, genres...) beside the albums of the selected one.
    component NamedAlbums: Item {
        id: na
        property var app
        property var names: []
        property int selected: 0
        readonly property var shown: {
            var f = app ? app.filter : ""
            var out = []
            for (var i = 0; i < names.length; ++i)
                if (f === "" || names[i].search.indexOf(f) >= 0)
                    out.push(names[i])
            return out
        }
        onShownChanged: if (selected >= shown.length) selected = 0

        ListView {
            id: nameList
            width: 250
            height: parent.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: na.shown
            ScrollBar.vertical: ScrollBar { }
            delegate: Rectangle {
                id: nameRow
                required property int index
                required property var modelData
                readonly property bool chosen: na.selected === index
                width: nameList.width
                height: 32
                color: chosen ? na.app.panel : (nameMouse.containsMouse ? Qt.rgba(1, 1, 1, 0.04) : "transparent")
                Rectangle {
                    width: 2
                    height: parent.height
                    color: nameRow.chosen ? na.app.accent : "transparent"
                }
                Text {
                    x: 14
                    width: parent.width - 70
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: nameRow.modelData.name
                    color: nameRow.chosen ? na.app.textMain : na.app.textRow
                    font.pixelSize: 13
                }
                Text {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    text: nameRow.modelData.count
                    color: na.app.textDim
                    font.family: na.app.mono
                    font.pixelSize: 11
                }
                MouseArea {
                    id: nameMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: na.selected = nameRow.index
                    onDoubleClicked: player.playList(nameRow.modelData.tracks, -1)
                }
            }
        }
        Rectangle {
            x: 250
            width: 1
            height: parent.height
            color: "#2e3238"
        }
        AlbumList {
            x: 251
            width: parent.width - 251
            height: parent.height
            app: na.app
            rows: na.shown.length > na.selected ? na.shown[na.selected].albums : []
        }
    }
}
