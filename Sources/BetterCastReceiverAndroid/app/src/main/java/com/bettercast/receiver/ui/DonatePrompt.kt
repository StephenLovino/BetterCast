package com.bettercast.receiver.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.bettercast.receiver.R
import com.bettercast.receiver.data.SettingsStore
import com.bettercast.receiver.ui.theme.BC

/**
 * Launch-time donation nudge, matching the Mac app's prompt.
 *
 * "Stop asking" is honour-system: the app has no licence check and no server, so whether
 * somebody actually donated is not knowable here. Anyone can press it. That is the
 * deliberate trade against building key entry and a verification service for what is a
 * voluntary contribution.
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

    AlertDialog(
        onDismissRequest = onLater,
        icon = {
            Icon(Icons.Filled.Favorite, contentDescription = null, tint = BC.primary)
        },
        title = {
            Text(
                stringResource(R.string.donate_title),
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth()
            )
        },
        text = {
            Text(stringResource(R.string.donate_body), textAlign = TextAlign.Center)
        },
        confirmButton = {
            TextButton(onClick = { openDonate() }) {
                Text(stringResource(R.string.donate_action))
            }
        },
        dismissButton = {
            // Both remaining choices live here so the row reads later / never, rather
            // than burying the permanent opt-out where nobody finds it.
            Column(
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(0.dp),
                modifier = Modifier.padding(end = 4.dp)
            ) {
                TextButton(onClick = onLater) {
                    Text(stringResource(R.string.donate_later))
                }
                TextButton(onClick = onAlreadyDonated) {
                    Text(stringResource(R.string.donate_already))
                }
            }
        }
    )
}
