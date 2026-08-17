package com.bettercast.receiver.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.bettercast.receiver.R
import com.bettercast.receiver.data.SettingsStore
import com.bettercast.receiver.ui.components.GlassButton
import com.bettercast.receiver.ui.components.GradientButton
import com.bettercast.receiver.ui.theme.BC
import com.bettercast.receiver.ui.theme.BCType

/**
 * Launch-time donation nudge, matching the Mac app's prompt.
 *
 * "Stop asking" is honour-system: the app has no licence check and no server, so whether
 * somebody actually donated is not knowable here. Anyone can press it. That is the
 * deliberate trade against building key entry and a verification service for what is a
 * voluntary contribution.
 *
 * Built as a plain [Dialog] rather than a Material3 `AlertDialog`. There are three
 * actions, and AlertDialog only has slots for two — stacking a Column into its
 * `dismissButton` broke the button row's measurement: a dead gap opened between the
 * first two actions and the third was clipped by the dialog's bottom edge. A single
 * vertical stack also matches the Mac layout and the app's own glass styling, which the
 * default AlertDialog chrome did not.
 */
@Composable
fun DonatePromptDialog(
    onLater: () -> Unit,
    onAlreadyDonated: () -> Unit
) {
    val context = LocalContext.current

    fun openDonate() {
        runCatching {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(SettingsStore.DONATE_URL)))
        }
    }

    Dialog(onDismissRequest = onLater) {
        val shape = RoundedCornerShape(BC.cardRadius)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .clip(shape)
                // Two layers on purpose: glassFill is translucent and is meant to sit
                // over the app background. In a dialog there is only the scrim behind,
                // so it needs an opaque base or the blurred screen shows through.
                .background(BC.background)
                .background(BC.glassFill)
                .border(BorderStroke(1.dp, BC.glassStroke), shape)
                .padding(horizontal = 22.dp, vertical = 24.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Icon(
                Icons.Filled.Favorite,
                contentDescription = null,
                tint = BC.primary,
                modifier = Modifier.size(36.dp)
            )

            Spacer(Modifier.height(14.dp))

            Text(
                stringResource(R.string.donate_title),
                style = BCType.cardTitle,
                color = BC.onSurface,
                textAlign = TextAlign.Center
            )

            Spacer(Modifier.height(10.dp))

            Text(
                stringResource(R.string.donate_body),
                style = BCType.bodySmall,
                color = BC.onSurfaceVariant,
                textAlign = TextAlign.Center
            )

            Spacer(Modifier.height(22.dp))

            GradientButton(
                text = stringResource(R.string.donate_action),
                onClick = { openDonate() },
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(Modifier.height(10.dp))

            GlassButton(
                text = stringResource(R.string.donate_later),
                onClick = onLater,
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(Modifier.height(16.dp))

            // Quiet by design: permanent, and not the action most people should take.
            Text(
                stringResource(R.string.donate_already),
                style = BCType.label,
                color = BC.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .clip(RoundedCornerShape(6.dp))
                    .clickable { onAlreadyDonated() }
                    .padding(horizontal = 10.dp, vertical = 6.dp)
            )
        }
    }
}
