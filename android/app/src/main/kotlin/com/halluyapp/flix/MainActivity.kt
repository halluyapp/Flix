package com.halluyapp.flix

import android.Manifest
import android.app.DownloadManager
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val downloadChannel = "flix.downloads"
    private val notificationRequestCode = 4301

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, downloadChannel)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getDirectory" -> result.success(downloadDirectory().absolutePath)
                        "enqueue" -> result.success(
                            enqueueDownload(call.arguments as? Map<*, *> ?: emptyMap<Any, Any>())
                        )
                        "getStatuses" -> {
                            val arguments = call.arguments as? Map<*, *>
                            val ids = arguments?.get("ids") as? List<*> ?: emptyList<Any>()
                            result.success(
                                ids.mapNotNull { it?.toString()?.toLongOrNull() }
                                    .mapNotNull { statusFor(it) }
                            )
                        }
                        "cancel" -> {
                            val arguments = call.arguments as? Map<*, *>
                            val id = arguments?.get("id")?.toString()?.toLongOrNull()
                            if (id == null) {
                                result.error("invalid_id", "Invalid download id", null)
                            } else {
                                result.success(cancelDownload(id))
                            }
                        }
                        "getStorageInfo" -> result.success(storageInfo())
                        "requestNotificationPermission" ->
                            result.success(requestNotificationPermission())
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error(
                        "download_error",
                        error.message ?: "Download operation failed",
                        null
                    )
                }
            }
    }

    private fun downloadDirectory(): File {
        val root = getExternalFilesDir(Environment.DIRECTORY_MOVIES)
            ?: throw IllegalStateException("App-private download storage is unavailable")
        val directory = File(root, "Flix")
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Could not create Flix's private downloads folder")
        }
        return directory
    }

    private fun enqueueDownload(arguments: Map<*, *>): Map<String, Any> {
        val rawUrl = arguments["url"]?.toString()?.trim().orEmpty()
        val uri = Uri.parse(rawUrl)
        require(uri.scheme == "https" && !uri.host.isNullOrBlank()) {
            "Only secure HTTPS downloads are supported"
        }

        val requestedName = arguments["fileName"]?.toString().orEmpty()
        val safeName = File(requestedName).name
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .ifBlank { "flix_${System.currentTimeMillis()}.mp4" }
            .let { if (it.endsWith(".mp4", ignoreCase = true)) it else "$it.mp4" }
        val destination = File(downloadDirectory(), safeName)
        // A previous valid download is never deleted to make room. Flix builds a
        // unique file name per transfer, so an existing file means this request
        // is a duplicate that should not overwrite working content.
        require(!destination.exists()) {
            "A file with this download name already exists"
        }

        val request = DownloadManager.Request(uri)
            .setTitle(
                arguments["title"]?.toString()?.ifBlank { "Flix download" }
                    ?: "Flix download"
            )
            .setDescription(
                arguments["description"]?.toString()?.ifBlank { "Saved in Flix" }
                    ?: "Saved in Flix"
            )
            .setMimeType("video/mp4")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setAllowedOverRoaming(false)
            .setDestinationInExternalFilesDir(this, Environment.DIRECTORY_MOVIES, "Flix/$safeName")

        val wifiOnly = arguments["wifiOnly"] == true
        request.setAllowedOverMetered(!wifiOnly)

        @Suppress("DEPRECATION")
        request.setVisibleInDownloadsUi(false)

        val headers = arguments["headers"] as? Map<*, *> ?: emptyMap<Any, Any>()
        headers.forEach { (key, value) ->
            if (key != null && value != null) {
                request.addRequestHeader(key.toString(), value.toString())
            }
        }

        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val id = manager.enqueue(request)
        return mapOf(
            "id" to id,
            "filePath" to destination.absolutePath,
            "fileName" to safeName,
        )
    }

    private fun statusFor(id: Long): Map<String, Any?>? {
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val cursor: Cursor = manager.query(DownloadManager.Query().setFilterById(id)) ?: return null
        cursor.use {
            if (!it.moveToFirst()) return null
            val status = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
            val reason = it.getInt(it.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
            val downloaded =
                it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val total = it.getLong(it.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            val state = when (status) {
                DownloadManager.STATUS_PENDING -> "pending"
                DownloadManager.STATUS_RUNNING -> "running"
                DownloadManager.STATUS_PAUSED -> "paused"
                DownloadManager.STATUS_SUCCESSFUL -> "completed"
                DownloadManager.STATUS_FAILED -> "failed"
                else -> "unknown"
            }
            return mapOf(
                "id" to id,
                "status" to state,
                "reason" to reason,
                "downloadedBytes" to downloaded,
                "totalBytes" to total,
            )
        }
    }

    private fun cancelDownload(id: Long): Boolean {
        val manager = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        return manager.remove(id) > 0
    }

    private fun storageInfo(): Map<String, Any> {
        val stat = StatFs(filesDir.absolutePath)
        val total = stat.blockCountLong * stat.blockSizeLong
        val free = stat.availableBlocksLong * stat.blockSizeLong
        var appBytes = 0L
        try {
            downloadDirectory().walkTopDown().forEach { file ->
                if (file.isFile) appBytes += file.length()
            }
        } catch (_: Exception) {
            // Storage figures are best-effort; the UI omits them when unknown.
        }
        return mapOf(
            "totalBytes" to total,
            "freeBytes" to free,
            "appBytes" to appBytes,
        )
    }

    private fun requestNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                notificationRequestCode
            )
        }
        return granted
    }
}
