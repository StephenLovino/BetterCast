#include "DonatePrompt.h"

#include <QDesktopServices>
#include <QLabel>
#include <QPushButton>
#include <QSettings>
#include <QUrl>
#include <QVBoxLayout>

// Stored beside every other BetterCast setting, so the Qt app and the glass
// build count launches and remember the answer together.
static constexpr const char* kSettingsOrg = "BetterCast";
static constexpr const char* kSettingsApp = "BetterCast";

bool DonatePrompt::silenced() {
    // Only this key. The every-fifth-launch prompt this replaced stored
    // "support/dismissedForever", but it set that from "Buy me a coffee" as
    // well as from "I've already donated", so it cannot stand for the one
    // answer that is allowed to stop the prompt.
    return QSettings(kSettingsOrg, kSettingsApp).value("donatePrompt/silenced", false).toBool();
}

void DonatePrompt::setSilenced(bool silenced) {
    QSettings(kSettingsOrg, kSettingsApp).setValue("donatePrompt/silenced", silenced);
}

bool DonatePrompt::shouldPresentOnLaunch() {
    // Every launch, the first included, until "I already donated" is pressed.
    // An earlier version skipped the first launch the way the macOS prompt
    // does; that silently swallowed the first launch of the update for
    // everyone upgrading, and the rule here is simpler: it asks each open.
    return !silenced();
}

void DonatePrompt::showIfDue(QWidget* parent) {
    if (!shouldPresentOnLaunch()) return;
    auto* prompt = new DonatePrompt(parent);
    prompt->show();
    prompt->raise();
    prompt->activateWindow();
}

DonatePrompt::DonatePrompt(QWidget* parent)
    : QDialog(parent)
{
    setAttribute(Qt::WA_DeleteOnClose);
    setWindowTitle(tr("Support BetterCast"));
    setWindowFlag(Qt::WindowContextHelpButtonHint, false);
    if (parent) {
        // A sheet over the window, as on the Mac.
        setWindowModality(Qt::WindowModal);
    } else {
        // The glass build has no Qt parent to sit over; keep it above the
        // D3D window instead of letting it open behind.
        setWindowFlag(Qt::WindowStaysOnTopHint);
    }
    setFixedWidth(380);

    // Secondary text, borders and the link are the window's own text colour at
    // reduced opacity. palette(mid) was used before and is a fixed mid grey:
    // readable on a light window, close to invisible on Windows' dark theme,
    // which is where the body text and "I already donated" vanished.
    const QColor text = palette().color(QPalette::WindowText);
    auto withAlpha = [&text](int alpha) {
        return QString("rgba(%1, %2, %3, %4)")
            .arg(text.red()).arg(text.green()).arg(text.blue()).arg(alpha);
    };
    const QString secondary = withAlpha(190);
    const QString subtle    = withAlpha(150);
    const QString border    = withAlpha(90);
    const QString hoverFill = withAlpha(30);

    auto* layout = new QVBoxLayout(this);
    layout->setContentsMargins(24, 22, 24, 16);
    layout->setSpacing(14);

    // U+2615 HOT BEVERAGE, written as UTF-8 escapes: the macOS prompt shows a
    // cup, and an emoji needs no image resource, which the glass build lacks.
    auto* cup = new QLabel(QString::fromUtf8("\xE2\x98\x95"));
    cup->setAlignment(Qt::AlignCenter);
    cup->setStyleSheet("font-size: 40px; font-family: 'Segoe UI Emoji';");
    layout->addWidget(cup);

    auto* title = new QLabel(tr("Want me to keep building free stuff?"));
    title->setAlignment(Qt::AlignCenter);
    title->setWordWrap(true);
    title->setStyleSheet("font-size: 18px; font-weight: 600;");
    layout->addWidget(title);

    auto* body = new QLabel(tr("BetterCast is free, has no ads, and does not track you. "
                               "If it saved you the price of a second monitor, a coffee "
                               "goes a long way."));
    body->setAlignment(Qt::AlignCenter);
    body->setWordWrap(true);
    body->setStyleSheet(QString("font-size: 13px; color: %1;").arg(secondary));
    layout->addWidget(body);

    auto* buttons = new QVBoxLayout();
    buttons->setSpacing(8);

    auto* donate = new QPushButton(tr("Buy me a coffee"));
    donate->setDefault(true);
    donate->setCursor(Qt::PointingHandCursor);
    donate->setStyleSheet(
        "QPushButton { background-color: #0078D4; color: #ffffff; font-weight: bold; "
        "padding: 10px; border-radius: 8px; border: none; font-size: 13px; }"
        "QPushButton:hover { background-color: #1a88e0; }");
    buttons->addWidget(donate);

    auto* later = new QPushButton(tr("Maybe later"));
    later->setCursor(Qt::PointingHandCursor);
    later->setStyleSheet(
        QString("QPushButton { padding: 9px; border-radius: 8px; border: 1px solid %1; "
                "background: transparent; font-size: 13px; }"
                "QPushButton:hover { background: %2; }").arg(border, hoverFill));
    buttons->addWidget(later);
    layout->addLayout(buttons);

    // The small one at the bottom, styled as a link rather than a button so it
    // reads as the quiet way out it is.
    auto* already = new QPushButton(tr("I already donated, don't pop up again"));
    already->setFlat(true);
    already->setCursor(Qt::PointingHandCursor);
    already->setStyleSheet(
        QString("QPushButton { border: none; background: transparent; padding: 2px; "
                "font-size: 12px; color: %1; text-decoration: underline; }"
                "QPushButton:hover { color: %2; }").arg(subtle, secondary));
    layout->addWidget(already, 0, Qt::AlignHCenter);

    connect(donate, &QPushButton::clicked, this, [this]() {
        QDesktopServices::openUrl(QUrl(QString::fromLatin1(kDonateUrl)));
        // Closed for this launch only. Opening the page is not proof of a
        // donation, and "I already donated" is there for when there was one.
        accept();
    });
    connect(later, &QPushButton::clicked, this, &QDialog::reject);
    connect(already, &QPushButton::clicked, this, [this]() {
        setSilenced(true);
        accept();
    });
}
