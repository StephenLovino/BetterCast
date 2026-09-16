#pragma once

#include <QObject>
#include <QString>

class QNetworkAccessManager;

// Checks GitHub Releases for a newer BetterCast.
//
// Two release lines share the repository. macOS (and Linux) ship as vNN tags;
// Windows ships as windows-<x.y.z>, with a version of its own. A Windows build
// that read "releases/latest" compared itself with whatever shipped last
// repo-wide - in practice a macOS vNN - and claimed an update to a Mac release
// forever. So on Windows the checker reads the release list, takes the newest
// published windows-* release, and compares full versions (1.1.0 vs 1.0.1).
// Everywhere else it reads releases/latest and compares vNN majors, as before.
class UpdateChecker : public QObject {
    Q_OBJECT

public:
    explicit UpdateChecker(QObject* parent = nullptr);

    // This build's release tag: "windows-1.1.0" on Windows, "v17" elsewhere.
    // Derived from the version CMake compiles in, so it cannot drift from the
    // installer.
    static QString currentTag();

    // Full version for display, e.g. "1.1.0" on Windows, "17.0.0" elsewhere.
    static QString currentVersion();

    // Leading integer of a tag: "v17" and "V17.2" both give 17, anything
    // unparseable gives 0 so a malformed tag never looks newer than a real one.
    static int versionNumber(const QString& tag);

    // Whether a release tag is newer than this build, using the rules above.
    static bool isNewer(const QString& latestTag);

    void check();

signals:
    // updateAvailable is false when this build is current — callers still get
    // latestTag so they can show "you are on the latest version".
    void finished(bool updateAvailable, const QString& latestTag,
                  const QString& url, const QString& notes);
    void failed(const QString& message);

private:
    QNetworkAccessManager* m_net = nullptr;
    bool m_inFlight = false;
};
