package vn.hunghd.flutterdownloader

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.*
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.provider.MediaStore
import android.util.Log
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.*
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.UnsupportedEncodingException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLDecoder
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.util.ArrayDeque
import java.util.HashMap
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean
import java.util.regex.Pattern
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import java.util.concurrent.TimeUnit
import java.util.UUID
import android.net.ConnectivityManager

/**
 * DownloadWorker.kt
 *
 * When a WorkManager worker runs, it opens an HTTP connection, streams bytes to a file,
 * updates a notification (with Pause/Resume/Cancel buttons), and reports progress/status
 * back to Dart via `backgroundChannel.invokeMethod("updateProgress", args)`.
 *
 * We do NOT call PluginUtilities.getCallbackFromHandle(...) here; instead, Dart listens
 * for “updateProgress” on its background channel and dispatches to the user’s callback.
 */
class DownloadWorker(context: Context, params: WorkerParameters) :
    Worker(context, params),
    MethodChannel.MethodCallHandler {

    // Patterns for parsing charset and filename from headers
    private val charsetPattern = Pattern.compile("(?i)\\bcharset=\\s*\"?([^\\s;\"]*)")
    private val filenameStarPattern =
        Pattern.compile("(?i)\\bfilename\\*=([^']+)'([^']*)'\"?([^\"]+)\"?")
    private val filenamePattern = Pattern.compile("(?i)\\bfilename=\"?([^\"]+)\"?")

    // Flutter background channel (to report progress back to Dart)
    private var backgroundChannel: MethodChannel? = null

    // Database helpers
    private var dbHelper: TaskDbHelper? = null
    private var taskDao: TaskDao? = null

    // Notification / state flags
    private var showNotification = false
    private var clickToOpenDownloadedFile = false
    private var debug = false
    private var ignoreSsl = false
    private var lastProgress = 0.0
    private var primaryId = 0
    private var msgStarted: String? = null
    private var msgInProgress: String? = null
    private var msgCanceled: String? = null
    private var msgFailed: String? = null
    private var msgPaused: String? = null
    private var msgComplete: String? = null
    private var lastCallUpdateNotification: Long = 0
    private var step = 0
    private var saveInPublicStorage = false

    // Download speed / remaining time tracking
    private var downloadStartTime: Long = 0
    private var downloadedBytesSoFar: Long = 0
    private var lastUpdateTime: Long = 0

    // --- Track pause/cancel state ---
    private var isPaused = false
    private var isManuallyStopped = false

    // BroadcastReceiver for “Pause / Resume / Cancel” button clicks in the notification
    private val downloadActionReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent == null) return
        // Grab the TASK_ID extra from the incoming broadcast:
        val sentTaskId = intent.getStringExtra("TASK_ID")
        // Only proceed if this worker’s id matches:
        if (sentTaskId != id.toString()) return

        when (intent.action) {
            ACTION_PAUSE  -> pauseDownload()
            ACTION_RESUME -> resumeDownload(intent)   // already expects "TASK_ID" inside intent
            ACTION_CANCEL -> cancelDownload()
        }
    }
}

    /**
     * Starts (or reuses) a headless FlutterEngine so we can send progress updates
     * back to Dart even if the app is in the background.  The Dart entrypoint
     * (callbackDispatcher) was already registered during plugin.initialize() on the Dart side.
     */
    private fun startBackgroundIsolate(context: Context) {
        synchronized(isolateStarted) {
            if (backgroundFlutterEngine == null) {
                val pref: SharedPreferences =
                    context.getSharedPreferences(
                        FlutterDownloaderPlugin.SHARED_PREFERENCES_KEY,
                        Context.MODE_PRIVATE
                    )
                val callbackHandle: Long = pref.getLong(
                    FlutterDownloaderPlugin.CALLBACK_DISPATCHER_HANDLE_KEY,
                    0
                )
                backgroundFlutterEngine = FlutterEngine(applicationContext, null, false)

                // Look up the Dart callback (callbackDispatcher) from the handle we stored earlier.
                val flutterCallback: FlutterCallbackInformation? =
                    FlutterCallbackInformation.lookupCallbackInformation(callbackHandle)
                if (flutterCallback == null) {
                    log("Fatal: failed to find callbackDispatcher")
                    return
                }
                val appBundlePath: String =
                    FlutterInjector.instance().flutterLoader().findAppBundlePath()
                val assets = applicationContext.assets
                backgroundFlutterEngine?.dartExecutor?.executeDartCallback(
                    DartExecutor.DartCallback(
                        assets,
                        appBundlePath,
                        flutterCallback
                    )
                )
            }
        }
        backgroundChannel = MethodChannel(
            backgroundFlutterEngine!!.dartExecutor,
            "vn.hunghd/downloader_background"
        )
        backgroundChannel?.setMethodCallHandler(this)

        // Register our BroadcastReceiver so “Pause / Resume / Cancel” intents get delivered
        val filter = IntentFilter().apply {
            addAction(ACTION_PAUSE)
            addAction(ACTION_RESUME)
            addAction(ACTION_CANCEL)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            applicationContext.registerReceiver(
                downloadActionReceiver,
                filter,
                Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            applicationContext.registerReceiver(downloadActionReceiver, filter)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // We only expect to receive "didInitializeDispatcher" from Dart to signal
        // that the Dart background isolate is up and running.  Once we see it,
        // we drain the queued arguments (if any).
        if (call.method == "didInitializeDispatcher") {
            synchronized(isolateStarted) {
                while (!isolateQueue.isEmpty()) {
                    backgroundChannel?.invokeMethod("", isolateQueue.removeFirst())
                }
                isolateStarted.set(true)
                result.success(null)
            }
        } else {
            result.notImplemented()
        }
    }

    /**
     * If the system kills our Worker (e.g. user pauses or cancels), we unregister
     * the BroadcastReceiver so we don’t leak it.
     */
    override fun onStopped() {
        try {
            applicationContext.unregisterReceiver(downloadActionReceiver)
        } catch (e: IllegalArgumentException) {
            // Receiver wasn’t registered or already unregistered
        }

        val context: Context = applicationContext
        dbHelper = TaskDbHelper.getInstance(context)
        taskDao = TaskDao(dbHelper!!)
        val url: String? = inputData.getString(ARG_URL)
        val filename: String? = inputData.getString(ARG_FILE_NAME)
        val task = taskDao?.loadTask(id.toString())
        if (task != null && task.status == DownloadStatus.ENQUEUED) {
            updateNotification(
                context,
                filename ?: url,
                DownloadStatus.CANCELED,
                -1.0,
                null,
                true
            )
            taskDao?.updateTask(id.toString(), DownloadStatus.CANCELED, lastProgress)
        }
        super.onStopped()
    }

    /**
     * This is the “main” WorkManager entry point.  We:
     * 1. Read all the arguments (URL, savedDir, headers, isResume, etc.)
     * 2. If “isResume = true”, we add a “Range:” header to pick up where we left off.
     * 3. Download bytes in a loop, writing to a partial file (append mode if resuming).
     * 4. On every “step”% or on finish, we call updateNotification(...)
     * 5. We also call sendUpdateProcessEvent(...) to push status/progress back to Dart.
     */
    override fun doWork(): Result {
        dbHelper = TaskDbHelper.getInstance(applicationContext)
        taskDao = TaskDao(dbHelper!!)
        val url: String =
            inputData.getString(ARG_URL)
                ?: throw IllegalArgumentException("Argument '$ARG_URL' should not be null")
        val filename: String? = inputData.getString(ARG_FILE_NAME)
        val savedDir: String = inputData.getString(ARG_SAVED_DIR)
            ?: throw IllegalArgumentException("Argument '$ARG_SAVED_DIR' should not be null")
        val headers: String = inputData.getString(ARG_HEADERS)
            ?: throw IllegalArgumentException("Argument '$ARG_HEADERS' should not be null")
        val isResume: Boolean = inputData.getBoolean(ARG_IS_RESUME, false)
        val timeout: Int = inputData.getInt(ARG_TIMEOUT, 15000)
        debug = inputData.getBoolean(ARG_DEBUG, false)
        step = inputData.getInt(ARG_STEP, 10)
        ignoreSsl = inputData.getBoolean(ARG_IGNORESSL, false)

        // Grab all of our localized strings from resources
        val res = applicationContext.resources
        msgStarted = res.getString(R.string.flutter_downloader_notification_started)
        msgInProgress = res.getString(R.string.flutter_downloader_notification_in_progress)
        msgCanceled = res.getString(R.string.flutter_downloader_notification_canceled)
        msgFailed = res.getString(R.string.flutter_downloader_notification_failed)
        msgPaused = res.getString(R.string.flutter_downloader_notification_paused)
        msgComplete = res.getString(R.string.flutter_downloader_notification_complete)

        downloadStartTime = System.currentTimeMillis()
        lastUpdateTime = downloadStartTime

        val task = taskDao?.loadTask(id.toString())
        log(
            "DownloadWorker{url=$url,filename=$filename,savedDir=$savedDir,header=$headers,isResume=$isResume,status="
                    + (task?.status ?: "GONE") +
                    "}"
        )

        // If the task is already canceled (or missing), we bail immediately
        if (task == null || task.status == DownloadStatus.CANCELED) {
            return Result.success()
        }

        // Read the boolean flags we passed in
        showNotification = inputData.getBoolean(ARG_SHOW_NOTIFICATION, false)
        clickToOpenDownloadedFile =
            inputData.getBoolean(ARG_OPEN_FILE_FROM_NOTIFICATION, false)
        saveInPublicStorage = inputData.getBoolean(ARG_SAVE_IN_PUBLIC_STORAGE, false)
        primaryId = task.primaryId

        // Show (or create) our notification channel if needed
        setupNotification(applicationContext)

        // Update the SQLite entry to “RUNNING” and show a “Starting download…” notification
        updateNotification(
            applicationContext,
            filename ?: "Starting Download...",
            DownloadStatus.RUNNING,
            task.progress,
            null,
            false
        )
        taskDao?.updateTask(id.toString(), DownloadStatus.RUNNING, task.progress)

        // If a partial file already exists, mark it resumable in the database
        val saveFilePath = savedDir + File.separator + filename
        val partialFile = File(saveFilePath)
        if (partialFile.exists()) {
            taskDao?.updateTaskResumable(id.toString(), true)
            log("Partial file exists for $filename; automatic resume next time.")
        }

        // Reset pause flag when we start
        isPaused = false

        return try {
            downloadFile(
                applicationContext,
                url,
                savedDir,
                filename,
                headers,
                isResume,
                timeout
            )
             cleanUp()
            dbHelper = null
            taskDao = null
            Result.success()
        } catch (e: Exception) {
            // On any error, mark it FAILED and notify both SQLite + notification
            updateNotification(
                applicationContext,
                filename ?: "Download failed",
                DownloadStatus.FAILED,
                -1.0,
                null,
                true
            )
            taskDao?.updateTask(id.toString(), DownloadStatus.FAILED, lastProgress)
            e.printStackTrace()
            dbHelper = null
            taskDao = null
            Result.failure()
        }
    }

    /**
     * Helper to set any custom HTTP headers on our HttpURLConnection.
     */
    private fun setupHeaders(conn: HttpURLConnection, headers: String) {
        if (headers.isNotEmpty()) {
            log("Headers = $headers")
            try {
                val json = JSONObject(headers)
                val it = json.keys() // Kotlin will infer java.util.Iterator<String>
                while (it.hasNext()) {
                    val key = it.next()
                    conn.setRequestProperty(key, json.getString(key))
                }
                conn.doInput = true
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    /**
     * If isResume==true, add an HTTP “Range: bytes=${downloaded}-” header to pick up
     * from where we left off.
     * Returns how many bytes were already on disk.
     */
    private fun setupPartialDownloadedDataHeader(
        conn: HttpURLConnection,
        filename: String?,
        savedDir: String
    ): Long {
        val saveFilePath = savedDir + File.separator + filename
        val partialFile = File(saveFilePath)
        val downloadedBytes: Long = partialFile.length()
        log("Resuming download: Range: bytes=$downloadedBytes-")
        conn.setRequestProperty("Accept-Encoding", "identity")
        conn.setRequestProperty("Range", "bytes=$downloadedBytes-")
        conn.doInput = true
        return downloadedBytes
    }

    /**
     * The “meat” of the worker: open an HttpURLConnection, follow redirects up to 3×,
     * stream bytes into either a brand‐new file (when isResume=false) or append to an
     * existing partial file (when isResume=true).  On every “step”, do three things:
     *  1) write to the OutputStream
     *  2) update the SQLite row’s progress
     *  3) call updateNotification(...) to refresh the notification
     *  4) call sendUpdateProcessEvent(...) to send progress back to Dart
     */
   private fun downloadFile(
    context: Context,
    fileURL: String,
    savedDir: String,
    filename: String?,
    headers: String,
    isResume: Boolean,
    timeout: Int
) {
    var actualFilename = filename
    var url = fileURL
    var resourceUrl: URL
    var base: URL?
    var next: URL
    val visited: MutableMap<String, Int> = HashMap()
    var httpConn: HttpURLConnection? = null
    var inputStream: InputStream? = null
    var outputStream: OutputStream? = null
    var downloadedBytes: Long = 0
    var responseCode: Int
    var times: Int

    // 0) Grab the “old” task ID (if this is a resume) so we can keep sending progress under that ID.
    val oldTaskId: String? = inputData.getString("OLD_TASK_ID")

    // Helper that sends progress using either oldTaskId or the new WorkRequest ID
    fun sendProgress(status: DownloadStatus, progress: Double) {
        val taskIdToUse = oldTaskId ?: id.toString()
        val callbackHandle: Long = inputData.getLong(ARG_CALLBACK_HANDLE, 0L)
        val args = listOf<Any>(callbackHandle, taskIdToUse, status.ordinal, progress)
        synchronized(isolateStarted) {
            if (!isolateStarted.get()) {
                isolateQueue.add(args)
            } else {
                Handler(applicationContext.mainLooper).post {
                    backgroundChannel?.invokeMethod("updateProgress", args)
                }
            }
        }
    }

    try {
        // Load current progress from DB (for lastProgress)
        val task = taskDao?.loadTask(id.toString())
        if (task != null) {
            lastProgress = task.progress
        }

        // 1) Follow redirects up to 3×
        while (true) {
            if (!visited.containsKey(url)) {
                times = 1
                visited[url] = times
            } else {
                times = visited[url]!! + 1
                visited[url] = times
            }
            if (times > 3) throw IOException("Stuck in redirect loop")

            resourceUrl = URL(url)
            httpConn = if (ignoreSsl) {
                trustAllHosts()
                if (resourceUrl.protocol.lowercase(Locale.US) == "https") {
                    val https: HttpsURLConnection =
                        resourceUrl.openConnection() as HttpsURLConnection
                    https.hostnameVerifier = DO_NOT_VERIFY
                    https
                } else {
                    resourceUrl.openConnection() as HttpURLConnection
                }
            } else {
                if (resourceUrl.protocol.lowercase(Locale.US) == "https") {
                    resourceUrl.openConnection() as HttpsURLConnection
                } else {
                    resourceUrl.openConnection() as HttpURLConnection
                }
            }

            log("Opening connection to $url")
            httpConn!!.connectTimeout = timeout
            httpConn.readTimeout = timeout
            httpConn.instanceFollowRedirects = false
            httpConn.setRequestProperty("User-Agent", "Mozilla/5.0...")

            // Apply custom headers
            setupHeaders(httpConn, headers)

            // If this is a resume, add the “Range:” header based on the partial file in app-specific dir
            if (isResume) {
                val resumeFile = File(savedDir, actualFilename ?: "")
                downloadedBytes = resumeFile.length()
                log("Resuming download: Range: bytes=$downloadedBytes-")
                httpConn.setRequestProperty("Accept-Encoding", "identity")
                httpConn.setRequestProperty("Range", "bytes=$downloadedBytes-")
                httpConn.doInput = true
            }

            responseCode = httpConn.responseCode
            when (responseCode) {
                HttpURLConnection.HTTP_MOVED_PERM,
                HttpURLConnection.HTTP_SEE_OTHER,
                HttpURLConnection.HTTP_MOVED_TEMP,
                307,
                308 -> {
                    log("Redirect response ($responseCode)")
                    val location = httpConn.getHeaderField("Location")
                    log("→ Location = $location")
                    base = URL(url)
                    next = URL(base, location)
                    url = next.toExternalForm()
                    log("→ New URL: $url")
                    continue
                }
            }
            break
        }

        // Actually connect now
        httpConn!!.connect()

        // ────────────────────────────────────────────────────────────────────────────────
        // If server returns 416, treat as “complete”
        if (isResume && responseCode == 416) {
            log("Server responded 416 (Range Not Satisfiable); marking task as COMPLETE.")
            taskDao?.updateTask(id.toString(), DownloadStatus.COMPLETE, 100.0)
            updateNotification(
                context,
                actualFilename,
                DownloadStatus.COMPLETE,
                100.0,
                null,
                true
            )
            sendProgress(DownloadStatus.COMPLETE, 100.0)
            return
        }
        // ────────────────────────────────────────────────────────────────────────────────

        // If 200 (OK) or 206 (Partial) and not canceled
        if ((responseCode == HttpURLConnection.HTTP_OK
                    || (isResume && responseCode == HttpURLConnection.HTTP_PARTIAL))
            && !(isManuallyStopped || isStopped)
        ) {
            val contentType: String? = httpConn.contentType
            val contentLength: Long = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N)
                httpConn.contentLengthLong
            else
                httpConn.contentLength.toLong()

            if (contentType != null) {
                log("Content-Type = $contentType")
            }
            log("Content-Length = $contentLength")

            val charset = getCharsetFromContentType(contentType)
            log("Charset = $charset")

            // If not resuming, derive the filename
            if (!isResume) {
    if (actualFilename == null) {
        val disposition: String? = httpConn.getHeaderField("Content-Disposition")
        log("Content-Disposition = $disposition")
        if (!disposition.isNullOrEmpty()) {
            actualFilename = getFileNameFromContentDisposition(disposition, charset)
        }
        if (actualFilename.isNullOrEmpty()) {
            actualFilename = url.substring(url.lastIndexOf("/") + 1)
            try {
                actualFilename = URLDecoder.decode(actualFilename, "UTF-8")
            } catch (e: IllegalArgumentException) {
                e.printStackTrace()
            }
        }
    }
}
log("Resolved filename = $actualFilename")

// ─── Update database with "final" name before opening streams ───
taskDao?.updateTask(id.toString(), actualFilename, contentType)
inputStream = httpConn.inputStream

// ─── Build outputStream: ───
val savedFile: File
if (isResume) {
    // Resuming: always append to the same file in app-specific dir
    savedFile = File(savedDir, actualFilename ?: "")
    outputStream = FileOutputStream(savedFile, true)
} else {
    // ─ Ensure the directory exists ─
    val dirFile = File(savedDir)
    if (!dirFile.exists()) {
        dirFile.mkdirs()
    }

    // ─ If a file with that name already exists, pick a unique name ─
    var finalFilename = actualFilename!!
    val baseName: String
    val extPart: String

    val dotIndex = finalFilename.lastIndexOf('.')
    if (dotIndex != -1) {
        baseName = finalFilename.substring(0, dotIndex)
        extPart = finalFilename.substring(dotIndex)  // includes the dot, e.g. ".mp4"
    } else {
        baseName = finalFilename
        extPart = ""
    }

    var candidateFile = File(savedDir, finalFilename)
    var counter = 1
    while (candidateFile.exists()) {
        finalFilename = "$baseName($counter)$extPart"
        candidateFile = File(savedDir, finalFilename)
        counter++
    }
    // Now `finalFilename` is guaranteed not to collide with an existing file
    actualFilename = finalFilename

    // ─ Update DB with the adjusted filename ─
    taskDao?.updateTask(id.toString(), actualFilename, contentType)

    // ─ Finally create the brand‐new file on disk ─
    val created = candidateFile.createNewFile()
    if (!created) {
        throw IOException("Could not create file: ${candidateFile.absolutePath}")
    }
    savedFile = candidateFile
    outputStream = FileOutputStream(savedFile, false)
}
val savedFilePath = savedFile.path

            // ─────────────────────────────────────────────────────────────────────────────

            var count = downloadedBytes
            var bytesRead: Int
            val buffer = ByteArray(BUFFER_SIZE)

            while (inputStream.read(buffer).also { bytesRead = it } != -1) {
                if (isManuallyStopped || isStopped) {
                    log("Download stopped (paused or canceled)")
                    break
                }
                count += bytesRead.toLong()
                val progress =
                    (count * 100.0 / (contentLength + downloadedBytes)).coerceAtMost(100.0)
                outputStream?.write(buffer, 0, bytesRead)

                if ((lastProgress == 0.0 || progress > lastProgress + step || progress == 100.0)
                    && progress != lastProgress
                ) {
                    lastProgress = progress
                    downloadedBytesSoFar = count
                    val currentTime = System.currentTimeMillis()
                    val timeElapsed = currentTime - downloadStartTime
                    val speedBytesPerSec =
                        if (timeElapsed > 0) (downloadedBytesSoFar * 1000 / timeElapsed) else 0
                    val remainingBytes = (contentLength + downloadedBytes) - downloadedBytesSoFar
                    val estimatedRemainingTimeSec =
                        if (speedBytesPerSec > 0) (remainingBytes / speedBytesPerSec) else -1

                    val speedText = if (speedBytesPerSec > 0) {
                        val speedKB = speedBytesPerSec / 1024.0
                        if (speedKB >= 1024) {
                            val speedMB = speedKB / 1024.0
                            String.format(Locale.US, "%.2f MB/s", speedMB)
                        } else {
                            String.format(Locale.US, "%.0f KB/s", speedKB)
                        }
                    } else {
                        "Calculating..."
                    }

                    val timeText =
                        if (estimatedRemainingTimeSec >= 0)
                            formatRemainingTime(estimatedRemainingTimeSec)
                        else
                            "Unknown time left"

                    val progressText = "$speedText · $timeText"

                    taskDao!!.updateTask(id.toString(), DownloadStatus.RUNNING, progress)
                    updateNotification(
                        context,
                        actualFilename,
                        DownloadStatus.RUNNING,
                        progress,
                        null,
                        false,
                        progressText
                    )
                    // Replace old call with our helper
                    sendProgress(DownloadStatus.RUNNING, progress)
                }
            }

            // Determine final status + progress
            val loadedTask = taskDao?.loadTask(id.toString())
            val wasStopped = isManuallyStopped || isStopped
            val finalProgress = if (wasStopped && loadedTask!!.resumable) lastProgress else 100.0
            val finalStatus = if (wasStopped) {
                if (loadedTask?.resumable == true) DownloadStatus.PAUSED else DownloadStatus.CANCELED
            } else {
                DownloadStatus.COMPLETE
            }

            if (finalStatus == DownloadStatus.COMPLETE &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                saveInPublicStorage
            ) {
                try {
                    // 1️⃣ Check if already exists (avoid duplicates)
                    val existingUri = findExistingDownloadUri(actualFilename!!)
                    if (existingUri != null) {
                        log("Public download already exists, skipping copy")
                        return
                    }

                    // 2️⃣ Create MediaStore entry
                    val uri = createFileInPublicDownloadsDir(actualFilename, contentType)
                    if (uri != null) {
                        // 3️⃣ COPY (never move)
                        applicationContext.contentResolver
                            .openOutputStream(uri, "w")
                            ?.use { dest ->
                                File(savedFilePath).inputStream().use { src ->
                                    src.copyTo(dest)
                                }
                            }

                        Thread.sleep(3000)
                        log("After copy, app file exists = ${File(savedFilePath).exists()}")

                        log("Copied file to public Downloads: $actualFilename")
                    }
                } catch (e: Exception) {
                    logError("Failed copying to Downloads: ${e.message}")
                }
            }

            val storage: Int = ContextCompat.checkSelfPermission(
                applicationContext,
                Manifest.permission.WRITE_EXTERNAL_STORAGE
            )
            var pendingIntent: PendingIntent? = null
            if (finalStatus == DownloadStatus.COMPLETE) {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
                    if (isImageOrVideoFile(contentType) && isExternalStoragePath(savedFilePath)) {
                        addImageOrVideoToGallery(
                            actualFilename,
                            savedFilePath,
                            getContentTypeWithoutCharset(contentType)
                        )
                    }
                }
                if (clickToOpenDownloadedFile) {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
                        storage != PackageManager.PERMISSION_GRANTED
                    ) return
                    val intent = IntentUtils.validatedFileIntent(
                        applicationContext,
                        savedFilePath,
                        contentType
                    )
                    if (intent != null) {
                        log("Setting intent to open file: $savedFilePath")
                        val flags: Int =
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                                PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
                            else
                                PendingIntent.FLAG_CANCEL_CURRENT
                        pendingIntent = PendingIntent.getActivity(
                            applicationContext,
                            0,
                            intent,
                            flags
                        )
                    } else {
                        log("No app can open $savedFilePath")
                    }
                }
            }

            taskDao!!.updateTask(id.toString(), finalStatus, finalProgress)
            updateNotification(
                context,
                actualFilename,
                finalStatus,
                finalProgress,
                pendingIntent,
                true
            )
            // Final callback under the correct ID
            sendProgress(finalStatus, finalProgress)
            log(if (wasStopped) "Download canceled/paused" else "Download complete")
        } else {
            // Canceled or unexpected response code
            val loadedTask = taskDao!!.loadTask(id.toString())
            val wasStopped = isManuallyStopped || isStopped
            val status = if (wasStopped)
                if (loadedTask?.resumable == true) DownloadStatus.PAUSED else DownloadStatus.CANCELED
            else
                DownloadStatus.FAILED

            taskDao!!.updateTask(id.toString(), status, lastProgress)
            updateNotification(
                context,
                filename ?: fileURL,
                status,
                -1.0,
                null,
                true
            )
            sendProgress(status, -1.0)
            log(
                if (wasStopped) "Download canceled/paused"
                else "HTTP $responseCode, marked FAILED"
            )
        }
    } catch (e: IOException) {
        if (!isNetworkAvailable()) {
        // Treat loss of connectivity as a pause
        log("Network lost: pausing download")
        taskDao!!.updateTask(id.toString(), DownloadStatus.PAUSED, lastProgress)
        updateNotification(
            context,
            filename ?: fileURL.substringAfterLast("/"),
            DownloadStatus.PAUSED,
            lastProgress,
            null,
            true
        )
        sendProgress(DownloadStatus.PAUSED, lastProgress)
    } else {
        // Some other I/O error → real failure
        logError("Download error: ${e.message}")
        taskDao!!.updateTask(id.toString(), DownloadStatus.FAILED, lastProgress)
        updateNotification(
            context,
            filename ?: "Download failed",
            DownloadStatus.FAILED,
            -1.0,
            null,
            true
        )
        sendProgress(DownloadStatus.FAILED, -1.0)
    }
        e.printStackTrace()
    } finally {
        outputStream?.flush()
        outputStream?.close()
        inputStream?.close()
        httpConn?.disconnect()
    }
}

private fun isNetworkAvailable(): Boolean {
    val cm = applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE)
            as ConnectivityManager
    // activeNetworkInfo is nullable
    val networkInfo = cm.activeNetworkInfo
    return networkInfo?.isConnected == true
}


    /**
     * Format remaining seconds into “Xm Ys left” or “Zs left.”
     */
    private fun formatRemainingTime(seconds: Long): String {
        val minutes = seconds / 60
        val secs = seconds % 60
        return if (minutes > 0) {
            "${minutes}m ${secs}s left"
        } else {
            "${secs}s left"
        }
    }

    /**
     * Create a brand‐new file under “savedDir/filename” (java.io API).
     */
    private fun createFileInAppSpecificDir(filename: String, savedDir: String): File? {
        val newFile = File(savedDir, filename)
        try {
            val rs: Boolean = newFile.createNewFile()
            if (rs) {
                return newFile
            } else {
                logError("Could not create file in app‐specific dir")
            }
        } catch (e: IOException) {
            e.printStackTrace()
            logError("createFileInAppSpecificDir failed: ${e.message}")
        }
        return null
    }

    /**
     * For Android Q+ with “saveInPublicStorage = true,” we insert a row into MediaStore.Downloads
     * so the file ends up in the public Download folder.  This returns a URI we can open an
     * OutputStream on.
     */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun createFileInPublicDownloadsDir(filename: String?, mimeType: String?): Uri? {
        val collection: Uri = MediaStore.Downloads.EXTERNAL_CONTENT_URI
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, filename)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        }
        val contentResolver = applicationContext.contentResolver
        return try {
            contentResolver.insert(collection, values)
        } catch (e: Exception) {
            e.printStackTrace()
            logError("createFileInPublicDownloadsDir failed: ${e.message}")
            null
        }
    }

      /**
   * Look up the MediaStore.Downloads URI for an existing file named `fileName`.
   * Returns null if no matching row is found.
   */
  @RequiresApi(Build.VERSION_CODES.Q)
