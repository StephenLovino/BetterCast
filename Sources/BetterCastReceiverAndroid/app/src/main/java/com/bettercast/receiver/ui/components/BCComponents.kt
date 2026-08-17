package com.bettercast.receiver.ui.components

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.bettercast.receiver.ui.theme.BC
import com.bettercast.receiver.ui.theme.BCType

/**
 * The iOS "glass card": rounded surface, faint white fill, hairline border, soft drop
 * shadow.
 *
 * iOS fills this with `.ultraThinMaterial`, which blurs whatever is behind it. Compose
 * has no backdrop-blur that works across the versions this app supports, so the fill is
 * a flat translucent white instead. Against the near-black background there is almost
 * nothing behind the card to blur, so the two land in nearly the same place visually.
 */
@Composable
fun GlassCard(
    modifier: Modifier = Modifier,
    cornerRadius: androidx.compose.ui.unit.Dp = BC.cardRadius,
    onClick: (() -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit
) {
    val shape = RoundedCornerShape(cornerRadius)
    Column(
        modifier = modifier
            .shadow(16.dp, shape, spotColor = Color.Black.copy(alpha = 0.37f))
            .clip(shape)
            .background(BC.glassFill)
            .border(BorderStroke(1.dp, BC.glassStroke), shape)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier),
        content = content
    )
}

/** Small caps pill, e.g. REQUIRED / RECOMMENDED. */
@Composable
fun BCBadge(text: String, color: Color, modifier: Modifier = Modifier) {
    Text(
        text = text,
        style = BCType.badge,
        color = color,
        modifier = modifier
            .clip(CircleShape)
            .background(color.copy(alpha = 0.15f))
            .padding(horizontal = 8.dp, vertical = 4.dp)
    )
}

/** Rounded square holding a tinted glyph — the leading element of every step card. */
@Composable
fun IconTile(icon: ImageVector, tint: Color, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .size(48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(tint.copy(alpha = 0.15f)),
        contentAlignment = Alignment.Center
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(24.dp))
    }
}

/** Primary action: the blue-to-cyan gradient, full width, 44dp tall. */
@Composable
fun GradientButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null
) {
    val shape = RoundedCornerShape(BC.buttonRadius)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(44.dp)
            .shadow(12.dp, shape, spotColor = BC.primary.copy(alpha = 0.5f))
            .clip(shape)
            .background(BC.liquidGradient)
            .clickable(onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, style = BCType.button, color = Color.White)
    }
}

/** Secondary action: same shape, glass fill instead of gradient. */
@Composable
fun GlassButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    tint: Color = BC.onSurface
) {
    val shape = RoundedCornerShape(BC.buttonRadius)
    Row(
        modifier = modifier
            .fillMaxWidth()
            .height(44.dp)
            .clip(shape)
            .background(BC.glassFill)
            .border(BorderStroke(1.dp, BC.glassStroke), shape)
            .clickable(onClick = onClick),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(text, style = BCType.button, color = tint)
    }
}

/** Wordmark row that opens every screen on iOS: tinted glyph, name, 56dp tall. */
@Composable
fun BCHeader(icon: ImageVector, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier.fillMaxWidth().height(56.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, tint = BC.primary, modifier = Modifier.size(24.dp))
        Spacer(Modifier.width(8.dp))
        Text(
            androidx.compose.ui.res.stringResource(com.bettercast.receiver.R.string.brand_bettercast),
            style = BCType.title,
            color = BC.onSurface
        )
    }
}

/**
 * Step card: icon tile, title, description, optional badge and action button. Mirrors
 * `stepCard` in SetupGuideView.swift.
 */
@Composable
fun StepCard(
    icon: ImageVector,
    iconColor: Color,
    title: String,
    description: String,
    badge: Pair<String, Color>? = null,
    actionText: String? = null,
    onAction: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
    extra: (@Composable ColumnScope.() -> Unit)? = null
) {
    GlassCard(modifier = modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                IconTile(icon, iconColor)
                Spacer(Modifier.width(14.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Text(title, style = BCType.cardTitle, color = BC.onSurface)
                    Spacer(Modifier.height(6.dp))
                    Text(description, style = BCType.bodySmall, color = BC.onSurfaceVariant)
                }
                if (badge != null) {
                    Spacer(Modifier.width(10.dp))
                    BCBadge(badge.first, badge.second)
                }
            }

            if (extra != null) {
                Spacer(Modifier.height(14.dp))
                extra()
            }

            if (actionText != null && onAction != null) {
                Spacer(Modifier.height(14.dp))
                GradientButton(actionText, onAction)
            }
        }
    }
}

// MARK: - Settings rows

/** Grouped section with a small-caps header, matching `section(title:icon:)` on iOS. */
@Composable
fun SettingsSection(
    title: String,
    icon: ImageVector,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 8.dp)) {
            Icon(icon, contentDescription = null, tint = BC.onSurfaceVariant, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(6.dp))
            Text(title, style = BCType.badge, color = BC.onSurfaceVariant)
        }
        GlassCard(modifier = Modifier.fillMaxWidth(), content = content)
    }
}

@Composable
fun ToggleRow(
    icon: ImageVector,
    iconColor: Color,
    title: String,
    description: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, tint = iconColor, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = BCType.rowTitle, color = BC.onSurface)
            Spacer(Modifier.height(2.dp))
            Text(description, style = BCType.bodySmall, color = BC.onSurfaceVariant)
        }
        Spacer(Modifier.width(12.dp))
        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White,
                checkedTrackColor = BC.primary,
                checkedBorderColor = BC.primary
            )
        )
    }
}

/** iOS-style segmented picker inside a settings row. */
@Composable
fun SegmentedRow(
    icon: ImageVector,
    iconColor: Color,
    title: String,
    description: String,
    options: List<String>,
    selectedIndex: Int,
    onSelect: (Int) -> Unit
) {
    Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, tint = iconColor, modifier = Modifier.size(22.dp))
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = BCType.rowTitle, color = BC.onSurface)
                Spacer(Modifier.height(2.dp))
                Text(description, style = BCType.bodySmall, color = BC.onSurfaceVariant)
            }
        }
        Spacer(Modifier.height(12.dp))
        Segmented(options = options, selectedIndex = selectedIndex, onSelect = onSelect)
    }
}

@Composable
fun Segmented(options: List<String>, selectedIndex: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(BC.segmentTrack)
            .padding(3.dp)
    ) {
        options.forEachIndexed { index, option ->
            val selected = index == selectedIndex
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(30.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(if (selected) BC.segmentThumb else Color.Transparent)
                    .clickable { onSelect(index) },
                contentAlignment = Alignment.Center
            ) {
                Text(
                    option,
                    style = BCType.button,
                    color = if (selected) BC.onSurface else BC.onSurfaceVariant
                )
            }
        }
    }
}

/** Tappable row that leads somewhere, with a chevron. */
@Composable
fun DisclosureRow(
    icon: ImageVector,
    iconColor: Color,
    title: String,
    subtitle: String,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(icon, contentDescription = null, tint = iconColor, modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(14.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = BCType.rowTitle, color = BC.onSurface)
            Spacer(Modifier.height(2.dp))
            Text(subtitle, style = BCType.bodySmall, color = BC.onSurfaceVariant)
        }
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = BC.onSurfaceVariant.copy(alpha = 0.6f),
            modifier = Modifier.size(20.dp)
        )
    }
}

@Composable
fun RowDivider() {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(start = 52.dp)
            .height(1.dp)
            .background(BC.glassStroke)
    )
}
