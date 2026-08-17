package com.bettercast.receiver.data

import android.content.Context
import android.os.Build
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class ThemeMode { SYSTEM, LIGHT, DARK }

/**
 * Persisted receiver preferences, mirroring the iOS settings screen.
 *
 * Backed by SharedPreferences and surfaced as StateFlows so both the settings tab and
 * the in-stream gear menu can drive the same values — on iOS those two paths mutate one
 * `@AppStorage` key, and they have to stay in step here too.
 */
class SettingsStore(context: Context) {

    companion object {
        private const val PREFS = "bettercast.settings"
        private const val KEY_DEVICE_NAME = "deviceName"
        private const val KEY_ASPECT_FILL = "aspectFill"
        private const val KEY_AUDIO_ENABLED = "audioEnabled"
        private const val KEY_CURSOR_MODE = "cursorMode"
        private const val KEY_THEME = "themeMode"
        private const val KEY_DONATE_SILENCED = "donatePromptSilenced"
        private const val KEY_LAUNCH_COUNT = "donatePromptLaunchCount"

        /** Where the donation prompt and the settings row both send people. */
        const val DONATE_URL = "https://whop.com/bettercast/bettercast-donate/"

        /** Falls back to the phone's model, the way iOS falls back to UIDevice.name. */
        fun defaultDeviceName(): String = "${Build.MANUFACTURER} ${Build.MODEL}"
            .replaceFirstChar { it.uppercase() }
    }

    private val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private val _deviceName = MutableStateFlow(
        prefs.getString(KEY_DEVICE_NAME, null)?.takeIf { it.isNotBlank() } ?: defaultDeviceName()
    )
    val deviceName: StateFlow<String> = _deviceName.asStateFlow()

    private val _aspectFill = MutableStateFlow(prefs.getBoolean(KEY_ASPECT_FILL, false))
    val aspectFill: StateFlow<Boolean> = _aspectFill.asStateFlow()

    private val _audioEnabled = MutableStateFlow(prefs.getBoolean(KEY_AUDIO_ENABLED, true))
    val audioEnabled: StateFlow<Boolean> = _audioEnabled.asStateFlow()

    /** False = touch (taps land where you touch), true = trackpad-style pointer. */
    private val _cursorMode = MutableStateFlow(prefs.getBoolean(KEY_CURSOR_MODE, false))
    val cursorMode: StateFlow<Boolean> = _cursorMode.asStateFlow()

    private val _themeMode = MutableStateFlow(
        runCatching { ThemeMode.valueOf(prefs.getString(KEY_THEME, null) ?: "") }
            .getOrDefault(ThemeMode.SYSTEM)
    )
    val themeMode: StateFlow<ThemeMode> = _themeMode.asStateFlow()

    fun setDeviceName(value: String) {
        val cleaned = value.trim().ifBlank { defaultDeviceName() }
        _deviceName.value = cleaned
        prefs.edit().putString(KEY_DEVICE_NAME, cleaned).apply()
    }

    fun setAspectFill(value: Boolean) {
        _aspectFill.value = value
        prefs.edit().putBoolean(KEY_ASPECT_FILL, value).apply()
    }

    fun setAudioEnabled(value: Boolean) {
        _audioEnabled.value = value
        prefs.edit().putBoolean(KEY_AUDIO_ENABLED, value).apply()
    }

    fun setCursorMode(value: Boolean) {
        _cursorMode.value = value
        prefs.edit().putBoolean(KEY_CURSOR_MODE, value).apply()
    }

    fun setThemeMode(value: ThemeMode) {
        _themeMode.value = value
        prefs.edit().putString(KEY_THEME, value.name).apply()
    }

    // ---- donation prompt ------------------------------------------------------

    /**
     * Whether the launch nudge should appear this time.
     *
     * There is no way to verify a donation from inside the app, so "stop asking" is an
     * honour-system flag rather than a checked entitlement — see DonatePrompt on the Mac
     * side for the same reasoning. Skips the very first launch: asking before the user
     * has seen the app work is how you get uninstalled instead of paid.
     *
     * Call once per process start; it increments the launch counter as a side effect.
     */
    fun shouldShowDonatePromptOnLaunch(): Boolean {
        val count = prefs.getInt(KEY_LAUNCH_COUNT, 0) + 1
        prefs.edit().putInt(KEY_LAUNCH_COUNT, count).apply()
        if (prefs.getBoolean(KEY_DONATE_SILENCED, false)) return false
        return count > 1
    }

    /** Set only by "I already donated". Never cleared by the app. */
    fun silenceDonatePrompt() {
        prefs.edit().putBoolean(KEY_DONATE_SILENCED, true).apply()
    }
}
