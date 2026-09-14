// BetterCast: device page, driven by the real core. Replaces "General".
//
// Not a mockup. The device list is whatever BetterCast's own ServiceDiscovery
// has found this second, and the two buttons drive the real SenderController -
// DXGI duplication into a hardware encoder, onto a virtual display claimed for
// that receiver or onto the screen in front of you. Nothing here reimplements
// any of it.
//
// Send and Extend are the pair the macOS sender offers as "Mirror Built-in"
// and "Extended Display", and they mean the same things here.
            if (dispPage == 0) {
                const auto& bcDevices = BetterCastBridge::devices();

                // All page state up front. ImGui statics are function-scoped
                // and these are read across several panels, so declaring them
                // where they are first drawn would leave the earlier ones
                // unable to see them.
                //
                // Selection is held as a name rather than an index: the device
                // list is rebuilt whenever discovery finds or loses something,
                // and an index would then be pointing at whoever moved into
                // that slot.
                static std::string bcSelName;
                static float bcFps     = 60.0f;
                static float bcBitrate = 20.0f;
                static int   bcRes     = 0;
                static const char* bcResNames[] = {
                    "Match this PC", "1920 x 1080", "1440 x 900", "1280 x 800", "1280 x 720" };
                static const int bcResW[] = { 0, 1920, 1440, 1280, 1280 };
                static const int bcResH[] = { 0, 1080,  900,  800,  720 };
                const int bcResCount = 5;

                int bcSelected = -1;
                for (int i = 0; i < (int)bcDevices.size(); i++)
                    if (bcDevices[(size_t)i].name == bcSelName) bcSelected = i;
                if (bcSelected < 0 && !bcDevices.empty()) bcSelected = 0;

                // Load this device's own settings whenever the selection moves,
                // so switching between a phone and a laptop shows each one's
                // size rather than whatever was last typed.
                static std::string bcLoadedFor;
                static bool bcLoadedAny = false;
                if (bcSelected >= 0) {
                    const std::string& selName = bcDevices[(size_t)bcSelected].name;
                    bcSelName = selName;
                    if (!bcLoadedAny || bcLoadedFor != selName) {
                        bcLoadedAny = true;
                        bcLoadedFor = selName;
                        const auto cfg = BetterCastBridge::settingsFor(selName);
                        bcFps     = (float)cfg.fps;
                        bcBitrate = (float)cfg.bitrateMbps;
                        bcRes = 0;
                        for (int i = 0; i < bcResCount; i++)
                            if (bcResW[i] == cfg.width && bcResH[i] == cfg.height) bcRes = i;
                    }
                }

                // Writes back only on a change, so this is not a settings file
                // rewritten sixty times a second.
                auto bcSave = [&]() {
                    if (bcSelected < 0) return;
                    BetterCastBridge::StreamSettings cfg;
                    cfg.fps         = (int)bcFps;
                    cfg.bitrateMbps = (int)bcBitrate;
                    cfg.width       = bcResW[bcRes];
                    cfg.height      = bcResH[bcRes];
                    BetterCastBridge::setSettingsFor(bcDevices[(size_t)bcSelected].name, cfg);
                };

                Glass::BeginPanel("DEVICES ON THIS NETWORK");
                if (bcDevices.empty()) {
                    ImGui::TextDisabled("Browsing for receivers...");
                    ImGui::TextWrapped("Open BetterCast on a phone, tablet or Mac and it "
                                       "should appear here within a few seconds.");
                } else {
                    for (int i = 0; i < (int)bcDevices.size(); i++) {
                        const bool live = BetterCastBridge::isSendingTo(bcDevices[(size_t)i].host);
                        std::string label = bcDevices[(size_t)i].name;
                        if (live) label += "  *";     // streaming right now
                        if (Glass::Chip(label.c_str(), bcSelected == i))
                            bcSelName = bcDevices[(size_t)i].name;
                    }
                    if (bcSelected >= 0) {
                        const auto& sel = bcDevices[(size_t)bcSelected];
                        Glass::Divider();
                        Glass::StatRow("Address",
                            (sel.host + ":" + std::to_string(sel.port)).c_str());
                    }
                }
                Glass::EndPanel();

                Glass::BeginPanel("SCREEN FOR THIS DEVICE");
                if (bcSelected < 0) {
                    ImGui::TextDisabled("No device selected.");
                } else {
                    const auto& target = bcDevices[(size_t)bcSelected];
                    if (BetterCastBridge::isSendingTo(target.host)) {
                        const std::string disp =
                            BetterCastBridge::displayForReceiver(target.host);
                        Glass::StatRow("Capturing", disp.empty() ? "-" : disp.c_str());
                        Glass::StatRow("Encoder", BetterCastBridge::encoderInfo().c_str());
                        ImGui::Dummy(ImVec2(0, 6));
                        if (Glass::Button("Stop Streaming Here", false)) {
                            BetterCastBridge::stopSending(target.host);
                        }
                    } else {
                        ImGui::TextWrapped("Mirror shows this device the screen in front of "
                                           "you. Extend gives it a display of its own, so "
                                           "your desktop grows onto it.");
                        ImGui::Dummy(ImVec2(0, 8));

                        // Windows can duplicate a display only once, so Mirror
                        // is offered to one device at a time. Saying so up front
                        // beats a button that fails when pressed.
                        const bool mirrored = BetterCastBridge::isMirroring();
                        if (!mirrored) {
                            if (Glass::Button("Mirror Screen Here", false)) {
                                BetterCastBridge::startMirroring(
                                    target.host, target.port,
                                    (int)bcFps, (int)bcBitrate);
                            }
                            ImGui::SameLine();
                        }
                        if (Glass::Button("Extend Screen Here", true)) {
                            BetterCastBridge::startExtending(
                                target.host, target.port,
                                (int)bcFps, (int)bcBitrate,
                                bcResW[bcRes], bcResH[bcRes],
                                target.name);
                        }
                        if (mirrored) {
                            ImGui::TextDisabled("Your screen is already going to another "
                                                "device; Windows can only send it once.");
                        }
                    }
                    ImGui::Dummy(ImVec2(0, 4));
                    ImGui::TextDisabled("%d streaming", BetterCastBridge::sessionCount());

                    // This device's own virtual display. Windows names every
                    // one "VDD by MTT", so this is where it says whose is whose.
                    Glass::Divider();
                    const std::string bcNode = BetterCastBridge::virtualDisplayFor(target.name);
                    if (bcNode.empty()) {
                        ImGui::TextDisabled("No virtual display yet - one is set up the "
                                            "first time you extend here.");
                    } else {
                        std::string bcWhere = bcNode + "  (not attached)";
                        for (const auto& vd : BetterCastBridge::virtualDisplayList()) {
                            if (vd.instanceId == bcNode && !vd.displayName.empty())
                                bcWhere = vd.displayName + "  (" + bcNode + ")";
                        }
                        Glass::StatRow("Virtual display", bcWhere.c_str());
                        if (BetterCastBridge::sessionCount() > 0) {
                            ImGui::TextDisabled("Stop streaming to remove it.");
                        } else if (Glass::Button("Remove This Virtual Display", false)) {
                            BetterCastBridge::removeVirtualDisplay(bcNode);
                        }
                    }
                }
                Glass::EndPanel();

                // The other direction: that device's screen, on this PC,
                // without walking over to it.
                Glass::BeginPanel("THEIR SCREEN ON THIS PC");
                if (bcSelected < 0) {
                    ImGui::TextDisabled("No device selected.");
                } else {
                    const auto& target = bcDevices[(size_t)bcSelected];
                    BetterCastBridge::probeAskSupport(target.host);
                    const auto support = BetterCastBridge::askSupport(target.host);

                    ImGui::TextWrapped("Asks that device to send its screen here, so you "
                                       "never have to touch it. Extend gives this PC a "
                                       "display of its own over there; Mirror duplicates "
                                       "its main screen.");
                    ImGui::Dummy(ImVec2(0, 8));

                    // Drawn either way rather than hidden, so it is clear the
                    // feature exists and what is missing. Enabled the moment
                    // the other end starts listening - no change needed here.
                    const bool canAsk = support == BetterCastBridge::AskSupport::Yes;
                    if (!canAsk) ImGui::BeginDisabled();
                    if (Glass::Button("Mirror Their Screen Here", false)) {
                        BetterCastBridge::askToSend(target.host, false);
                    }
                    ImGui::SameLine();
                    if (Glass::Button("Extend Them Onto This PC", true)) {
                        BetterCastBridge::askToSend(target.host, true);
                    }
                    if (!canAsk) ImGui::EndDisabled();

                    ImGui::Dummy(ImVec2(0, 6));
                    switch (support) {
                        case BetterCastBridge::AskSupport::Probing:
                            ImGui::TextDisabled("Asking whether it can be asked...");
                            break;
                        case BetterCastBridge::AskSupport::Yes:
                            ImGui::TextDisabled("Ready.");
                            break;
                        default:
                            // The macOS app does not listen for this yet. Say
                            // so, and say what does work in the meantime,
                            // rather than leaving a dead button unexplained.
                            ImGui::TextWrapped("This device cannot be asked yet - the Mac "
                                               "app needs the version that listens for it. "
                                               "Until then, turn on Auto-Connect on the Mac "
                                               "and set Use as to Extended Display or "
                                               "Mirror Built-in; it will start sending here "
                                               "on its own.");
                            break;
                    }
                }
                Glass::EndPanel();

                Glass::BeginPanel("STREAM QUALITY FOR THIS DEVICE");
                if (bcSelected < 0) {
                    ImGui::TextDisabled("No device selected.");
                } else {
                    ImGui::SetNextItemWidth(220.0f*scale);
                    if (Glass::Slider("Frame rate", &bcFps, 15.0f, 120.0f, "%.0f FPS")) bcSave();
                    if (Glass::Dropdown("Resolution", bcResNames, bcResCount, &bcRes)) bcSave();
                    ImGui::SetNextItemWidth(220.0f*scale);
                    if (Glass::Slider("Bitrate", &bcBitrate, 2.0f, 100.0f, "%.0f Mbps")) bcSave();
                    // Through %s rather than as the format string: a device
                    // name is whatever its owner typed, and a stray % in it
                    // would be read as a conversion.
                    const std::string note =
                        "Kept for " + bcDevices[(size_t)bcSelected].name +
                        " and used the next time a stream starts. Resolution applies to "
                        "Extend; Mirror is whatever size your screen already is.";
                    ImGui::TextWrapped("%s", note.c_str());
                }
                Glass::EndPanel();

                // The one panel that runs the other way: the phone's screen
                // arrives here, rather than this PC's screen going out. Kept
                // separate from the device list above for that reason, and
                // because a phone on a cable is not something mDNS ever sees.
                Glass::BeginPanel("ANDROID OVER USB");
                if (!BetterCastBridge::androidToolsPresent()) {
                    ImGui::TextWrapped("The Android tools are not installed beside "
                                       "BetterCast, so a phone cannot be mirrored from "
                                       "this build.");
                } else if (!BetterCastBridge::androidWatching()) {
                    ImGui::TextWrapped("Shows an Android phone's screen here, over the "
                                       "cable. Turn on USB debugging on the phone, plug "
                                       "it in, then look for it.");
                    ImGui::Dummy(ImVec2(0, 8));
                    if (Glass::Button("Look for Android Devices", false)) {
                        BetterCastBridge::watchAndroid(true);
                    }
                } else {
                    const auto& bcPhones = BetterCastBridge::androidDevices();
                    if (bcPhones.empty()) {
                        ImGui::TextDisabled("Nothing on the cable yet.");
                        ImGui::TextWrapped("Plug the phone in and accept the debugging "
                                           "prompt it shows.");
                    }
                    for (size_t i = 0; i < bcPhones.size(); i++) {
                        const auto& ph = bcPhones[i];
                        ImGui::PushID((int)i);
                        Glass::StatRow(ph.model.c_str(), ph.state.c_str());
                        if (ph.state == "device") {
                            if (Glass::Button("Mirror This Phone Here", true)) {
                                BetterCastBridge::mirrorAndroid(ph.serial);
                            }
                        } else if (ph.state == "unauthorized") {
                            ImGui::TextWrapped("The phone is waiting for you to allow "
                                               "this computer. Look at its screen.");
                        }
                        ImGui::PopID();
                    }
                    ImGui::Dummy(ImVec2(0, 6));
                    if (Glass::Button("Stop Looking", false)) {
                        BetterCastBridge::watchAndroid(false);
                    }
                }
                {
                    const std::string st = BetterCastBridge::androidStatus();
                    if (!st.empty()) Glass::StatRow("Status", st.c_str());
                }
                Glass::EndPanel();

                // The architecture questions, answered on screen rather than argued.
                Glass::BeginPanel("ARCHITECTURE PROBE");
                Glass::StatRow("Qt core", "running in this render loop");
                Glass::StatRow("Receivers found", std::to_string(bcDevices.size()).c_str());
                Glass::StatRow("Streams active",
                               std::to_string(BetterCastBridge::sessionCount()).c_str());
                Glass::StatRow("OpenGL window",
                               BetterCastBridge::probeWindowOpen() ? "open" : "closed");
                {
                    // Click another window and watch this drop: a utility that
                    // sits open all day should not redraw at 60fps with nobody
                    // looking at it.
                    const std::string cap =
                        std::to_string(BetterCastBridge::currentFrameCap()) + " fps";
                    Glass::StatRow("Drawing at", cap.c_str());
                }
                ImGui::Dummy(ImVec2(0, 6));
                if (Glass::Button(BetterCastBridge::probeWindowOpen()
                                      ? "Close OpenGL window"
                                      : "Open OpenGL window", false)) {
                    BetterCastBridge::toggleProbeWindow();
                }
                Glass::EndPanel();

                Glass::BeginPanel("CORE LOG");
                {
                    const std::string last = BetterCastBridge::lastLogLine();
                    ImGui::TextWrapped("%s", last.empty() ? "(nothing logged yet)" : last.c_str());
                }
                Glass::EndPanel();
            }
