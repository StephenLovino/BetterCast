package com.bettercast.receiver.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import com.bettercast.receiver.data.ThemeMode

/**
 * Design tokens lifted from the iOS receiver so both apps read as one product.
 *
 * The dark values are the literals used in `OnboardingView.swift`. The light values
 * follow `SetupGuideView.swift`, which switches surfaces to the system light palette
 * while holding the brand colours fixed. Keep them in sync by hand — there is no shared
 * asset pipeline between the two codebases.
 */
@Immutable
data class BCPalette(
    val background: Color,
    val onSurface: Color,
    val onSurfaceVariant: Color,
    val primary: Color,
    val primaryDim: Color,
    val secondary: Color,
    val secondaryDim: Color,
    val accentGold: Color,
    val accentOrange: Color,
    val success: Color,
    val danger: Color,
    val glassFill: Color,
    val glassStroke: Color,
    val navBar: Color,
    val segmentTrack: Color,
    val segmentThumb: Color,
    val isDark: Boolean
)

private val DarkPalette = BCPalette(
    background = Color(0xFF131314),
    onSurface = Color(0xFFE5E2E3),
    onSurfaceVariant = Color(0xFFC1C6D7),
    primary = Color(0xFF4B8EFF),
    primaryDim = Color(0xFFADC6FF),
    secondary = Color(0xFF5DE6FF),
    secondaryDim = Color(0xFF2FD9F4),
    accentGold = Color(0xFFFFD60A),
    accentOrange = Color(0xFFEF6719),
    success = Color(0xFF32D74B),
    danger = Color(0xFFFF453A),
    glassFill = Color(0x0FFFFFFF),
    glassStroke = Color(0x1AFFFFFF),
    navBar = Color(0xE61C1C1E),
    segmentTrack = Color(0xFF1C1C1E),
    segmentThumb = Color(0xFF3A3A3C),
    isDark = true
)

// Light is not a straight inversion. On white, the mid-blue and cyan that carry the
// brand in dark mode fail contrast at small sizes, so text-bearing accents step down a
// few shades while the gradient and status colours stay as they are.
private val LightPalette = BCPalette(
    background = Color(0xFFF2F2F7),
    onSurface = Color(0xFF1C1C1E),
    onSurfaceVariant = Color(0xFF5F6570),
    primary = Color(0xFF0A66E0),
    primaryDim = Color(0xFF1D5FD0),
    secondary = Color(0xFF0091B3),
    secondaryDim = Color(0xFF00799A),
    accentGold = Color(0xFFB88600),
    accentOrange = Color(0xFFD1550C),
    success = Color(0xFF1D9E36),
    danger = Color(0xFFD62F26),
    glassFill = Color(0xFFFFFFFF),
    glassStroke = Color(0x14000000),
    navBar = Color(0xF2FFFFFF),
    segmentTrack = Color(0xFFE3E3E8),
    segmentThumb = Color(0xFFFFFFFF),
    isDark = false
)

val LocalBCPalette = staticCompositionLocalOf { DarkPalette }

/**
 * Token accessors. These read the palette from the composition, so every call site
 * follows the active theme without threading colours through parameters.
 */
object BC {
    val background: Color @Composable get() = LocalBCPalette.current.background
    val onSurface: Color @Composable get() = LocalBCPalette.current.onSurface
    val onSurfaceVariant: Color @Composable get() = LocalBCPalette.current.onSurfaceVariant
    val primary: Color @Composable get() = LocalBCPalette.current.primary
    val primaryDim: Color @Composable get() = LocalBCPalette.current.primaryDim
    val secondary: Color @Composable get() = LocalBCPalette.current.secondary
    val secondaryDim: Color @Composable get() = LocalBCPalette.current.secondaryDim
    val accentGold: Color @Composable get() = LocalBCPalette.current.accentGold
    val accentOrange: Color @Composable get() = LocalBCPalette.current.accentOrange
    val success: Color @Composable get() = LocalBCPalette.current.success
    val danger: Color @Composable get() = LocalBCPalette.current.danger
    val glassFill: Color @Composable get() = LocalBCPalette.current.glassFill
    val glassStroke: Color @Composable get() = LocalBCPalette.current.glassStroke
    val navBar: Color @Composable get() = LocalBCPalette.current.navBar
    val segmentTrack: Color @Composable get() = LocalBCPalette.current.segmentTrack
    val segmentThumb: Color @Composable get() = LocalBCPalette.current.segmentThumb
    val isDark: Boolean @Composable get() = LocalBCPalette.current.isDark

    /** Fixed in both themes — it is the brand mark, not a surface. */
    val liquidGradient = Brush.linearGradient(
        colors = listOf(Color(0xFF007AFF), Color(0xFF5DE6FF))
    )

    val cardRadius = 20.dp
    val buttonRadius = 14.dp
    val screenPadding = 20.dp

    /** Clearance for the floating nav pill so scrolled content is never trapped behind it. */
    val navClearance = 96.dp
}

/**
 * Type scale copied from the iOS views, including the negative tracking on display
 * sizes and the wide tracking on small caps labels — that spacing is a large part of why
 * the iOS screens read the way they do.
 *
 * The typeface itself cannot follow: SF Pro is licensed for Apple platforms only, so
 * this is the platform default at matching sizes and weights.
 */
object BCType {
    val display = TextStyle(fontSize = 32.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.5).sp)
    val headline = TextStyle(fontSize = 28.sp, fontWeight = FontWeight.Bold, letterSpacing = (-0.5).sp)
    val title = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold)
    val cardTitle = TextStyle(fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
    val rowTitle = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Medium)
    val body = TextStyle(fontSize = 16.sp, fontWeight = FontWeight.Normal)
    val bodySmall = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Normal, lineHeight = 19.sp)
    val label = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Medium, letterSpacing = 0.6.sp)
    val badge = TextStyle(fontSize = 9.sp, fontWeight = FontWeight.SemiBold, letterSpacing = 0.6.sp)
    val button = TextStyle(fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
}

@Composable
fun BetterCastReceiverTheme(
    themeMode: ThemeMode = ThemeMode.DARK,
    content: @Composable () -> Unit
) {
    val dark = when (themeMode) {
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
        ThemeMode.LIGHT -> false
        ThemeMode.DARK -> true
    }
    val palette = if (dark) DarkPalette else LightPalette

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = palette.background.toArgb()
            window.navigationBarColor = palette.background.toArgb()
            // Bar glyphs have to invert with the surface or they vanish in light mode.
            WindowCompat.getInsetsController(window, view).apply {
                isAppearanceLightStatusBars = !dark
                isAppearanceLightNavigationBars = !dark
            }
        }
    }

    val scheme = if (dark) {
        darkColorScheme(
            primary = palette.primary,
            onPrimary = Color.White,
            secondary = palette.secondary,
            background = palette.background,
            onBackground = palette.onSurface,
            surface = palette.background,
            onSurface = palette.onSurface,
            onSurfaceVariant = palette.onSurfaceVariant,
            error = palette.danger
        )
    } else {
        lightColorScheme(
            primary = palette.primary,
            onPrimary = Color.White,
            secondary = palette.secondary,
            background = palette.background,
            onBackground = palette.onSurface,
            surface = Color.White,
            onSurface = palette.onSurface,
            onSurfaceVariant = palette.onSurfaceVariant,
            error = palette.danger
        )
    }

    CompositionLocalProvider(LocalBCPalette provides palette) {
        MaterialTheme(
            colorScheme = scheme,
            typography = Typography(
                titleLarge = BCType.title,
                bodyLarge = BCType.body,
                labelLarge = BCType.button
            ),
            content = content
        )
    }
}
