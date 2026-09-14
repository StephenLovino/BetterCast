#pragma once

#include <QDialog>

// Launch-time nudge asking people to chip in - the Windows twin of the macOS
// app's DonatePrompt (Sources/BetterCastSender/DonatePrompt.swift on main).
//
// Same rules as there. BetterCast is free and unlicensed, so whether somebody
// donated is not knowable from inside the app: "I already donated" is an
// honour-system button that silences the prompt for good, not a verified
// state. The very first launch passes unasked - someone who has not seen the
// app work yet should not be asked for money - and every launch after that
// asks until that button is pressed.
//
// A plain Qt dialog so the Qt app and the glass build share it: the glass
// build runs a full QApplication, pumped once per frame, so a top-level
// widget there works like anywhere else.
class DonatePrompt : public QDialog {
    Q_OBJECT
public:
    // Counts this launch and shows the prompt if it is due. Never blocks: the
    // dialog deletes itself when closed. With no parent (the glass build) it
    // is its own window, kept above the app.
    static void showIfDue(QWidget* parent = nullptr);

    // Call once per launch. Returns whether the prompt should be presented.
    static bool shouldPresentOnLaunch();

    // Set only by "I already donated". Never cleared by the app.
    static bool silenced();
    static void setSilenced(bool silenced);

    static constexpr const char* kDonateUrl = "https://whop.com/bettercast/bettercast-donate/";

private:
    explicit DonatePrompt(QWidget* parent);
};
