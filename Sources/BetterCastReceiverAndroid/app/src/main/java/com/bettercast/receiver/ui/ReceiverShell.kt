package com.bettercast.receiver.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AspectRatio
import androidx.compose.material.icons.filled.Cable
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material.icons.outlined.HelpOutline
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.annotation.StringRes
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import com.bettercast.receiver.BuildConfig
import com.bettercast.receiver.R
import com.bettercast.receiver.data.ThemeMode
import com.bettercast.receiver.ui.components.DisclosureRow
import com.bettercast.receiver.ui.components.RowDivider
import com.bettercast.receiver.ui.components.BCHeader
import com.bettercast.receiver.ui.components.GlassCard
import com.bettercast.receiver.ui.components.SegmentedRow
import com.bettercast.receiver.ui.components.SettingsSection
import com.bettercast.receiver.ui.components.StepCard
import com.bettercast.receiver.ui.components.ToggleRow
import com.bettercast.receiver.ui.theme.BC
import com.bettercast.receiver.ui.theme.BCType
import com.bettercast.receiver.viewmodel.ReceiverState
import com.bettercast.receiver.viewmodel.ReceiverViewModel

/**
 * Icons stand in for the iOS tab bar's SF Symbols — play.display, questionmark.circle
 * and slider.horizontal.3 have no exact match in Material, so these are the nearest
 * equivalents rather than a like-for-like port.
 */
enum class ReceiverTab(@StringRes val labelRes: Int, val icon: ImageVector) {
    CONNECT(R.string.tab_connect, Icons.Filled.PlayCircle),
    SETUP(R.string.tab_setup, Icons.Outlined.HelpOutline),
    SETTINGS(R.string.tab_settings, Icons.Filled.Tune)
}

@Composable
fun ReceiverShell(viewModel: ReceiverViewModel) {
    val state by viewModel.state.collectAsState()

    var tab by remember { mutableStateOf(ReceiverTab.CONNECT) }
    var navVisible by remember { mutableStateOf(true) }

    // A live stream takes the whole panel: the phone is a display at that point, and
    // chrome over the video is in the way. The user can bring the bar back from the
    // settings menu, so this only sets the default each time the state flips.
    LaunchedEffect(state) {
        navVisible = state != ReceiverState.CONNECTED
    }

    // Box rather than Column: the nav floats over the content instead of taking a slice
    // of the layout, so screens run the full height and scroll underneath it.
    Box(modifier = Modifier.fillMaxSize().background(BC.background)) {
        when (tab) {
            // ReceiverScreen already picks the right view for the current state, so
            // Connect can host it directly.
            ReceiverTab.CONNECT -> ReceiverScreen(
                viewModel = viewModel,
                navVisible = navVisible,
                onToggleNav = { navVisible = !navVisible },
                onShowSetup = {
                    // Show the bar first — otherwise Setup is a one-way trip.
                    navVisible = true
                    tab = ReceiverTab.SETUP
                }
            )
            ReceiverTab.SETUP -> SetupGuideTab()
            ReceiverTab.SETTINGS -> SettingsTab(
                viewModel = viewModel,
                onShowSetup = { tab = ReceiverTab.SETUP }
            )
        }

        AnimatedVisibility(
            visible = navVisible,
            enter = fadeIn() + slideInVertically { it },
            exit = fadeOut() + slideOutVertically { it },
            modifier = Modifier.align(Alignment.BottomCenter)
        ) {
            FloatingNav(selected = tab, onSelect = { tab = it })
        }
    }
}

