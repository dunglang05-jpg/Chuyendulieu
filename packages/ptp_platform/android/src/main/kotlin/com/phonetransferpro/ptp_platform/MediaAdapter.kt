// MediaStore / SAF access for the Android adapter. NOT YET BUILT OR DEVICE-TESTED.
package com.phonetransferpro.ptp_platform

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class MediaAdapter(private val context: Context) {
    private val openFds = ConcurrentHashMap<String, ParcelFileDescriptor>()
    private val staged = ConcurrentHashMap<String, File>()
    private val pending = ConcurrentHashMap<String, ParcelFileDescriptor>() // MediaStore uri -> rw descriptor

    private fun collection(cat: String): Uri = when (cat) {
        "photos" -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        "videos" -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        "audio" -> MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        "documents" -> MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL)
        else -> throw IllegalArgumentException("category")
    }

    /** Metadata only (no bytes). With "limited" access MediaStore returns just the user-selected items. */
    fun scan(cat: String, limit: Int): List<Map<String, Any?>> {
        if (cat !in listOf("photos", "videos", "audio")) return emptyList()
        val uri = collection(cat)
        val cols = arrayOf(
            MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.RELATIVE_PATH,
        )
        val out = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(uri, cols, null, null, "${MediaStore.MediaColumns.DATE_MODIFIED} DESC")?.use { c ->
            while (c.moveToNext() && out.size < limit) {
                val id = c.getLong(0)
                val name = c.getString(1) ?: "item_$id"
                val rel = (c.getString(4) ?: "").trimEnd('/')
                out.add(mapOf(
                    "id" to ContentUris.withAppendedId(uri, id).toString(),
                    "name" to name,
                    "relPath" to sanitize(if (rel.isEmpty()) name else "$rel/$name"),
                    "category" to cat,
                    "size" to c.getLong(2),
                    "mime" to c.getString(3),
                ))
            }
        }
        return out
    }

    fun describeDocument(uri: Uri, cat: String): Map<String, Any?> {
        var name = "document"
        var size = 0L
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                name = c.getString(0) ?: name
                if (!c.isNull(1)) size = c.getLong(1)
            }
        }
        return mapOf("id" to uri.toString(), "name" to name, "relPath" to sanitize(name), "category" to cat,
            "size" to size, "mime" to context.contentResolver.getType(uri))
    }

    /**
     * Opens a content:// item without copying when it is a regular file: Dart reads /proc/self/fd/N.
     * Pipes/virtual files (some cloud providers) are staged into cache first because they cannot seek.
     */
    fun openForRead(uri: Uri): Map<String, Any?> {
        val pfd = context.contentResolver.openFileDescriptor(uri, "r") ?: throw IllegalStateException("open failed")
        val st = Os.fstat(pfd.fileDescriptor)
        if (OsConstants.S_ISREG(st.st_mode)) {
            val token = UUID.randomUUID().toString()
            openFds[token] = pfd
            return mapOf("path" to "/proc/self/fd/${pfd.fd}", "size" to st.st_size, "mtimeMs" to st.st_mtime * 1000, "token" to token)
        }
        pfd.close()
        val dir = File(context.cacheDir, "stage").apply { mkdirs() }
        val f = File(dir, UUID.randomUUID().toString())
        context.contentResolver.openInputStream(uri)!!.use { input -> f.outputStream().use { input.copyTo(it, 1 shl 20) } }
        return openFile(f, deleteOnClose = true)
    }

    fun openFile(f: File, deleteOnClose: Boolean = true): Map<String, Any?> {
        val token = UUID.randomUUID().toString()
        if (deleteOnClose) staged[token] = f
        return mapOf("path" to f.absolutePath, "size" to f.length(), "mtimeMs" to f.lastModified(), "token" to token)
    }

    fun closeRead(token: String) {
        openFds.remove(token)?.close()
        staged.remove(token)?.delete()
    }

    fun closeAll() {
        openFds.values.forEach { runCatching { it.close() } }
        openFds.clear()
        pending.values.forEach { runCatching { it.close() } }
        pending.clear()
        staged.values.forEach { it.delete() }
        staged.clear()
    }

    private fun destination(cat: String): Pair<Uri, String> = when (cat) {
        "photos" -> collection(cat) to "Pictures/PhoneTransferPro"
        "videos" -> collection(cat) to "Movies/PhoneTransferPro"
        "audio" -> collection(cat) to "Music/PhoneTransferPro"
        else -> collection("documents") to "Download/PhoneTransferPro"
    }

    /**
     * Audit P1-7: the receiver writes straight into a hidden MediaStore item instead of the app inbox, so a file is
     * written once (no inbox → MediaStore copy, no 2× space). IS_PENDING=1 keeps it out of the gallery until the
     * SHA-256 check passed and [publishPending] runs; MediaStore removes abandoned pending items by itself.
     * Dart opens the returned /proc/self/fd/N path; if that fails on a device, Dart falls back to the inbox.
     */
    fun createPending(cat: String, name: String, mime: String?): Map<String, String> {
        val (collection, base) = destination(cat)
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            if (mime != null) put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, base)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val item = resolver.insert(collection, values) ?: throw IllegalStateException("insert")
        val pfd = try {
            resolver.openFileDescriptor(item, "rw") ?: throw IllegalStateException("open")
        } catch (e: Exception) {
            resolver.delete(item, null, null)
            throw e
        }
        pending[item.toString()] = pfd
        return mapOf("uri" to item.toString(), "path" to "/proc/self/fd/${pfd.fd}")
    }

    fun reopenPending(uri: String): String {
        pending[uri]?.let { return "/proc/self/fd/${it.fd}" }
        val pfd = context.contentResolver.openFileDescriptor(Uri.parse(uri), "rw") ?: throw IllegalStateException("gone")
        pending[uri] = pfd
        return "/proc/self/fd/${pfd.fd}"
    }

    fun publishPending(uri: String): String {
        pending.remove(uri)?.let { runCatching { it.fileDescriptor.sync() }; it.close() }
        val item = Uri.parse(uri)
        val resolver = context.contentResolver
        if (resolver.update(item, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null) != 1) {
            throw IllegalStateException("publish")
        }
        var location = "PhoneTransferPro"
        resolver.query(item, arrayOf(MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) location = "${(c.getString(0) ?: "").trimEnd('/')}/${c.getString(1) ?: ""}"
        }
        return location
    }

    fun deletePending(uri: String) {
        pending.remove(uri)?.let { runCatching { it.close() } }
        runCatching { context.contentResolver.delete(Uri.parse(uri), null, null) }
    }

    /**
     * Moves a verified file from the app inbox into the shared collection under …/PhoneTransferPro.
     * IS_PENDING hides the item until the copy is complete, so a crash never leaves a half file visible.
     */
    fun importFile(src: File, cat: String, name: String, mime: String?, subdir: String? = null): Map<String, Any?> {
        val (collection, base0) = destination(cat)
        // "files": keep the sender's folder layout under Download/PhoneTransferPro/Bộ nhớ/…
        val base = if (subdir.isNullOrEmpty()) base0 else "$base0/${sanitize(subdir)}"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            if (mime != null) put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, base)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.contentResolver
        val item = resolver.insert(collection, values) ?: return mapOf("status" to "failed", "message" to "insert")
        try {
            resolver.openOutputStream(item, "w")!!.use { out -> src.inputStream().use { it.copyTo(out, 1 shl 20) } }
            resolver.update(item, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(item, null, null)
            return mapOf("status" to "failed", "message" to e.javaClass.simpleName)
        }
        src.delete()
        return mapOf("status" to "imported", "location" to "$base/$name")
    }

    companion object {
        /** Same rules as PROTOCOL_v1 §8 so the receiver never has to reject our own paths. */
        fun sanitize(path: String): String = path.split('/').filter { it.isNotEmpty() && it != "." && it != ".." }
            .joinToString("/") { seg ->
                seg.map { ch -> if (ch.code < 0x20 || ch.code == 0x7f || ch in "\\:*?\"<>|") '_' else ch }
                    .joinToString("").trimEnd(' ', '.').ifEmpty { "_" }.take(120)
            }.ifEmpty { "item" }
    }
}
