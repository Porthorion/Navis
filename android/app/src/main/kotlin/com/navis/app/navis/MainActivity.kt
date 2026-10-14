package com.navis.app.navis

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.DocumentsContract
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import androidx.documentfile.provider.DocumentFile
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import kotlinx.coroutines.runBlocking
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.Locale

class MainActivity : AudioServiceActivity() {

    private val updaterChannelName = "com.navis.app/updater"
    private val distributionChannelName = "com.navis.app/distribution"
    private val powerChannelName = "com.navis.app/power"
    private val deviceChannelName = "com.navis.app/device"
    private val backgroundSyncChannelName = "com.navis.app/background_sync"
    private val diagnosticsHandshakeChannelName = "com.navis.app/diagnostics_handshake"
    private val permanentDownloadStorageChannelName = "com.navis.app/permanent_download_storage"
    @Volatile
    private var pendingCloseAfterInstallerHandoff = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.navis.app/storage_capacity",
            StandardMethodCodec.INSTANCE,
            flutterEngine.dartExecutor.binaryMessenger.makeBackgroundTaskQueue(),
        )
            .setMethodCallHandler { call, result ->
                if (call.method != "freeBytes") {
                    result.notImplemented()
                } else {
                    try {
                        val path = requireNotNull(call.argument<String>("path"))
                        result.success(android.os.StatFs(path).availableBytes)
                    } catch (error: Exception) {
                        result.error("CAPACITY_UNAVAILABLE", "Storage capacity unavailable", null)
                    }
                }
            }

        if (BuildConfig.SELF_UPDATE_ENABLED) {
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                updaterChannelName
            ).setMethodCallHandler { call, result ->
                when (call.method) {
                    "installApk" -> {
                        val filePath = call.argument<String>("filePath")
                        if (filePath == null) {
                            result.error("INVALID_ARG", "filePath is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            installApk(filePath)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            distributionChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstallSource" -> {
                    result.success(resolveInstallSource())
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            powerChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isIgnoringBatteryOptimizations" -> {
                    result.success(isIgnoringBatteryOptimizations())
                }
                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        requestIgnoreBatteryOptimizations()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("POWER_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            deviceChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "restartNavis" -> {
                    val restart = Intent(this, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
                    // Acknowledge first, then have the system schedule the new
                    // activity before ending this process and its cached engine.
                    result.success(null)
                    Handler(Looper.getMainLooper()).post {
                        startActivity(restart)
                        android.os.Process.killProcess(android.os.Process.myPid())
                    }
                }
                "getDeviceName" -> {
                    result.success(resolveDeviceName())
                }
                else -> result.notImplemented()
            }
        }

        registerNetworkCostChannel(applicationContext, flutterEngine.dartExecutor.binaryMessenger)

        val backgroundScheduler = AndroidBackgroundSyncScheduler(applicationContext)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            backgroundSyncChannelName
        ).setMethodCallHandler { call, result ->
            val profileKey = call.argument<String>("profileKey")
            if (profileKey == null || !profileKey.matches(Regex("[0-9a-f]{32}"))) {
                result.error("INVALID_ARGUMENT", "Invalid opaque profile key.", null)
                return@setMethodCallHandler
            }
            try {
                when (call.method) {
                    "configurePeriodic" -> {
                        val intervalMinutes = call.argument<Int>("intervalMinutes")?.toLong()
                        val unmeteredOnly = call.argument<Boolean>("unmeteredOnly")
                        if (intervalMinutes == null || unmeteredOnly == null) {
                            result.error("INVALID_ARGUMENT", "Missing schedule parameters.", null)
                            return@setMethodCallHandler
                        }
                        val spec = BackgroundSyncScheduleSpec(
                            profileKey = profileKey,
                            intervalMinutes = intervalMinutes,
                            unmeteredOnly = unmeteredOnly,
                        )
                        respondWithBackgroundSchedule(result) {
                            backgroundScheduler.configurePeriodic(spec)
                        }
                    }
                    "enqueueCatchup" -> {
                        val unmeteredOnly = call.argument<Boolean>("unmeteredOnly")
                        if (unmeteredOnly == null) {
                            result.error("INVALID_ARGUMENT", "Missing network constraint.", null)
                            return@setMethodCallHandler
                        }
                        val spec = BackgroundSyncScheduleSpec(
                            profileKey = profileKey,
                            intervalMinutes = 15,
                            unmeteredOnly = unmeteredOnly,
                        )
                        respondWithBackgroundSchedule(result) {
                            backgroundScheduler.enqueueCatchup(spec)
                        }
                    }
                    "cancel" -> {
                        respondWithBackgroundSchedule(result) {
                            backgroundScheduler.cancel(profileKey)
                        }
                    }
                    "status" -> {
                        Thread {
                            val observation = runCatching {
                                kotlinx.coroutines.runBlocking {
                                    backgroundScheduler.status(profileKey)
                                }
                            }.getOrElse {
                                BackgroundSyncScheduleObservation(state = "platformFailure")
                            }
                            runOnUiThread { result.success(observation.toMap()) }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            } catch (_: IllegalArgumentException) {
                result.error("INVALID_ARGUMENT", "Unsupported schedule parameters.", null)
            } catch (_: Exception) {
                result.error("SCHEDULER_FAILURE", "Native schedule reconciliation failed.", null)
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            diagnosticsHandshakeChannelName
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "publish" -> {
                    val port = call.argument<Int>("port")
                    val token = call.argument<String>("token")
                    val pid = call.argument<Int>("pid")
                    val mode = call.argument<String>("mode")
                    if (
                        port == null || port !in 1..65535 ||
                        token == null || !token.matches(Regex("[A-Za-z0-9_-]{43}")) ||
                        pid == null || pid < 1 ||
                        mode !in setOf("clone", "primaryCertification")
                    ) {
                        result.error("INVALID_ARGUMENT", "Invalid diagnostics handshake.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        writeDiagnosticsHandshake(port, token, pid, requireNotNull(mode))
                        result.success(null)
                    } catch (_: Exception) {
                        result.error(
                            "HANDSHAKE_WRITE_FAILED",
                            "Could not publish diagnostics handshake.",
                            null,
                        )
                    }
                }
                "clear" -> {
                    try {
                        clearDiagnosticsHandshake()
                        result.success(null)
                    } catch (_: Exception) {
                        result.error(
                            "HANDSHAKE_CLEAR_FAILED",
                            "Could not clear diagnostics handshake.",
                            null,
                        )
                    }
                }
                "diagnosticsFixtureTree" -> {
                    if (BuildConfig.BUILD_TYPE != "profile" ||
                        BuildConfig.APPLICATION_ID == "com.navis.app.navis"
                    ) {
                        result.error("DIAGNOSTICS_UNAVAILABLE", "Profile sidecar required.", null)
                    } else {
                        result.success(
                            DocumentsContract.buildTreeDocumentUri(
                                "${BuildConfig.APPLICATION_ID}.diagnostics.documents",
                                "root",
                            ).toString(),
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Storage Access Framework calls query a content provider for every
        // document, and on Android the platform thread is also Flutter's UI
        // thread. Run them on a background task queue (serial, so calls keep
        // their order) so scanning or writing a large folder never freezes
        // the app.
        val storageMessenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(
            storageMessenger,
            permanentDownloadStorageChannelName,
            StandardMethodCodec.INSTANCE,
            storageMessenger.makeBackgroundTaskQueue(),
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "diagnosticsFixtureSetReadDenied" -> {
                        if (BuildConfig.BUILD_TYPE != "profile" ||
                            BuildConfig.APPLICATION_ID == "com.navis.app.navis"
                        ) {
                            result.error("DIAGNOSTICS_UNAVAILABLE", "Profile sidecar required.", null)
                        } else {
                            val denied = call.argument<Boolean>("denied") == true
                            val fixtureRoot = File(filesDir, "navis-saf-fixture")
                            if (!fixtureRoot.exists() && !fixtureRoot.mkdirs()) {
                                throw IllegalStateException("Fixture root is unavailable")
                            }
                            val marker = File(fixtureRoot, ".navis-diagnostics-deny-reads")
                            if (denied) marker.writeText("1") else marker.delete()
                            result.success(null)
                        }
                    }
                    "diagnosticsFixtureStageUnindexedCopy" -> {
                        if (BuildConfig.BUILD_TYPE != "profile" ||
                            BuildConfig.APPLICATION_ID == "com.navis.app.navis"
                        ) {
                            result.error("DIAGNOSTICS_UNAVAILABLE", "Profile sidecar required.", null)
                        } else {
                            val fixtureRoot = File(filesDir, "navis-saf-fixture")
                            val source = fixtureRoot.walkTopDown().firstOrNull { candidate ->
                                candidate.isFile &&
                                    candidate.name != ".navis-downloads.sqlite" &&
                                    !candidate.name.startsWith(".navis-diagnostics-")
                            } ?: throw IllegalStateException("No fixture media is available to stage")
                            val stagedDirectory = File(fixtureRoot, "diagnostics-unindexed")
                            if (!stagedDirectory.exists() && !stagedDirectory.mkdirs()) {
                                throw IllegalStateException("Could not create the fixture staging directory")
                            }
                            val staged = File(stagedDirectory, "unindexed-${source.name}")
                            source.copyTo(staged, overwrite = true)
                            result.success(null)
                        }
                    }
                    "diagnosticsFixtureTree" -> {
                        if (BuildConfig.BUILD_TYPE != "profile" ||
                            BuildConfig.APPLICATION_ID == "com.navis.app.navis"
                        ) {
                            result.error("DIAGNOSTICS_UNAVAILABLE", "Profile sidecar required.", null)
                        } else {
                            result.success(
                                DocumentsContract.buildTreeDocumentUri(
                                    "${BuildConfig.APPLICATION_ID}.diagnostics.documents",
                                    "root",
                                ).toString(),
                            )
                        }
                    }
                    "persistTree" -> {
                        // The picker plugin drops its persist option, so keep the
                        // grant here; without it the folder is lost on restart.
                        try {
                            contentResolver.takePersistableUriPermission(
                                Uri.parse(requireNotNull(call.argument<String>("treeUri"))),
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                            )
                        } catch (error: SecurityException) {
                            // App-owned trees may have no persistable grant.
                            // The writable probe still decides whether to use them.
                            Log.w("Navis", "Tree grant is not persistable; validating access instead.")
                        }
                        result.success(null)
                    }
                    "inspectTree" -> {
                        val tree = requiredTree(call.argument<String>("treeUri"))
                        result.success(treeDetails(tree, canReplace = false))
                    }
                    "validateWritableTree" -> {
                        val tree = requiredTree(call.argument<String>("treeUri"))
                        result.success(treeDetails(tree, canReplace = probeWritableTree(tree)))
                    }
                    "listRecursively" -> {
                        result.success(listDocuments(requiredTree(call.argument<String>("treeUri"))))
                    }
                    "findDocument" -> {
                        val tree = requiredTree(call.argument<String>("treeUri"))
                        result.success(
                            findDocumentId(tree, requireNotNull(call.argument<String>("relativePath")))
                                ?.let { DocumentsContract.buildDocumentUriUsingTree(tree.uri, it).toString() },
                        )
                    }
                    "materialize" -> {
                        val output = File.createTempFile("navis-saf-", ".tmp", cacheDir)
                        contentResolver.openInputStream(Uri.parse(requireNotNull(call.argument<String>("uri"))))?.use { input ->
                            FileOutputStream(output).use { destination -> input.copyTo(destination) }
                        } ?: throw IllegalStateException("Document is unreadable")
                        result.success(output.absolutePath)
                    }
                    "readFlacIdentity" -> {
                        val uri = Uri.parse(requireNotNull(call.argument<String>("uri")))
                        val values = contentResolver.openInputStream(uri)?.use { input ->
                            readNavisFlacIdentity(input)
                        } ?: throw IllegalStateException("Document is unreadable")
                        result.success(values)
                    }
                    "writeFromFile" -> {
                        val tree = requiredTree(call.argument<String>("treeUri"))
                        val source = File(requireNotNull(call.argument<String>("sourcePath")))
                        if (!source.isFile) throw IllegalArgumentException("Source file is unavailable")
                        val target = createDocument(
                            tree,
                            requireNotNull(call.argument<String>("relativePath")),
                            call.argument<String>("mimeType") ?: "application/octet-stream",
                            call.argument<Boolean>("replace") ?: true,
                        )
                        try {
                            contentResolver.openOutputStream(target.uri, "wt")?.use { output ->
                                val copied = source.inputStream().use { input -> input.copyTo(output) }
                                output.flush()
                                if (copied != source.length()) throw java.io.IOException("Incomplete document write")
                            } ?: throw IllegalStateException("Document is unwritable")
                            result.success(target.uri.toString())
                        } catch (error: Exception) {
                            // This call created the document. A process crash is
                            // repaired by the queue's verified finish journal.
                            target.delete()
                            throw error
                        }
                    }
                    "delete" -> {
                        val document = DocumentFile.fromSingleUri(this, Uri.parse(requireNotNull(call.argument<String>("uri"))))
                            ?: throw IllegalArgumentException("Invalid document URI")
                        if (!document.delete()) throw IllegalStateException("Could not delete document")
                        result.success(null)
                    }
                    "exists" -> result.success(
                        DocumentFile.fromSingleUri(this, Uri.parse(requireNotNull(call.argument<String>("uri"))))?.exists() == true,
                    )
                    "isDescendant" -> {
                        val tree = requiredTree(call.argument<String>("treeUri"))
                        val document = DocumentFile.fromSingleUri(
                            this,
                            Uri.parse(requireNotNull(call.argument<String>("documentUri"))),
                        )
                        result.success(document?.let { isDescendant(tree, it) } == true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error(storageErrorCode(e), "Android folder operation failed", null)
            }
        }
    }

    private fun storageErrorCode(error: Throwable): String {
        val causes = generateSequence(error) { it.cause }.toList()
        val errno = causes.filterIsInstance<android.system.ErrnoException>().firstOrNull()?.errno
        return when {
            errno == android.system.OsConstants.ENOSPC || errno == android.system.OsConstants.EDQUOT ||
                causes.any { cause -> listOf("ENOSPC", "EDQUOT", "No space left", "Disk quota exceeded").any { cause.message?.contains(it) == true } } -> "NO_SPACE"
            causes.any { it is SecurityException } || errno == android.system.OsConstants.EACCES ||
                errno == android.system.OsConstants.EPERM -> "PERMISSION_DENIED"
            else -> "SAF_STORAGE_ERROR"
        }
    }

    private fun requiredTree(rawUri: String?): DocumentFile {
        val uri = rawUri?.let(Uri::parse) ?: throw IllegalArgumentException("Folder URI is required")
        return DocumentFile.fromTreeUri(this, uri)?.takeIf { it.exists() && it.isDirectory }
            ?: throw IllegalArgumentException("Selected folder is unavailable")
    }

    private val childProjection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
    )

    /**
     * Lists every file below [tree] with one provider query per folder.
     * DocumentFile made about five queries per file (name, type, size and two
     * kind checks). Like DocumentFile.isFile, entries without a MIME type are
     * skipped.
     */
    private fun listDocuments(tree: DocumentFile): List<Map<String, Any?>> {
        val treeUri = tree.uri
        val output = mutableListOf<Map<String, Any?>>()
        val pending = ArrayDeque<Pair<String, String>>()
        pending.add(DocumentsContract.getDocumentId(treeUri) to "")
        while (pending.isNotEmpty()) {
            val (parentId, prefix) = pending.removeFirst()
            forEachChild(treeUri, parentId) { id, name, mimeType, size ->
                val relativePath = if (prefix.isEmpty()) name else "$prefix/$name"
                if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                    pending.add(id to relativePath)
                } else if (!mimeType.isNullOrEmpty()) {
                    output += mapOf(
                        "uri" to DocumentsContract.buildDocumentUriUsingTree(treeUri, id).toString(),
                        "relativePath" to relativePath,
                        "displayName" to name,
                        "size" to size,
                        "mimeType" to mimeType,
                    )
                }
            }
        }
        return output
    }

    private inline fun forEachChild(
        treeUri: Uri,
        parentId: String,
        action: (id: String, name: String, mimeType: String?, size: Long) -> Unit,
    ) {
        contentResolver.query(
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId),
            childProjection,
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                val size = if (cursor.isNull(3)) 0L else cursor.getLong(3)
                action(id, name, cursor.getString(2), size)
            }
        }
    }

    /** Resolves [relativePath] below [tree] with one query per path component. */
    private fun findDocumentId(tree: DocumentFile, relativePath: String): String? {
        val parts = relativePath.split('/').filter { it.isNotBlank() }
        if (parts.isEmpty() || parts.any { it == "." || it == ".." }) return null
        var currentId = DocumentsContract.getDocumentId(tree.uri)
        for (name in parts) {
            var found: String? = null
            forEachChild(tree.uri, currentId) { id, childName, _, _ ->
                if (found == null && childName == name) found = id
            }
            currentId = found ?: return null
        }
        return currentId
    }

    private fun readNavisFlacIdentity(input: java.io.InputStream): Map<String, String> {
        val magic = input.readNBytes(4)
        if (!magic.contentEquals(byteArrayOf('f'.code.toByte(), 'L'.code.toByte(), 'a'.code.toByte(), 'C'.code.toByte()))) {
            return emptyMap()
        }
        while (true) {
            val header = input.readNBytes(4)
            if (header.size != 4) return emptyMap()
            val last = header[0].toInt() and 0x80 != 0
            val type = header[0].toInt() and 0x7f
            val length = ((header[1].toInt() and 0xff) shl 16) or
                ((header[2].toInt() and 0xff) shl 8) or (header[3].toInt() and 0xff)
            if (type == 4) {
                if (length > 1024 * 1024) return emptyMap()
                return parseNavisVorbisComments(input.readNBytes(length))
            }
            var remaining = length.toLong()
            while (remaining > 0) {
                val skipped = input.skip(remaining)
                if (skipped <= 0) return emptyMap()
                remaining -= skipped
            }
            if (last) return emptyMap()
        }
    }

    private fun parseNavisVorbisComments(bytes: ByteArray): Map<String, String> {
        fun u32(offset: Int): Int = (bytes[offset].toInt() and 0xff) or
            ((bytes[offset + 1].toInt() and 0xff) shl 8) or
            ((bytes[offset + 2].toInt() and 0xff) shl 16) or
            ((bytes[offset + 3].toInt() and 0xff) shl 24)
        if (bytes.size < 8) return emptyMap()
        var offset = 0
        val vendorLength = u32(offset)
        offset += 4 + vendorLength
        if (offset + 4 > bytes.size) return emptyMap()
        val count = u32(offset)
        offset += 4
        val result = mutableMapOf<String, String>()
        repeat(count) {
            if (offset + 4 > bytes.size) return result
            val length = u32(offset)
            offset += 4
            if (length < 0 || offset + length > bytes.size) return result
            val value = bytes.copyOfRange(offset, offset + length).toString(Charsets.UTF_8)
            offset += length
            val equals = value.indexOf('=')
            if (equals > 0) result[value.substring(0, equals).uppercase()] = value.substring(equals + 1)
        }
        return result
    }

    // Folders resolved by createDocument, keyed by tree and relative path.
    // Downloads share artist and album folders, and DocumentFile.findFile
    // queries every sibling's name, so resolving them once per session avoids
    // most provider round trips. Only touched on the storage task queue.
    private val resolvedFolders = HashMap<String, DocumentFile>()

    private fun createDocument(root: DocumentFile, relativePath: String, mimeType: String, replace: Boolean): DocumentFile {
        val parts = relativePath.split('/').filter { it.isNotBlank() }
        require(parts.isNotEmpty() && parts.none { it == "." || it == ".." }) { "Invalid relative path" }
        return try {
            createDocumentIn(root, parts, mimeType, replace, useCache = true)
        } catch (error: Exception) {
            // A cached folder may have been removed outside Navis.
            resolvedFolders.clear()
            createDocumentIn(root, parts, mimeType, replace, useCache = false)
        }
    }

    private fun createDocumentIn(
        root: DocumentFile,
        parts: List<String>,
        mimeType: String,
        replace: Boolean,
        useCache: Boolean,
    ): DocumentFile {
        var directory = root
        var path = root.uri.toString()
        for (name in parts.dropLast(1)) {
            path = "$path/$name"
            val cached = if (useCache) resolvedFolders[path] else null
            directory = cached ?: (directory.findFile(name) ?: directory.createDirectory(name)
                ?: throw IllegalStateException("Could not create folder"))
            if (cached == null) {
                if (!directory.isDirectory) throw IllegalStateException("Path component is not a folder")
                resolvedFolders[path] = directory
            }
        }
        val filename = parts.last()
        val existing = directory.findFile(filename)
        if (existing != null) {
            if (!replace) {
                throw IllegalStateException("A document with this name already exists")
            }
            if (!existing.delete()) throw IllegalStateException("Could not replace existing document")
        }
        return directory.createFile(mimeType, filename) ?: throw IllegalStateException("Could not create document")
    }

    private fun treeDetails(tree: DocumentFile, canReplace: Boolean): Map<String, Any> = mapOf(
        "uri" to tree.uri.toString(),
        "displayName" to (tree.name ?: "Selected folder"),
        // DocumentFile.canRead/canWrite only consult URI grants. That is not
        // sufficient for Navis's profile-only provider, which is accessed by
        // the same UID and therefore has no grant record. Probe the actual
        // provider operation as the authoritative capability instead.
        "canRead" to canReadTree(tree),
        "canWrite" to (tree.canWrite() || canReplace),
        "canReplace" to canReplace,
    )

    private fun probeWritableTree(tree: DocumentFile): Boolean {
        val name = ".navis-saf-probe-${System.nanoTime()}"
        val probe = tree.createFile("application/octet-stream", name) ?: return false
        return try {
            contentResolver.openOutputStream(probe.uri, "wt")?.use { output ->
                output.write(byteArrayOf(0x4e, 0x56))
            } ?: return false
            probe.delete()
        } catch (error: Exception) {
            if (storageErrorCode(error) == "NO_SPACE") throw error
            false
        } finally {
            if (probe.exists()) probe.delete()
        }
    }

    private fun canReadTree(tree: DocumentFile): Boolean = try {
        tree.listFiles()
        true
    } catch (_: Exception) {
        false
    }

    private fun isDescendant(root: DocumentFile, document: DocumentFile): Boolean {
        val rootId = DocumentsContract.getTreeDocumentId(root.uri)
        val documentId = DocumentsContract.getDocumentId(document.uri)
        return documentId == rootId || documentId.startsWith("$rootId/")
    }

    private fun diagnosticsHandshakeFile(): File {
        return File(diagnosticsArtifactDirectory(), "handshake.json")
    }

    private fun diagnosticsArtifactDirectory(): File {
        val externalFiles = getExternalFilesDir(null)
            ?: throw IllegalStateException("External app files directory is unavailable")
        val directory = File(externalFiles, "navis-diagnostics")
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Could not create diagnostics artifact directory")
        }
        return directory
    }

    private fun writeDiagnosticsHandshake(port: Int, token: String, pid: Int, mode: String) {
        val target = diagnosticsHandshakeFile()
        val directory = target.parentFile
            ?: throw IllegalStateException("Diagnostics handshake directory is unavailable")
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Could not create diagnostics handshake directory")
        }
        val temporary = File.createTempFile("handshake-", ".tmp", directory)
        try {
            FileOutputStream(temporary).bufferedWriter(Charsets.UTF_8).use { writer ->
                writer.write(
                    "{\"port\":$port,\"token\":\"$token\",\"pid\":$pid," +
                        "\"mode\":\"$mode\"}",
                )
                writer.flush()
            }
            if (target.exists() && !target.delete()) {
                throw IllegalStateException("Could not replace diagnostics handshake")
            }
            if (!temporary.renameTo(target)) {
                throw IllegalStateException("Could not publish diagnostics handshake")
            }
        } finally {
            if (temporary.exists()) {
                temporary.delete()
            }
        }
    }

    private fun clearDiagnosticsHandshake() {
        val target = diagnosticsHandshakeFile()
        if (target.exists() && !target.delete()) {
            throw IllegalStateException("Could not clear diagnostics handshake")
        }
    }

    private fun respondWithBackgroundSchedule(
        result: MethodChannel.Result,
        operation: suspend () -> BackgroundSyncScheduleObservation,
    ) {
        Thread {
            val observation = runCatching {
                runBlocking { operation() }
            }.getOrElse {
                BackgroundSyncScheduleObservation(state = "platformFailure")
            }
            runOnUiThread { result.success(observation.toMap()) }
        }.start()
    }

    private fun resolveInstallSource(): Map<String, String?> {
        val packageName = applicationContext.packageName
        val packageManager = applicationContext.packageManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val sourceInfo = packageManager.getInstallSourceInfo(packageName)
            return mapOf(
                "installerPackage" to sourceInfo.installingPackageName,
                "initiatingPackage" to sourceInfo.initiatingPackageName,
                "primaryAbi" to Build.SUPPORTED_ABIS.firstOrNull(),
            )
        }

        @Suppress("DEPRECATION")
        val installerPackage = packageManager.getInstallerPackageName(packageName)
        return mapOf(
            "installerPackage" to installerPackage,
            "initiatingPackage" to null,
            "primaryAbi" to Build.SUPPORTED_ABIS.firstOrNull(),
        )
    }

    private fun installApk(filePath: String) {
        val file = File(filePath)
        if (!file.exists()) {
            throw IllegalStateException("APK file not found at $filePath")
        }

        val archiveInfo = getArchivePackageInfo(filePath)
            ?: throw IllegalStateException("Invalid APK at $filePath")
        val installedInfo = getInstalledPackageInfo(applicationContext.packageName)

        val archivePackageName = archiveInfo.packageName
        if (archivePackageName != applicationContext.packageName) {
            throw IllegalStateException(
                "APK package mismatch. Expected ${applicationContext.packageName}, got $archivePackageName"
            )
        }

        val installedDigests = signingDigests(installedInfo)
        val archiveDigests = signingDigests(archiveInfo)
        if (
            installedDigests.isNotEmpty() &&
            archiveDigests.isNotEmpty() &&
            installedDigests.intersect(archiveDigests).isEmpty()
        ) {
            throw IllegalStateException(
                "APK signature mismatch with installed app. " +
                    "Uninstall the current app once, then install the new APK."
            )
        }

        val uri = FileProvider.getUriForFile(
            this,
            "${applicationContext.packageName}.fileprovider",
            file
        )

        val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
            setData(uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            putExtra(Intent.EXTRA_RETURN_RESULT, false)
        }

        val packageManager = applicationContext.packageManager
        if (intent.resolveActivity(packageManager) == null) {
            throw IllegalStateException("No package installer available to handle APK installation")
        }

        pendingCloseAfterInstallerHandoff = true
        startActivity(intent)
    }

    override fun onStop() {
        super.onStop()
        if (!pendingCloseAfterInstallerHandoff) {
            return
        }
        pendingCloseAfterInstallerHandoff = false
        closeTaskAfterInstallerHandoff()
    }

    private fun closeTaskAfterInstallerHandoff() {
        Handler(Looper.getMainLooper()).post {
            runCatching {
                moveTaskToBack(true)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    finishAndRemoveTask()
                } else {
                    finish()
                }
            }
        }
    }

    private fun getArchivePackageInfo(filePath: String): PackageInfo? {
        val flags = PackageManager.GET_SIGNING_CERTIFICATES.toLong()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageArchiveInfo(
                filePath,
                PackageManager.PackageInfoFlags.of(flags)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageArchiveInfo(filePath, flags.toInt())
        }
    }

    private fun getInstalledPackageInfo(packageName: String): PackageInfo {
        val flags = PackageManager.GET_SIGNING_CERTIFICATES.toLong()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(flags)
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, flags.toInt())
        }
    }

    private fun signingDigests(packageInfo: PackageInfo): Set<String> {
        val signatures: Array<Signature> = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val signingInfo = packageInfo.signingInfo ?: return emptySet()
            if (signingInfo.hasMultipleSigners()) {
                signingInfo.apkContentsSigners
            } else {
                signingInfo.signingCertificateHistory
            }
        } else {
            @Suppress("DEPRECATION")
            packageInfo.signatures ?: return emptySet()
        }

        return signatures.map { signature ->
            val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
            digest.joinToString(separator = "") { byte ->
                String.format(Locale.US, "%02x", byte.toInt() and 0xff)
            }
        }.toSet()
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }
        val powerManager = getSystemService(POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(applicationContext.packageName)
    }

    private fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }

        val intent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${applicationContext.packageName}")
        ).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        val packageManager = applicationContext.packageManager
        if (intent.resolveActivity(packageManager) != null) {
            startActivity(intent)
            return
        }

        startActivity(
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }

    private fun resolveDeviceName(): String {
        normalizedDeviceName(Settings.Global.getString(contentResolver, "device_name"))?.let {
            return it
        }
        normalizedDeviceName(Settings.Secure.getString(contentResolver, "bluetooth_name"))?.let {
            return it
        }

        val manufacturer = normalizedDeviceName(Build.MANUFACTURER)
        val model = normalizedDeviceName(Build.MODEL)
        if (manufacturer == null) {
            return model ?: "Android device"
        }
        if (model == null || model.startsWith(manufacturer, ignoreCase = true)) {
            return model ?: manufacturer
        }
        return "$manufacturer $model"
    }

    private fun normalizedDeviceName(value: String?): String? {
        val normalized = value
            ?.trim()
            ?.replace(Regex("\\s+"), " ")
            ?.takeIf { it.isNotEmpty() }
            ?: return null
        val lowercase = normalized.lowercase(Locale.US)
        if (
            lowercase == "localhost" ||
            lowercase == "localhost.localdomain" ||
            lowercase == "unknown"
        ) {
            return null
        }
        return normalized
    }
}