/** Free-floating pill, in place of a full-width bar welded to the bottom edge. */
@Composable
private fun FloatingNav(selected: ReceiverTab, onSelect: (ReceiverTab) -> Unit) {
    val shape = RoundedCornerShape(28.dp)
    Row(
        modifier = Modifier
            .padding(horizontal = 28.dp, vertical = 18.dp)
            .shadow(20.dp, shape, spotColor = Color.Black.copy(alpha = 0.5f))
            .clip(shape)
            .background(BC.navBar)
            .border(BorderStroke(1.dp, BC.glassStroke), shape)
            .padding(horizontal = 6.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        ReceiverTab.entries.forEach { entry ->
            val isSelected = entry == selected
            Row(
                modifier = Modifier
                    .clip(CircleShape)
                    .background(if (isSelected) BC.primary.copy(alpha = 0.16f) else Color.Transparent)
                    .clickable { onSelect(entry) }
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                val label = stringResource(entry.labelRes)
                Icon(
                    entry.icon,
                    contentDescription = label,
                    tint = if (isSelected) BC.primary else BC.onSurfaceVariant.copy(alpha = 0.75f),
                    modifier = Modifier.size(20.dp)
                )
                // Only the active tab is labelled. Three permanent labels make the pill
                // as wide as the screen, which defeats the point of floating it.
                if (isSelected) {
                    Spacer(Modifier.width(6.dp))
                    Text(label, style = BCType.label, color = BC.primary)
                }
            }
        }
    }
}

/** Static walkthrough, moved off the waiting screen so Connect stays uncluttered. */
@Composable
private fun SetupGuideTab() {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BC.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BC.screenPadding)
    ) {
        BCHeader(Icons.Filled.PlayCircle)

        Text(stringResource(R.string.setup_title), style = BCType.display, color = BC.onSurface)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.setup_subtitle),
            style = BCType.bodySmall,
            color = BC.onSurfaceVariant
        )

        Spacer(Modifier.height(20.dp))

        StepCard(
            icon = Icons.Filled.Cable,
            iconColor = BC.primaryDim,
            title = stringResource(R.string.setup_usb_title),
            description = stringResource(R.string.setup_usb_desc),
            badge = stringResource(R.string.badge_best) to BC.success,
            extra = {
                NumberedSteps(
                    stringResource(R.string.setup_usb_step1),
                    stringResource(R.string.setup_usb_step2),
                    stringResource(R.string.setup_usb_step3),
                    stringResource(R.string.setup_usb_step4)
                )
            }
        )

        Spacer(Modifier.height(16.dp))

        StepCard(
            icon = Icons.Filled.QrCodeScanner,
            iconColor = BC.secondaryDim,
            title = stringResource(R.string.setup_wifi_title),
            description = stringResource(R.string.setup_wifi_desc),
            extra = {
                NumberedSteps(
                    stringResource(R.string.setup_wifi_step1),
                    stringResource(R.string.setup_wifi_step2),
                    stringResource(R.string.setup_wifi_step3)
                )
                Spacer(Modifier.height(12.dp))
                Callout(stringResource(R.string.setup_wifi_callout))
            }
        )

        Spacer(Modifier.height(16.dp))

        StepCard(
            icon = Icons.Filled.WifiTethering,
            iconColor = BC.accentGold,
            title = stringResource(R.string.setup_hotspot_title),
            description = stringResource(R.string.setup_hotspot_desc),
            extra = {
                NumberedSteps(
                    stringResource(R.string.setup_hotspot_step1),
                    stringResource(R.string.setup_hotspot_step2),
                    stringResource(R.string.setup_hotspot_step3)
                )
                Spacer(Modifier.height(12.dp))
                Callout(stringResource(R.string.setup_hotspot_callout))
            }
        )

        Spacer(Modifier.height(BC.navClearance))
    }
}

@Composable
private fun NumberedSteps(vararg steps: String) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        steps.forEachIndexed { index, step ->
            Row(verticalAlignment = Alignment.Top) {
                Text(
                    "${index + 1}",
                    style = BCType.badge,
                    color = BC.primaryDim,
                    modifier = Modifier
                        .background(BC.primary.copy(alpha = 0.15f), CircleShape)
                        .width(18.dp)
                        .padding(vertical = 3.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
                Spacer(Modifier.width(10.dp))
                Text(step, style = BCType.bodySmall, color = BC.onSurfaceVariant)
            }
        }
    }
}

/** Inline note — the things people get wrong, called out rather than buried in prose. */
@Composable
private fun Callout(text: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(BC.accentOrange.copy(alpha = 0.10f), RoundedCornerShape(10.dp))
            .padding(10.dp)
    ) {
        Text(text, style = BCType.bodySmall, color = BC.onSurfaceVariant)
    }
}

/**
 * Settings, following the section order of the iOS screen.
 *
 * "Hide Settings Button" is the one section that did not come across: it lives on the
 * in-stream gear menu, where the button it hides actually exists.
 */
