package com.navis.app.navis

import android.database.Cursor
import android.database.MatrixCursor
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import java.io.File

/**
 * App-private SAF fixture tree for profile diagnostics only.
 *
 * This provider never ships with stable/debug builds. It deliberately exposes
 * no storage outside [fixtureRoot], so diagnostic code can exercise the real
 * ContentResolver/DocumentsContract path without broad-storage permission.
 */
class NavisDiagnosticsDocumentsProvider : DocumentsProvider() {
    companion object {
        private const val rootId = "navis-fixture"
        private const val rootDocumentId = "root"
        private const val documentPrefix = "root:"
    }

    private val fixtureRoot: File
        get() = File(requireNotNull(context).filesDir, "navis-saf-fixture")

    private val denyReadsMarker: File
        get() = File(fixtureRoot, ".navis-diagnostics-deny-reads")

    override fun onCreate(): Boolean {
        return fixtureRoot.exists() || fixtureRoot.mkdirs()
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val result = MatrixCursor(projection ?: DocumentsContract.Root.COLUMN_ROOT_ID.let {
            arrayOf(
                DocumentsContract.Root.COLUMN_ROOT_ID,
                DocumentsContract.Root.COLUMN_DOCUMENT_ID,
                DocumentsContract.Root.COLUMN_TITLE,
                DocumentsContract.Root.COLUMN_FLAGS,
            )
        })
        result.newRow()
            .add(DocumentsContract.Root.COLUMN_ROOT_ID, rootId)
            .add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, rootDocumentId)
            .add(DocumentsContract.Root.COLUMN_TITLE, "Navis diagnostics")
            .add(
                DocumentsContract.Root.COLUMN_FLAGS,
                DocumentsContract.Root.FLAG_SUPPORTS_CREATE or
                    DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD,
            )
        return result
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor =
        MatrixCursor(projection ?: defaultDocumentProjection).also { result ->
            includeDocument(result, resolveDocument(documentId), documentId)
        }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor = MatrixCursor(projection ?: defaultDocumentProjection).also { result ->
        val parent = resolveDocument(parentDocumentId)
        require(parent.isDirectory) { "Not a directory" }
        parent.listFiles()?.sortedBy { it.name }?.forEach { child ->
            includeDocument(result, child, documentIdFor(child))
        }
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: android.os.CancellationSignal?,
    ): ParcelFileDescriptor {
        val document = resolveDocument(documentId)
        // Keep Navis's index available while denying media reads. This models a
        // provider losing access to one child document and lets diagnostics
        // verify that the review preserves and reports that file. A revoked
        // tree grant is still surfaced by the production bridge as a
        // recoverable FileSystemException.
        if (denyReadsMarker.exists() && document.name != ".navis-downloads.sqlite") {
            throw SecurityException("Fixture read access is revoked")
        }
        require(document.isFile) { "Not a file" }
        return ParcelFileDescriptor.open(document, ParcelFileDescriptor.parseMode(mode))
    }

    override fun createDocument(parentDocumentId: String, mimeType: String, displayName: String): String {
        require(displayName.isNotBlank() && displayName != "." && displayName != "..")
        val parent = resolveDocument(parentDocumentId)
        require(parent.isDirectory) { "Parent is not a directory" }
        val target = resolveChild(parent, displayName)
        require(!target.exists()) { "Document already exists" }
        val created = if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
            target.mkdir()
        } else {
            target.createNewFile()
        }
        require(created) { "Could not create document" }
        return documentIdFor(target)
    }

    override fun deleteDocument(documentId: String) {
        val target = resolveDocument(documentId)
        require(target != fixtureRoot) { "Cannot delete fixture root" }
        require(target.delete()) { "Could not delete document" }
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        val parent = resolveDocument(parentDocumentId).canonicalFile
        val child = resolveDocument(documentId).canonicalFile
        return child == parent || child.path.startsWith("${parent.path}${File.separator}")
    }

    override fun getDocumentType(documentId: String): String =
        if (resolveDocument(documentId).isDirectory) DocumentsContract.Document.MIME_TYPE_DIR
        else "application/octet-stream"

    private fun includeDocument(cursor: MatrixCursor, file: File, documentId: String) {
        cursor.newRow()
            .add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, documentId)
            .add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, if (file == fixtureRoot) "Navis diagnostics" else file.name)
            .add(DocumentsContract.Document.COLUMN_MIME_TYPE, if (file.isDirectory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream")
            .add(DocumentsContract.Document.COLUMN_SIZE, if (file.isFile) file.length() else null)
            .add(DocumentsContract.Document.COLUMN_LAST_MODIFIED, file.lastModified())
            .add(
                DocumentsContract.Document.COLUMN_FLAGS,
                if (file.isDirectory) DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
                else DocumentsContract.Document.FLAG_SUPPORTS_WRITE or DocumentsContract.Document.FLAG_SUPPORTS_DELETE,
            )
    }

    private fun resolveDocument(documentId: String): File = when (documentId) {
        rootDocumentId -> fixtureRoot
        else -> {
            require(documentId.startsWith(documentPrefix)) { "Unknown document" }
            resolveChild(fixtureRoot, documentId.removePrefix(documentPrefix))
        }
    }

    private fun resolveChild(parent: File, relative: String): File {
        val candidate = File(parent, relative).canonicalFile
        val root = fixtureRoot.canonicalFile
        require(candidate.path.startsWith("${root.path}${File.separator}")) { "Path escapes fixture" }
        return candidate
    }

    private fun documentIdFor(file: File): String {
        if (file.canonicalFile == fixtureRoot.canonicalFile) return rootDocumentId
        return documentPrefix + file.canonicalFile.relativeTo(fixtureRoot.canonicalFile).invariantSeparatorsPath
    }

    private val defaultDocumentProjection = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_SIZE,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_FLAGS,
    )
}
