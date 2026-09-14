// BetterCast: settings. Replaces liquidDX11's "Customize".
//
// The same settings the Qt app carries - identity, language, version and
// update state, the log file - reading and writing the same QSettings keys
// and the same UpdateChecker, so the two front ends agree about everything.
            if (dispPage == 4) {
                Glass::BeginPanel("THIS DEVICE");
                ImGui::TextWrapped("The name other devices see when they look for a screen "
                                   "to extend onto.");
                ImGui::Dummy(ImVec2(0, 6));
                {
                    static char bcName[64] = {};
                    static bool bcNameLoaded = false;
                    if (!bcNameLoaded) {
                        bcNameLoaded = true;
                        const std::string n = BetterCastBridge::userName();
                        std::snprintf(bcName, sizeof(bcName), "%s", n.c_str());
                    }
                    if (Glass::TextField("Name", bcName, sizeof(bcName), "This PC")) {
                        BetterCastBridge::setUserName(bcName);
                    }
                }
                Glass::StatRow("Address", BetterCastBridge::userHandle().c_str());
                ImGui::TextDisabled("Advertised from the next start.");
                Glass::EndPanel();

                Glass::BeginPanel("LANGUAGE");
                {
                    // Listed by endonym: someone hunting for their own language
                    // looks for its own name, not for whatever English calls it.
                    const auto langs = BetterCastBridge::languages();
                    static std::vector<const char*> bcLangLabels;
                    static std::vector<std::string> bcLangCodes;
                    if (bcLangLabels.empty()) {
                        bcLangLabels.push_back("Follow system");
                        bcLangCodes.push_back("");
                        for (const auto& l : langs) {
                            bcLangCodes.push_back(l.first);
                            bcLangLabels.push_back(nullptr);   // filled below
                        }
                        // Labels must outlive the call, so they point at the
                        // stored strings rather than temporaries.
                        static std::vector<std::string> keep;
                        for (const auto& l : langs) keep.push_back(l.second);
                        for (size_t i = 0; i < keep.size(); i++)
                            bcLangLabels[i + 1] = keep[i].c_str();
                    }

                    static int bcLang = -1;
                    if (bcLang < 0) {
                        bcLang = 0;
                        const std::string saved = BetterCastBridge::savedLanguage();
                        for (size_t i = 0; i < bcLangCodes.size(); i++)
                            if (bcLangCodes[i] == saved) bcLang = (int)i;
                    }
                    if (Glass::Dropdown("Language", bcLangLabels.data(),
                                        (int)bcLangLabels.size(), &bcLang)) {
                        BetterCastBridge::setSavedLanguage(bcLangCodes[(size_t)bcLang]);
                    }
                    ImGui::TextDisabled("Applies the next time BetterCast starts.");
                }
                Glass::EndPanel();

                Glass::BeginPanel("ABOUT");
                Glass::StatRow("Version", BetterCastBridge::appVersion().c_str());
                {
                    const std::string st = BetterCastBridge::updateStatus();
                    Glass::StatRow("Updates", st.empty() ? "not checked yet" : st.c_str());
                }
                ImGui::Dummy(ImVec2(0, 6));
                if (Glass::Button("Check for Updates", false)) {
                    BetterCastBridge::checkForUpdates();
                }
                if (!BetterCastBridge::updateUrl().empty()) {
                    ImGui::SameLine();
                    if (Glass::Button("Open Release Page", true)) {
                        BetterCastBridge::openUrl(BetterCastBridge::updateUrl());
                    }
                }
                Glass::EndPanel();

                Glass::BeginPanel("LOG");
                // BetterCast used to run as a console binary, so this scrolled
                // past in a terminal beside the window. That terminal is gone -
                // it was an artifact of how the thing was linked, not a
                // feature - so the log lives here instead.
                {
                    const auto& bcLog = BetterCastBridge::logLines();
                    ImGui::BeginChild("bclog", ImVec2(0, 240.0f*scale), true,
                                      ImGuiWindowFlags_HorizontalScrollbar);
                    if (bcLog.empty()) {
                        ImGui::TextDisabled("Nothing logged yet.");
                    } else {
                        // TextUnformatted, not Text: a log line is data and can
                        // contain a percent sign.
                        for (const auto& line : bcLog) ImGui::TextUnformatted(line.c_str());
                    }
                    // Follow the tail, but stop following the moment the user
                    // scrolls up - otherwise reading anything while a stream is
                    // running is impossible.
                    if (ImGui::GetScrollY() >= ImGui::GetScrollMaxY() - 1.0f) {
                        ImGui::SetScrollHereY(1.0f);
                    }
                    ImGui::EndChild();
                }
                ImGui::Dummy(ImVec2(0, 6));
                if (Glass::Button("Open Log File", false)) {
                    BetterCastBridge::openLogFile();
                }
                Glass::EndPanel();

                Glass::BeginPanel("DIAGNOSTICS");
                Glass::StatRow("Log file", BetterCastBridge::logFilePath().c_str());
                ImGui::TextWrapped("Written as it happens and kept across a crash, so the "
                                   "previous run is still there after a restart.");

                const auto vddNodes = BetterCastBridge::virtualDisplayNodes();
                if (vddNodes.available) {
                    ImGui::Dummy(ImVec2(0, 6));
                    const std::string vddCounts =
                        std::to_string(vddNodes.present) + " active, " +
                        std::to_string(vddNodes.disconnected) + " disconnected";
                    Glass::StatRow("Virtual displays", vddCounts.c_str());
                    if (vddNodes.present + vddNodes.disconnected > 0) {
                        ImGui::TextWrapped("Disconnected ones are left over from earlier "
                                           "installs. Removing all of them is safe: "
                                           "BetterCast adds what it needs the next time "
                                           "you extend. Asks for administrator approval.");
                        ImGui::Dummy(ImVec2(0, 6));
                        if (BetterCastBridge::sessionCount() > 0) {
                            ImGui::TextDisabled("Stop streaming first - removing them ends "
                                                "every capture.");
                        } else if (Glass::Button("Remove All Virtual Displays", false)) {
                            BetterCastBridge::removeAllVirtualDisplays();
                        }
                    }
                }
                Glass::EndPanel();

                Glass::BeginPanel("SUPPORT");
                ImGui::TextWrapped("BetterCast is free and has no subscription. If it saved "
                                   "you buying a second monitor, you can chip in.");
                ImGui::Dummy(ImVec2(0, 6));
                if (Glass::Button("Support BetterCast", true)) {
                    BetterCastBridge::openUrl("https://whop.com/bettercast/bettercast-donate/");
                }
                ImGui::TextDisabled("Made with love by Stephen Lovino");
                Glass::EndPanel();
            }
