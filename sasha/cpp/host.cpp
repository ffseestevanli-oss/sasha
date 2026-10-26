// The Qt host: creates the application, the Player object and the QML window.
// Called from Rust's main() with the QML source compiled into the binary.

#include "player.h"

#include <QApplication>
#include <QByteArray>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QFileInfo>
#include <QStringList>
#include <QFile>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QString>
#include <QUrl>

#include <cstddef>
#include <cstdio>

extern "C" int tn_host_main(int argc, char **argv, const char *qml, size_t qmlLen)
{
    // The window is partly translucent so KWin can blur behind the header.
    QQuickWindow::setDefaultAlphaBuffer(true);

    QApplication app(argc, argv);
    QApplication::setOrganizationName(QStringLiteral("sasha"));
    QApplication::setApplicationName(QStringLiteral("sasha"));
    QApplication::setApplicationDisplayName(QStringLiteral("Sasha"));
    QApplication::setApplicationVersion(QStringLiteral(TN_VERSION));
    // Wayland app id; matches sasha.desktop so the taskbar shows the right icon.
    QApplication::setDesktopFileName(QStringLiteral("sasha"));

    const QString besideBinary = QCoreApplication::applicationDirPath() + QStringLiteral("/sasha.svg");
    const QString inSource = QString::fromUtf8(TN_ASSET_DIR "/sasha.svg");
    if (QFile::exists(besideBinary))
        QApplication::setWindowIcon(QIcon(besideBinary));
    else
        QApplication::setWindowIcon(QIcon::fromTheme(QStringLiteral("sasha"), QIcon(inSource)));

    // Files to play: from the command line, or from Dolphin via the launcher's %F.
    QStringList files;
    const QStringList args = QApplication::arguments().mid(1);
    for (const QString &a : args) {
        if (a.startsWith(QLatin1String("file:")))
            files << QUrl(a).toLocalFile();
        else if (!a.startsWith(QLatin1Char('-')))
            files << QFileInfo(a).absoluteFilePath();
    }

    // One Sasha at a time: if one is already running, hand it the files
    // (and the launcher's activation token so it can come to the front) and quit.
    static const QString service = QStringLiteral("io.github.sasha.Sasha");
    static const QString objectPath = QStringLiteral("/Sasha");
    Player player;
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (bus.isConnected()) {
        bus.registerObject(objectPath, &player, QDBusConnection::ExportScriptableSlots);
        if (!bus.registerService(service)) {
            QDBusMessage call = QDBusMessage::createMethodCall(service, objectPath, service, QStringLiteral("Open"));
            call << files << QString::fromLocal8Bit(qgetenv("XDG_ACTIVATION_TOKEN"));
            const QDBusMessage reply = bus.call(call, QDBus::Block, 5000);
            if (reply.type() == QDBusMessage::ReplyMessage)
                return 0;
            std::fprintf(stderr, "Sasha: another copy seems to be running but didn't answer (%s); starting anyway.\n",
                         qPrintable(reply.errorMessage()));
        }
    }

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("player"), &player);

    // SASHA_QML=/path/to/main.qml loads the window from a file instead,
    // so the layout can be tweaked without rebuilding.
    const QByteArray qmlFile = qgetenv("SASHA_QML");
    if (!qmlFile.isEmpty())
        engine.load(QUrl::fromLocalFile(QString::fromLocal8Bit(qmlFile)));
    else
        engine.loadData(QByteArray(qml, qsizetype(qmlLen)), QUrl(QStringLiteral("qrc:/sasha/main.qml")));

    if (engine.rootObjects().isEmpty()) {
        std::fprintf(stderr,
                     "\nSasha: the window failed to load. The QML errors above name the cause.\n"
                     "If they say a module \"is not installed\", a Qt Quick package is missing. On Debian, Ubuntu or Kubuntu:\n"
                     "  sudo apt install qml6-module-qtquick qml6-module-qtquick-controls \\\n"
                     "       qml6-module-qtquick-templates qml6-module-qtquick-window qml6-module-qtqml-workerscript \\\n"
                     "       qml6-module-qtqml-models\n"
                     "On openSUSE: sudo zypper install qt6-declarative-imports\n\n");
        return 1;
    }

    player.attachWindow(qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst()));
    player.start();
    player.openFiles(files);
    return app.exec();
}
