// BetterCast: receive page. Replaces liquidDX11's "Storage".
//
// The name and addresses here were literals - someone else's machine name and
// an IP from a network that no longer exists - and the ADB button had an empty
// body. Both are real now.
            if (dispPage == 3) {
                Glass::BeginPanel("RECEIVE A SCREEN");
                ImGui::TextWrapped("Other devices send to this PC. Nothing has to be started "
                                   "here - it listens whenever BetterCast is open.");
                ImGui::Dummy(ImVec2(0, 6));
                Glass::StatRow("Listening", BetterCastBridge::listeningOn().c_str());
                Glass::StatRow("Advertised as", BetterCastBridge::advertisedName().c_str());
                Glass::StatRow("Address", BetterCastBridge::userHandle().c_str());
                Glass::StatRow("Receiving now",
                               BetterCastBridge::isReceiving() ? "yes" : "not right now");
                Glass::EndPanel();

                Glass::BeginPanel("ANDROID OVER WI-FI");
                ImGui::TextWrapped("Shows an Android phone's screen on this PC without a "
                                   "cable. On the phone, open BetterCast, switch to Send and "
                                   "start sharing. Then enter the phone's IP address here - "
                                   "it is in the phone's Wi-Fi network details, or under "
                                   "Settings > About phone > Status.");
                ImGui::Dummy(ImVec2(0, 8));
                {
                    static char bcPhoneAddr[64] = {};
                    static bool bcPhoneAddrLoaded = false;
                    if (!bcPhoneAddrLoaded) {
                        bcPhoneAddrLoaded = true;
                        std::snprintf(bcPhoneAddr, sizeof(bcPhoneAddr), "%s",
                                      BetterCastBridge::androidWifiAddress().c_str());
                    }
                    Glass::TextField("Phone address", bcPhoneAddr, sizeof(bcPhoneAddr),
                                     "192.168.1.23");
                    ImGui::Dummy(ImVec2(0, 6));
                    if (Glass::Button("Connect to Android over Wi-Fi", true)) {
                        BetterCastBridge::receiveFromAndroidOverWifi(bcPhoneAddr);
                    }
                }
                {
                    const std::string bcWifiSt = BetterCastBridge::androidWifiStatus();
                    if (!bcWifiSt.empty()) {
                        ImGui::Dummy(ImVec2(0, 6));
                        Glass::StatRow("Status", bcWifiSt.c_str());
                    }
                }
                ImGui::TextDisabled("Both need the same network - or put the phone on this "
                                    "PC's hotspot. View only: the phone does not take taps "
                                    "back from here.");
                Glass::EndPanel();

                Glass::BeginPanel("ANDROID OVER THE CABLE");
                ImGui::TextWrapped("For when the phone and this PC cannot find each other "
                                   "over Wi-Fi. Forwards a port through the USB cable and "
                                   "dials it, so the phone can send its screen here.");
                ImGui::Dummy(ImVec2(0, 8));

                if (!BetterCastBridge::androidCableAvailable()) {
                    ImGui::TextDisabled("adb was not found on this PC.");
                    ImGui::TextWrapped("The bundled copy lives beside BetterCast; if this "
                                       "says otherwise, the install is missing it.");
                } else {
                    if (Glass::Button("Connect to Android over USB", true)) {
                        BetterCastBridge::receiveFromAndroidOverCable();
                    }
                    ImGui::Dummy(ImVec2(0, 6));
                    const std::string st = BetterCastBridge::androidCableStatus();
                    if (!st.empty()) Glass::StatRow("Status", st.c_str());
                    ImGui::TextDisabled("Needs USB debugging turned on, and the phone to "
                                        "have allowed this computer.");
                }
                Glass::EndPanel();
            }
