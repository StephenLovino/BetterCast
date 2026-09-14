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
    QSettings settings(kSettingsOrg, kSettingsApp);
    // "support/dismissedForever" is what the every-fifth-launch prompt this
    // replaced stored. Someone who already told that one they had donated is
    // not asked again.
    return settings.value("donatePrompt/silenced", false).toBool() ||
           settings.value("support/dismissedForever", false).toBool();
}

void DonatePrompt::setSilenced(bool silenced) {
    QSettings(kSettingsOrg, kSettingsApp).setValue("donatePrompt/silenced", silenced);
}

bool DonatePrompt::shouldPresentOnLaunch() {
    QSettings settings(kSettingsOrg, kSettingsApp);

    // "The first launch passes unasked" is meant for someone brand new. This
    // counter did not exist before the prompt did, so without this everyone
    // who installed the update had their first launch of it treated as their
    // first launch ever and saw nothing - which is how it looked broken on a
    // real machine. Settings left by earlier versions mean they have used
    // BetterCast before: start them past the grace launch.
    if (!settings.contains("donatePrompt/launchCount")) {
        const bool usedBefore = settings.value("support/launchCount", 0).toInt() > 0 ||
                                !settings.childGroups().filter("virtualDisplays").isEmpty() ||
                                !settings.childGroups().filter("devices").isEmpty();
        if (usedBefore) settings.setValue("donatePrompt/launchCount", 1);
    }

    const int launches = settings.value("donatePrompt/launchCount", 0).toInt() + 1;
    settings.setValue("donatePrompt/launchCount", launches);
    if (silenced()) return false;
    return launches > 1;   // the first launch passes unasked
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
    body->setStyleSheet("font-size: 13px; color: palette(mid);");
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
        "QPushButton { padding: 9px; border-radius: 8px; border: 1px solid palette(mid); "
        "background: transparent; font-size: 13px; }"
        "QPushButton:hover { background: rgba(127, 127, 127, 0.14); }");
    buttons->addWidget(later);
    layout->addLayout(buttons);

    // The small one at the bottom, styled as a link rather than a button so it
    // reads as the quiet way out it is.
    auto* already = new QPushButton(tr("I already donated, don't pop up again"));
    already->setFlat(true);
    already->setCursor(Qt::PointingHandCursor);
    already->setStyleSheet(
        "QPushButton { border: none; background: transparent; padding: 2px; "
        "font-size: 11px; color: palette(mid); text-decoration: underline; }"
        "QPushButton:hover { color: palette(link); }");
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