private fun findExistingDownloadUri(fileName: String): Uri? {
  val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
  val projection = arrayOf(MediaStore.Downloads._ID)
  val selection = "${MediaStore.Downloads.DISPLAY_NAME} = ?"
  val selectionArgs = arrayOf(fileName)

  applicationContext.contentResolver
    .query(collection, projection, selection, selectionArgs, null)
    ?.use { cursor ->
      if (cursor.moveToFirst()) {
        val id = cursor.getLong(cursor.getColumnIndexOrThrow(MediaStore.Downloads._ID))
        return ContentUris.withAppendedId(collection, id)
      }
    }
  return null
}

    /**
     * Once the file is fully written on disk, Android Q+ requires us to fetch the actual “DATA” path
     * via a query on MediaStore so we can pass a real file path to any gallery/scanner logic.
     */
    private fun getMediaStoreEntryPathApi29(uri: Uri): String? {
        return try {
            applicationContext.contentResolver.query(
                uri,
                arrayOf(MediaStore.Files.FileColumns.DATA),
                null,
                null,
                null
            )?.use { cursor ->
                if (!cursor.moveToFirst()) return null
                cursor.getString(
                    cursor.getColumnIndexOrThrow(
                        MediaStore.Files.FileColumns.DATA
                    )
                )
            }
        } catch (e: IllegalArgumentException) {
            e.printStackTrace()
            logError("getMediaStoreEntryPathApi29 failed: ${e.message}")
            null
        }
    }

    /**
     * If the final status is COMPLETE (and the file is an image or video,
     * and it lives on external storage), we insert a row into the image/video
     * collection so it appears in the user’s gallery.
     */
    private fun addImageOrVideoToGallery(
        fileName: String?,
        filePath: String?,
        contentType: String?
    ) {
        if (contentType != null && filePath != null && fileName != null) {
            if (contentType.startsWith("image/")) {
                val values = ContentValues().apply {
                    put(MediaStore.Images.Media.TITLE, fileName)
                    put(MediaStore.Images.Media.DISPLAY_NAME, fileName)
                    put(MediaStore.Images.Media.DESCRIPTION, "")
                    put(MediaStore.Images.Media.MIME_TYPE, contentType)
                    put(MediaStore.Images.Media.DATE_ADDED, System.currentTimeMillis())
                    put(MediaStore.Images.Media.DATE_TAKEN, System.currentTimeMillis())
                    put(MediaStore.Images.Media.DATA, filePath)
                }
                Log.d(TAG, "Inserting $fileName into image gallery")
                applicationContext.contentResolver.insert(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    values
                )
            } else if (contentType.startsWith("video")) {
                val values = ContentValues().apply {
                    put(MediaStore.Video.Media.TITLE, fileName)
                    put(MediaStore.Video.Media.DISPLAY_NAME, fileName)
                    put(MediaStore.Video.Media.DESCRIPTION, "")
                    put(MediaStore.Video.Media.MIME_TYPE, contentType)
                    put(MediaStore.Video.Media.DATE_ADDED, System.currentTimeMillis())
                    put(MediaStore.Video.Media.DATE_TAKEN, System.currentTimeMillis())
                    put(MediaStore.Video.Media.DATA, filePath)
                }
                Log.d(TAG, "Inserting $fileName into video gallery")
                applicationContext.contentResolver.insert(
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                    values
                )
            }
        }
    }

    /**
     * Remove any partial file if the final status is not COMPLETE and “resumable=false”.
     */
    private fun cleanUp() {
        val task = taskDao?.loadTask(id.toString()) ?: return
        if (task.status != DownloadStatus.COMPLETE && !task.resumable) {
            var filename = task.filename
            if (filename == null) {
                filename = task.url.substring(task.url.lastIndexOf("/") + 1)
            }
            val saveFilePath = task.savedDir + File.separator + filename
            val tempFile = File(saveFilePath)
            if (tempFile.exists()) {
                val deleted = tempFile.delete()
                log("Deleted temp file: $saveFilePath → $deleted")
            }
        }
    }

    /**
     * Fetch our notification icon from AndroidManifest metadata or fallback
     */
    private val notificationIconRes: Int
        get() {
            return try {
                val applicationInfo: ApplicationInfo =
                    applicationContext.packageManager.getApplicationInfo(
                        applicationContext.packageName,
                        PackageManager.GET_META_DATA
                    )
                val appIconResId: Int = applicationInfo.icon
                applicationInfo.metaData.getInt(
                    "vn.hunghd.flutterdownloader.NOTIFICATION_ICON",
                    appIconResId
                )
            } catch (e: PackageManager.NameNotFoundException) {
                e.printStackTrace()
                0
            }
        }

    /**
     * Create (or no-op if already created) the notification channel on Android O+.
     */
    private fun setupNotification(context: Context) {
        if (!showNotification) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val res = applicationContext.resources
            val channelName: String =
                res.getString(R.string.flutter_downloader_notification_channel_name)
            val channelDescription: String =
                res.getString(R.string.flutter_downloader_notification_channel_description)
            val importance: Int = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(CHANNEL_ID, channelName, importance).apply {
                description = channelDescription
                setSound(null, null)
            }
            NotificationManagerCompat.from(context).createNotificationChannel(channel)
        }
    }

    /**
     * Build or update the ongoing notification with Pause/Resume/Cancel buttons.
     * If “finalize=true,” we allow it to be auto-cancelled (for COMPLETE/FAILED/CANCELED).
     */
    private fun updateNotification(
        context: Context,
        title: String?,
        status: DownloadStatus,
        progress: Double,
        intent: PendingIntent?,
        finalize: Boolean,
        progressText: String? = null
    ) {
        // Always send status/progress back to Dart before updating the notification UI:
        sendUpdateProcessEvent(status, progress)

        if (!showNotification) return

        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentIntent(intent)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        // Prepare “Pause,” “Resume,” “Cancel” PendingIntents:
        // Prepare “Pause,” “Resume,” “Cancel” PendingIntents:
val pauseIntent = Intent(ACTION_PAUSE).apply {
    setPackage(context.packageName)
    putExtra("TASK_ID", id.toString())
}
val resumeIntent = Intent(ACTION_RESUME).apply {
    setPackage(context.packageName)
    putExtra("TASK_ID", id.toString())
}
val cancelIntent = Intent(ACTION_CANCEL).apply {
    setPackage(context.packageName)
    putExtra("TASK_ID", id.toString())
}

        val idCode = id.toString().hashCode()   // or use task.primaryId

val pausePendingIntent = PendingIntent.getBroadcast(
    context,
    idCode,           // ← unique per-task
    pauseIntent,
    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
)
val resumePendingIntent = PendingIntent.getBroadcast(
    context,
    idCode + 1,       // ← also unique
    resumeIntent,
    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
)
val cancelPendingIntent = PendingIntent.getBroadcast(
    context,
    idCode + 2,
    cancelIntent,
    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
)

        val progressPercentage = String.format(Locale.US, "%.2f%%", progress)

        when (status) {
            DownloadStatus.RUNNING -> {
                if (progress <= 0) {
                    builder.setContentText(msgStarted)
                        .setProgress(0, 0, false)
                        .setOngoing(true)
                        .setAutoCancel(false)
                        .setSmallIcon(notificationIconRes)
                } else if (progress < 100) {
                    val finalProgressText =
                        if (progressText != null)
                            "$msgInProgress – $progressPercentage – $progressText"
                        else
                            "$msgInProgress – $progressPercentage"

                    builder.setContentText(finalProgressText)
                        .setProgress(100, progress.toInt(), false)
                        .setOngoing(true)
                        .setAutoCancel(false)
                        .setSmallIcon(android.R.drawable.stat_sys_download)
                        .addAction(
                            android.R.drawable.ic_media_pause,
                            "Pause",
                            pausePendingIntent
                        )
                        .addAction(
                            android.R.drawable.ic_menu_close_clear_cancel,
                            "Cancel",
                            cancelPendingIntent
                        )
                } else {
                    builder.setContentText(msgComplete)
                        .setProgress(0, 0, false)
                        .setOngoing(false)
                        .setAutoCancel(true)
                        .setSmallIcon(android.R.drawable.stat_sys_download_done)
                }
            }

            DownloadStatus.PAUSED -> {
    builder
      .setContentText("$msgPaused – $progressPercentage")
      .setProgress(0, 0, false)
      .setOngoing(true)
      .setAutoCancel(false)
      .setSmallIcon(android.R.drawable.ic_media_pause)
      .addAction(
        android.R.drawable.ic_media_play,
        "Resume",
        resumePendingIntent
      )
      .addAction(
        android.R.drawable.ic_menu_close_clear_cancel,
        "Cancel",
        cancelPendingIntent
      )
}


            DownloadStatus.CANCELED -> {
                builder.setContentText(msgCanceled)
                    .setProgress(0, 0, false)
                    .setOngoing(false)
                    .setAutoCancel(true)
                    .setSmallIcon(android.R.drawable.stat_notify_error)
            }

            DownloadStatus.FAILED -> {
                builder.setContentText(msgFailed)
                    .setProgress(0, 0, false)
                    .setOngoing(false)
                    .setAutoCancel(true)
                    .setSmallIcon(android.R.drawable.stat_notify_error)
            }

            DownloadStatus.COMPLETE -> {
                builder.setContentText(msgComplete)
                    .setProgress(0, 0, false)
                    .setOngoing(false)
                    .setAutoCancel(true)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
            }

            else -> {
                builder.setProgress(0, 0, false)
                    .setOngoing(false)
                    .setAutoCancel(true)
                    .setSmallIcon(notificationIconRes)
            }
        }

        // Throttle notification updates to at most once per second, unless “finalize=true”
        if (System.currentTimeMillis() - lastCallUpdateNotification < 1000) {
            if (finalize) {
                log("Final update is more than once/sec; sleeping 1s to ensure it is processed")
                try {
                    Thread.sleep(1000)
                } catch (e: InterruptedException) {
                    e.printStackTrace()
                }
            } else {
                log("Dropped too-frequent update")
                return
            }
        }
        log("Updating notification (ID=$primaryId, status=$status, progress=$progress)")
        NotificationManagerCompat.from(context).notify(primaryId, builder.build())
        lastCallUpdateNotification = System.currentTimeMillis()
    }

    /**
     * Instead of trying to look up a Dart callback by handle (PluginUtilities),
     * we simply send a MethodChannel invocation back to Dart with three arguments:
     *   [0] callbackHandle (Long),
     *   [1] this WorkRequest’s string ID,
     *   [2] status.ordinal,
     *   [3] progress (Double)
     *
     * On the Dart side, `callbackDispatcher` will receive “updateProgress” and
     * forward it to whatever callback the user registered.
     */
    private fun sendUpdateProcessEvent(status: DownloadStatus, progress: Double) {
        val args: MutableList<Any> = ArrayList()
        val callbackHandle: Long = inputData.getLong(ARG_CALLBACK_HANDLE, 0)
        args.add(callbackHandle)
        args.add(id.toString())
        args.add(status.ordinal)
        args.add(progress)
        synchronized(isolateStarted) {
            if (!isolateStarted.get()) {
                // Queue it until Dart signals “didInitializeDispatcher”
                isolateQueue.add(args)
            } else {
                Handler(applicationContext.mainLooper).post {
                    backgroundChannel?.invokeMethod("updateProgress", args)
                }
            }
        }
    }

    private fun getCharsetFromContentType(contentType: String?): String? {
        if (contentType == null) return null
        val m = charsetPattern.matcher(contentType)
        return if (m.find()) {
            m.group(1)?.trim { it <= ' ' }?.uppercase(Locale.US)
        } else {
            null
        }
    }

    @Throws(UnsupportedEncodingException::class)
    private fun getFileNameFromContentDisposition(
        disposition: String?,
        contentCharset: String?
    ): String? {
        if (disposition == null) return null
        var name: String? = null
        var charset = contentCharset

        val plainMatcher = filenamePattern.matcher(disposition)
        if (plainMatcher.find()) name = plainMatcher.group(1)
        val starMatcher = filenameStarPattern.matcher(disposition)
        if (starMatcher.find()) {
            name = starMatcher.group(3)
            charset = starMatcher.group(1)?.uppercase(Locale.US)
        }
        return if (name == null) {
            null
        } else {
            URLDecoder.decode(name, charset ?: "ISO-8859-1")
        }
    }

    private fun getContentTypeWithoutCharset(contentType: String?): String? {
        return contentType?.split(";")?.toTypedArray()?.get(0)?.trim { it <= ' ' }
    }

    private fun isImageOrVideoFile(contentType: String?): Boolean {
        val newContentType = getContentTypeWithoutCharset(contentType)
        return newContentType != null && (newContentType.startsWith("image/") ||
                newContentType.startsWith("video"))
    }

    private fun isExternalStoragePath(filePath: String?): Boolean {
        val externalStorageDir: File = Environment.getExternalStorageDirectory()
        return filePath != null && filePath.startsWith(externalStorageDir.path)
    }

    private fun log(message: String) {
        if (debug) {
            Log.d(TAG, message)
        }
    }

    private fun logError(message: String) {
        if (debug) {
            Log.e(TAG, message)
        }
    }

    // “Pause” a running download: set isPaused/isStopped, mark resumable, update SQLite, update notification
    private fun pauseDownload() {
        if (!isPaused) {
            log("Pausing download")
            isPaused = true
            isManuallyStopped = true
            taskDao?.updateTaskResumable(id.toString(), true)
            taskDao?.updateTask(id.toString(), DownloadStatus.PAUSED, lastProgress)
            val task = taskDao?.loadTask(id.toString())
            var filename: String? = null
            if (task != null) {
                filename = task.filename ?: task.url.substring(task.url.lastIndexOf("/") + 1)
            }
            updateNotification(
                applicationContext,
                filename ?: "Download paused",
                DownloadStatus.PAUSED,
                lastProgress,
                null,
                false
            )
        }
    }

    /**
 * “Resume” button handler: look up exactly the paused task by ID (from the Intent extras),
 * rebuild a OneTimeWorkRequest, update the DB’s task_id → newTaskId, and re‐enqueue.
 */