@Composable
private fun SettingsTab(viewModel: ReceiverViewModel, onShowSetup: () -> Unit) {
    val context = LocalContext.current
    val settings = viewModel.settings

    val deviceName by settings.deviceName.collectAsState()
    val aspectFill by settings.aspectFill.collectAsState()
    val audioEnabled by settings.audioEnabled.collectAsState()
    val cursorMode by settings.cursorMode.collectAsState()
    val themeMode by settings.themeMode.collectAsState()
    val state by viewModel.state.collectAsState()

    var nameDraft by remember(deviceName) { mutableStateOf(deviceName) }

    fun open(url: String) {
        runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(BC.background)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = BC.screenPadding)
    ) {
        BCHeader(Icons.Filled.PlayCircle)

        Text(stringResource(R.string.settings_title), style = BCType.display, color = BC.onSurface)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.settings_subtitle),
            style = BCType.bodySmall,
            color = BC.onSurfaceVariant
        )

        Spacer(Modifier.height(22.dp))

        SettingsSection(stringResource(R.string.section_device), Icons.Filled.Devices) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(stringResource(R.string.setting_device_name), style = BCType.rowTitle, color = BC.onSurface)
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = nameDraft,
                    onValueChange = { nameDraft = it },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedTextColor = BC.onSurface,
                        unfocusedTextColor = BC.onSurface,
                        focusedBorderColor = BC.primary,
                        unfocusedBorderColor = BC.glassStroke,
                        cursorColor = BC.primary
                    )
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    stringResource(R.string.setting_device_name_desc),
                    style = BCType.bodySmall,
                    color = BC.onSurfaceVariant
                )
                if (nameDraft.trim() != deviceName) {
                    Spacer(Modifier.height(12.dp))
                    com.bettercast.receiver.ui.components.GradientButton(
                        text = stringResource(R.string.action_save_name),
                        onClick = { settings.setDeviceName(nameDraft) }
                    )
                }
            }
        }

        Spacer(Modifier.height(20.dp))

        SettingsSection(stringResource(R.string.section_display), Icons.Filled.AspectRatio) {
            SegmentedRow(
                icon = Icons.Filled.AspectRatio,
                iconColor = BC.primaryDim,
                title = stringResource(R.string.setting_aspect),
                description = stringResource(R.string.setting_aspect_desc),
                options = listOf(
                    stringResource(R.string.aspect_fill),
                    stringResource(R.string.aspect_fit)
                ),
                selectedIndex = if (aspectFill) 0 else 1,
                onSelect = { settings.setAspectFill(it == 0) }
            )
            RowDivider()
            SegmentedRow(
                icon = Icons.Filled.Contrast,
                iconColor = BC.secondaryDim,
                title = stringResource(R.string.setting_appearance),
                description = stringResource(R.string.setting_appearance_desc),
                options = listOf(
                    stringResource(R.string.theme_system),
                    stringResource(R.string.theme_light),
                    stringResource(R.string.theme_dark)
                ),
                selectedIndex = when (themeMode) {
                    ThemeMode.SYSTEM -> 0
                    ThemeMode.LIGHT -> 1
                    ThemeMode.DARK -> 2
                },
                onSelect = {
                    settings.setThemeMode(
                        when (it) {
                            0 -> ThemeMode.SYSTEM
                            1 -> ThemeMode.LIGHT
                            else -> ThemeMode.DARK
                        }
                    )
                }
            )
        }

        Spacer(Modifier.height(20.dp))

        SettingsSection(stringResource(R.string.section_input), Icons.Filled.TouchApp) {
            SegmentedRow(
                icon = Icons.Filled.TouchApp,
                iconColor = BC.secondaryDim,
                title = stringResource(R.string.setting_mode),
                description = stringResource(R.string.setting_mode_desc),
                options = listOf(
                    stringResource(R.string.mode_touch),
                    stringResource(R.string.mode_cursor)
                ),
                selectedIndex = if (cursorMode) 1 else 0,
                onSelect = { settings.setCursorMode(it == 1) }
            )
        }

        Spacer(Modifier.height(20.dp))

        SettingsSection(stringResource(R.string.section_audio), Icons.Filled.VolumeUp) {
            ToggleRow(
                icon = Icons.Filled.VolumeUp,
                iconColor = BC.primaryDim,
                title = stringResource(R.string.setting_audio),
                description = stringResource(R.string.setting_audio_desc),
                checked = audioEnabled,
                onCheckedChange = { settings.setAudioEnabled(it) }
            )
        }

        Spacer(Modifier.height(20.dp))

        if (state == ReceiverState.CONNECTED) {
            SettingsSection(stringResource(R.string.section_connection), Icons.Filled.Cable) {
                DisclosureRow(
                    icon = Icons.Filled.ErrorOutline,
                    iconColor = BC.accentOrange,
                    title = stringResource(R.string.action_disconnect),
                    subtitle = stringResource(R.string.action_disconnect_desc),
                    onClick = { viewModel.disconnect() }
                )
            }
            Spacer(Modifier.height(20.dp))
        }

        SettingsSection(stringResource(R.string.section_help), Icons.Outlined.HelpOutline) {
            DisclosureRow(
                icon = Icons.Outlined.HelpOutline,
                iconColor = BC.primaryDim,
                title = stringResource(R.string.help_setup_guide),
                subtitle = stringResource(R.string.help_setup_guide_desc),
                onClick = onShowSetup
            )
            RowDivider()
            DisclosureRow(
                icon = Icons.Filled.Info,
                iconColor = BC.secondaryDim,
                title = stringResource(R.string.help_about),
                subtitle = stringResource(R.string.help_about_desc),
                onClick = { open("https://bettercast.online") }
            )
            RowDivider()
            DisclosureRow(
                icon = Icons.Filled.ErrorOutline,
                iconColor = BC.accentOrange,
                title = stringResource(R.string.help_report),
                subtitle = stringResource(R.string.help_report_desc),
                onClick = { open("https://github.com/StephenLovino/BetterCast/issues") }
            )
        }

        Spacer(Modifier.height(24.dp))

        GlassCard(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                Text(stringResource(R.string.app_name), style = BCType.label, color = BC.onSurface)
                Spacer(Modifier.height(4.dp))
                Text(
                    stringResource(
                        R.string.version_format,
                        BuildConfig.VERSION_NAME,
                        BuildConfig.VERSION_CODE
                    ),
                    style = BCType.badge,
                    color = BC.onSurfaceVariant
                )
            }
        }

        Spacer(Modifier.height(BC.navClearance))
    }
}
