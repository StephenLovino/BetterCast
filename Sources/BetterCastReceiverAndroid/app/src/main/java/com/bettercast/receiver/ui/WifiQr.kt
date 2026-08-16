package com.bettercast.receiver.ui

import android.graphics.Bitmap
import android.graphics.Color
import androidx.compose.foundation.Image
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.FilterQuality
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter

/**
 * Standard Wi-Fi QR (`WIFI:S:<ssid>;T:WPA;P:<pass>;;`) for the Mac's camera to read.
 *
 * Escaping matters: the spec requires `\`, `;`, `,`, `:` and `"` inside a value to be
 * backslash-escaped, and system-generated passphrases can contain them. Without this
 * the Mac would parse the value short and silently join with the wrong password.
 */
fun wifiQrPayload(ssid: String, passphrase: String): String {
    fun esc(v: String) = v.fold(StringBuilder()) { acc, c ->
        if (c in charArrayOf('\\', ';', ',', ':', '"')) acc.append('\\')
        acc.append(c)
    }.toString()
    return "WIFI:S:${esc(ssid)};T:WPA;P:${esc(passphrase)};;"
}

fun qrBitmap(content: String, size: Int = 512): Bitmap? = try {
    val matrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, size, size)
    Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).apply {
        for (x in 0 until size) {
            for (y in 0 until size) {
                setPixel(x, y, if (matrix[x, y]) Color.BLACK else Color.WHITE)
            }
        }
    }
} catch (e: Exception) {
    null
}

@Composable
fun WifiQrImage(ssid: String, passphrase: String, modifier: Modifier = Modifier) {
    val bitmap = remember(ssid, passphrase) { qrBitmap(wifiQrPayload(ssid, passphrase)) }
    bitmap?.let {
        Image(
            bitmap = it.asImageBitmap(),
            contentDescription = "Wi-Fi QR code for $ssid",
            modifier = modifier,
            filterQuality = FilterQuality.None
        )
    }
}
