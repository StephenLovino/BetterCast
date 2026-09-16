#include "UpdateChecker.h"

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QList>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QTimer>
#include <QUrl>

#include <algorithm>

namespace {
constexpr const char* kReleasesLatest =
    "https://api.github.com/repos/StephenLovino/BetterCast/releases/latest";
// Newest first. Thirty covers many macOS releases between two Windows ones.
constexpr const char* kReleasesList =
    "https://api.github.com/repos/StephenLovino/BetterCast/releases?per_page=30";
constexpr const char* kWindowsTagPrefix = "windows-";
constexpr int kTimeoutMs = 10000;

// "windows-1.1.0" -> {1, 1, 0}; "v17" -> {17}. Stops at the first character
// after the number that is not a dot, so suffixes like "-beta" are ignored.
QList<int> versionParts(const QString& text) {
    QList<int> parts;
    QString digits;
    bool started = false;
    for (const QChar c : text) {
        if (c.isDigit()) {
            digits += c;
            started = true;
        } else if (started && c == QLatin1Char('.')) {
            parts << digits.toInt();
            digits.clear();
        } else if (started) {
            break;
        }
    }
    if (!digits.isEmpty()) parts << digits.toInt();
    return parts;
}

// <0, 0 or >0, comparing part by part; missing parts count as 0.
int compareVersions(const QList<int>& a, const QList<int>& b) {
    const int n = std::max(a.size(), b.size());
    for (int i = 0; i < n; i++) {
        const int x = i < a.size() ? a.at(i) : 0;
        const int y = i < b.size() ? b.at(i) : 0;
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}
} // namespace

UpdateChecker::UpdateChecker(QObject* parent)
    : QObject(parent), m_net(new QNetworkAccessManager(this)) {}

QString UpdateChecker::currentVersion() {
#ifdef BETTERCAST_VERSION
    return QStringLiteral(BETTERCAST_VERSION);
#else
    return QCoreApplication::applicationVersion();
#endif
}

QString UpdateChecker::currentTag() {
#ifdef _WIN32
    return QString::fromLatin1(kWindowsTagPrefix) + currentVersion();
#else
    const QString major = currentVersion().section(QLatin1Char('.'), 0, 0);
    return QStringLiteral("v") + major;
#endif
}

int UpdateChecker::versionNumber(const QString& tag) {
    int i = 0;
    while (i < tag.size() && !tag.at(i).isDigit()) i++;

    QString digits;
    while (i < tag.size() && tag.at(i).isDigit()) {
        digits += tag.at(i);
        i++;
    }

    bool ok = false;
    const int value = digits.toInt(&ok);
    return ok ? value : 0;
}

bool UpdateChecker::isNewer(const QString& latestTag) {
#ifdef _WIN32
    return compareVersions(versionParts(latestTag), versionParts(currentVersion())) > 0;
#else
    return versionNumber(latestTag) > versionNumber(currentTag());
#endif
}

void UpdateChecker::check() {
    if (m_inFlight) return;
    m_inFlight = true;

#ifdef _WIN32
    const QUrl url(QString::fromLatin1(kReleasesList));
#else
    const QUrl url(QString::fromLatin1(kReleasesLatest));
#endif
    QNetworkRequest request(url);
    request.setRawHeader("Accept", "application/vnd.github+json");
    // GitHub rejects API requests without one.
    request.setHeader(QNetworkRequest::UserAgentHeader,
                      QStringLiteral("BetterCast/%1").arg(currentVersion()));

    QNetworkReply* reply = m_net->get(request);

    // QNetworkAccessManager has no per-request timeout before Qt 5.15's
    // transferTimeout, and a silently hung check would leave the UI saying
    // "Checking..." forever.
    auto* timeout = new QTimer(reply);
    timeout->setSingleShot(true);
    connect(timeout, &QTimer::timeout, reply, &QNetworkReply::abort);
    timeout->start(kTimeoutMs);

    connect(reply, &QNetworkReply::finished, this, [this, reply]() {
        reply->deleteLater();
        m_inFlight = false;

        if (reply->error() != QNetworkReply::NoError) {
            emit failed(reply->errorString());
            return;
        }

        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());

        QJsonObject release;
#ifdef _WIN32
        if (!doc.isArray()) {
            emit failed(QStringLiteral("GitHub returned an unexpected response"));
            return;
        }
        // The Windows line only: macOS vNN releases are not updates for this app.
        for (const QJsonValue& value : doc.array()) {
            const QJsonObject candidate = value.toObject();
            if (candidate.value(QStringLiteral("draft")).toBool() ||
                candidate.value(QStringLiteral("prerelease")).toBool()) {
                continue;
            }
            if (candidate.value(QStringLiteral("tag_name")).toString()
                    .startsWith(QLatin1String(kWindowsTagPrefix))) {
                release = candidate;
                break;
            }
        }
        if (release.isEmpty()) {
            emit failed(QStringLiteral("No Windows release found"));
            return;
        }
#else
        if (!doc.isObject()) {
            emit failed(QStringLiteral("GitHub returned an unexpected response"));
            return;
        }
        release = doc.object();
#endif

        const QString tag   = release.value(QStringLiteral("tag_name")).toString();
        const QString url   = release.value(QStringLiteral("html_url")).toString();
        const QString notes = release.value(QStringLiteral("body")).toString();

        if (tag.isEmpty()) {
            emit failed(QStringLiteral("No published release found"));
            return;
        }

        emit finished(isNewer(tag), tag, url, notes);
    });
}