private fun resumeDownload(intent: Intent) {
    // 0) (New) Ensure we have a live TaskDao/DB connection:
    if (taskDao == null) {
        dbHelper = TaskDbHelper.getInstance(applicationContext)
        taskDao   = TaskDao(dbHelper!!)
    }

    // 1) Pull out the paused task’s ID from the Intent
    val pausedTaskId = intent.getStringExtra("TASK_ID")
    if (pausedTaskId.isNullOrEmpty()) {
        logError("Cannot resume: no TASK_ID in Intent extras")
        return
    }

    // 2) Load that exact row from SQLite
    val pausedTask = taskDao?.loadTask(pausedTaskId)
    if (pausedTask == null) {
        logError("Cannot resume: no DB row found for ID = $pausedTaskId")
        return
    }

    // 3) Ensure it really was paused / resumable
    if (!pausedTask.resumable) {
        logError("Cannot resume: task was not marked resumable = 1")
        return
    }

    log("Resuming download for task_id = $pausedTaskId")

    // 4) Gather all original parameters out of that DownloadTask
    val originalUrl              = pausedTask.url
    val originalSavedDir         = pausedTask.savedDir
    val originalFileName         = pausedTask.filename
    val originalHeaders          = pausedTask.headers
    val originalShowNotification = pausedTask.showNotification
    val originalOpenFileFromNotif= pausedTask.openFileFromNotification
    val originalSaveInPublic     = pausedTask.saveInPublicStorage
    val originalAllowCellular    = pausedTask.allowCellular
    val originalProgress         = pausedTask.progress

    // 5) Grab any “plugin-level” flags from inputData (callbackHandle, step, debug, etc.)
    val callbackHandle = inputData.getLong(ARG_CALLBACK_HANDLE, 0L)
    val stepSize       = inputData.getInt(ARG_STEP, 10)
    val debugFlag      = inputData.getBoolean(ARG_DEBUG, false)
    val ignoreSslFlag  = inputData.getBoolean(ARG_IGNORESSL, false)
    val timeoutMs      = inputData.getInt(ARG_TIMEOUT, 15000)

    // 6) Build a brand-new Data object, just like FlutterDownloader.resume(...) would
    val newData = Data.Builder()
        .putString(ARG_URL, originalUrl)
        .putString(ARG_SAVED_DIR, originalSavedDir)
        .putString(ARG_FILE_NAME, originalFileName)
        .putString(ARG_HEADERS, originalHeaders)
        .putBoolean(ARG_SHOW_NOTIFICATION, originalShowNotification)
        .putBoolean(ARG_OPEN_FILE_FROM_NOTIFICATION, originalOpenFileFromNotif)
        .putBoolean(ARG_IS_RESUME, true)
        .putLong(ARG_CALLBACK_HANDLE, callbackHandle)
        .putInt(ARG_STEP, stepSize)
        .putBoolean(ARG_DEBUG, debugFlag)
        .putBoolean(ARG_IGNORESSL, ignoreSslFlag)
        .putBoolean(ARG_SAVE_IN_PUBLIC_STORAGE, originalSaveInPublic)
        .putBoolean("allow_cellular", originalAllowCellular)
        .putInt(ARG_TIMEOUT, timeoutMs)

        // <— Add this line to carry the old (paused) task ID forward:
        .putString("OLD_TASK_ID", pausedTaskId)

        .build()

    // 7) Recreate exactly the same Constraints:
    val constraints = Constraints.Builder()
        .setRequiresStorageNotLow(true)
        .setRequiredNetworkType(
            if (originalAllowCellular) NetworkType.CONNECTED
            else NetworkType.UNMETERED
        )
        .build()

    // 8) Build a brand-new OneTimeWorkRequest pointing to this same DownloadWorker
    val newWork = OneTimeWorkRequest.Builder(DownloadWorker::class.java)
        .setConstraints(constraints)
        .setBackoffCriteria(
            androidx.work.BackoffPolicy.EXPONENTIAL,
            10,
            TimeUnit.SECONDS
        )
        .setInputData(newData)
        .build()

    val newTaskId = newWork.id.toString()

    // 9) Overwrite that same DB row so “task_id → newTaskId, status=RUNNING, progress=originalProgress, resumable=false”
    taskDao!!.updateTask(
        /* currentTaskId = */ pausedTaskId,
        /* newTaskId     = */ newTaskId,
        /* status        = */ DownloadStatus.RUNNING,
        /* progress      = */ originalProgress,
        /* resumable     = */ false
    )

    // 10) Actually enqueue the fresh WorkRequest
    WorkManager.getInstance(applicationContext).enqueue(newWork)

    // 11) Immediately send one “updateProgress” callback into Dart
    Handler(applicationContext.mainLooper).post {
        backgroundChannel?.invokeMethod(
            "updateProgress",
            listOf(callbackHandle, newTaskId, DownloadStatus.RUNNING.ordinal, originalProgress)
        )
    }

    // NotificationManagerCompat.from(applicationContext)
    //    .cancel(pausedTask.primaryId)

    // 12) Flip the notification from “Paused…” back to “Resuming…”
    updateNotification(
    applicationContext,
    originalFileName ?: originalUrl.substring(originalUrl.lastIndexOf("/") + 1),
    DownloadStatus.RUNNING,
    originalProgress,
    null,
    false
)
}

    // “Cancel” a running or paused download: set isStopped, delete partial file, update SQLite, update notification
    private fun cancelDownload() {
        log("Canceling download")
        isPaused = false
        isManuallyStopped = true
        taskDao?.updateTaskResumable(id.toString(), false)

        val task = taskDao?.loadTask(id.toString())
        var filename: String? = null
        if (task != null) {
            filename = task.filename
            if (filename == null) {
                filename = task.url.substring(task.url.lastIndexOf("/") + 1)
            }
            val saveFilePath = task.savedDir + File.separator + filename
            val tempFile = File(saveFilePath)
            if (tempFile.exists()) {
                val deleted = tempFile.delete()
                log("Deleted partial file on cancel: $saveFilePath → $deleted")
            }
        }
        taskDao?.updateTask(id.toString(), DownloadStatus.CANCELED, lastProgress)
        updateNotification(
            applicationContext,
            filename ?: "Download canceled",
            DownloadStatus.CANCELED,
            lastProgress,
            null,
            true
        )
    }

    companion object {
        const val ARG_URL = "url"
        const val ARG_FILE_NAME = "file_name"
        const val ARG_SAVED_DIR = "saved_file"
        const val ARG_HEADERS = "headers"
        const val ARG_IS_RESUME = "is_resume"
        const val ARG_TIMEOUT = "timeout"
        const val ARG_SHOW_NOTIFICATION = "show_notification"
        const val ARG_OPEN_FILE_FROM_NOTIFICATION = "open_file_from_notification"
        const val ARG_CALLBACK_HANDLE = "callback_handle"
        const val ARG_DEBUG = "debug"
        const val ARG_STEP = "step"
        const val ARG_SAVE_IN_PUBLIC_STORAGE = "save_in_public_storage"
        const val ARG_IGNORESSL = "ignoreSsl"

        private val TAG = DownloadWorker::class.java.simpleName
        private const val BUFFER_SIZE = 4096
        private const val CHANNEL_ID = "FLUTTER_DOWNLOADER_NOTIFICATION"

        // These static flags track whether the Dart side has told us “didInitializeDispatcher”
        private val isolateStarted = AtomicBoolean(false)
        private val isolateQueue = ArrayDeque<List<Any>>()

        private var backgroundFlutterEngine: FlutterEngine? = null
        val DO_NOT_VERIFY = HostnameVerifier { _, _ -> true }

        // Notification action constants
        const val ACTION_PAUSE = "vn.hunghd.flutterdownloader.action.PAUSE"
        const val ACTION_RESUME = "vn.hunghd.flutterdownloader.action.RESUME"
        const val ACTION_CANCEL = "vn.hunghd.flutterdownloader.action.CANCEL"

        private fun trustAllHosts() {
            val tag = "trustAllHosts"
            val trustManagers: Array<TrustManager> = arrayOf(
                @SuppressLint("CustomX509TrustManager")
                object : X509TrustManager {
                    override fun checkClientTrusted(
                        chain: Array<X509Certificate>,
                        authType: String
                    ) {
                        Log.i(tag, "checkClientTrusted")
                    }

                    override fun checkServerTrusted(
                        chain: Array<X509Certificate>,
                        authType: String
                    ) {
                        Log.i(tag, "checkServerTrusted")
                    }

                    override fun getAcceptedIssuers(): Array<out X509Certificate> = emptyArray()
                }
            )
            try {
                val sslContent: SSLContext = SSLContext.getInstance("TLS")
                sslContent.init(null, trustManagers, SecureRandom())
                HttpsURLConnection.setDefaultSSLSocketFactory(sslContent.socketFactory)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    init {
        // Postpone starting the FlutterEngine until the worker is actually run
        Handler(context.mainLooper).post { startBackgroundIsolate(context) }
    }
}
