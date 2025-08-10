package vn.hunghd.flutterdownloader

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.net.URLConnection
import kotlin.jvm.Synchronized
import android.provider.MediaStore
import android.content.ContentUris
import androidx.annotation.RequiresApi
import android.database.Cursor

object IntentUtils {
    private fun buildIntent(context: Context, file: File, mime: String?): Intent {
        val intent = Intent(Intent.ACTION_VIEW)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            val uri = FileProvider.getUriForFile(
                context,
                context.packageName + ".flutter_downloader.provider",
                file
            )
            intent.setDataAndType(uri, mime)
        } else {
            intent.setDataAndType(Uri.fromFile(file), mime)
        }
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return intent
    }

    @Synchronized
fun validatedFileIntent(context: Context, path: String, contentType: String?): Intent? {
    val file = File(path)

    // If the file still exists on disk, use FileProvider as before.
    if (file.exists()) {
        var intent = buildIntent(context, file, contentType)
        if (canBeHandled(context, intent)) return intent

        // MIME sniffing only if the file actually exists
        var mime: String? = null
        try {
            FileInputStream(file).use { fis ->
                mime = URLConnection.guessContentTypeFromStream(fis)
            }
        } catch (_: IOException) { /* ignore */ }

        if (mime == null) mime = URLConnection.guessContentTypeFromName(path)
        if (mime != null) {
            intent = buildIntent(context, file, mime)
            if (canBeHandled(context, intent)) return intent
        }
        return null
    }

    // Android Q+: file was likely moved to public Downloads via MediaStore
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        val name = file.name
        val uri = findDownloadByDisplayName(context, name) ?: return null

        val mime = contentType ?: context.contentResolver.getType(uri)
        return Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }.takeIf { canBeHandled(context, it) }
    }

    return null
}

// NEW helper inside IntentUtils.kt
@RequiresApi(Build.VERSION_CODES.Q)
private fun findDownloadByDisplayName(context: Context, fileName: String): Uri? {
    val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
    val projection = arrayOf(MediaStore.Downloads._ID, MediaStore.Downloads.DISPLAY_NAME)
    val sel = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
    val args = arrayOf(fileName)

    return context.contentResolver
  .query(collection, projection, sel, args, null)
  ?.use { c: Cursor ->
      if (c.moveToFirst()) {
          val id = c.getLong(c.getColumnIndexOrThrow(MediaStore.Downloads._ID))
          ContentUris.withAppendedId(collection, id)
      } else null
  }
}

    private fun canBeHandled(context: Context, intent: Intent): Boolean {
        val manager = context.packageManager
        val results = manager.queryIntentActivities(intent, 0)
        // return if there is at least one app that can handle this intent
        return results.size > 0
    }
}
