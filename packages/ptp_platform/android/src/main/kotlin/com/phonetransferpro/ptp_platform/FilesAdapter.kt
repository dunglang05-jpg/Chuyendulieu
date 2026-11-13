// Phone Transfer Pro — "Toàn bộ tệp" category: every non-media file in shared storage (Download, Documents, Zalo/
// WhatsApp files saved outside the apps, …). NOT TESTED ON DEVICES (see docs/ALL_FILES.md).
//
// Needs Android 11+ "All files access" (MANAGE_EXTERNAL_STORAGE), granted by the user in Settings, like Smart
// Switch on non-Samsung phones (device check 2026-11-13). Even with it, Android/data and Android/obb (app-private
// data) stay unreadable, and app-internal data (/data/data) is never touched.
// Photos, videos and audio are skipped here: their own categories already cover them (no duplicates).
package com.phonetransferpro.ptp_platform

import android.content.Context
import android.os.Build
import android.os.Environment
import android.webkit.MimeTypeMap
import java.io.File

class FilesAdapter(@Suppress("unused") private val context: Context) {
    val granted: Boolean get() = Build.VERSION.SDK_INT >= 30 && Environment.isExternalStorageManager()

    private val root: File get() = Environment.getExternalStorageDirectory()

    fun scan(limit: Int): List<Map<String, Any?>> {
        if (!granted) return emptyList()
        val base = root.canonicalFile
        val out = ArrayList<Map<String, Any?>>()
        base.walkTopDown()
            .maxDepth(30)
            .onEnter { dir -> dir == base || !skipDir(base, dir) }
            .filter { it.isFile && !it.name.startsWith(".") && it.canRead() }
            .forEach { f ->
                if (out.size >= limit) return@forEach
                val mime = mimeOf(f.name)
                if (mime.startsWith("image/") || mime.startsWith("video/") || mime.startsWith("audio/")) return@forEach
                val rel = f.relativeTo(base).invariantSeparatorsPath
                val relPath = "Bộ nhớ/" + rel.split('/').joinToString("/") { safeSegment(it) }
                if (relPath.toByteArray().size > 900) return@forEach // protocol path limit (1024 bytes)
                out.add(mapOf(
                    "id" to PREFIX + f.absolutePath,
                    "name" to f.name,
                    "relPath" to relPath,
                    "category" to "files",
                    "size" to f.length(),
                    "mime" to mime,
                ))
            }
        return out
    }

    /** Only files under shared storage, never outside it (no traversal / symlink tricks). */
    fun resolve(id: String): File {
        val f = File(id.removePrefix(PREFIX)).canonicalFile
        val base = root.canonicalFile
        if (!granted || !f.path.startsWith(base.path + "/") || skipDir(base, f.parentFile ?: base)) {
            throw SecurityException("FILE_NOT_ALLOWED")
        }
        return f
    }

    private fun skipDir(base: File, dir: File): Boolean {
        val rel = dir.relativeTo(base).invariantSeparatorsPath
        if (rel == "Android/data" || rel.startsWith("Android/data/")) return true // app-private, blocked anyway
        if (rel == "Android/obb" || rel.startsWith("Android/obb/")) return true
        return rel.split('/').any { it.startsWith(".") } // .thumbnails, .trash, caches
    }

    private fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
    }

    /** Same rules as PROTOCOL_v1 §8, and ≤ 60 chars so a segment always stays under 255 UTF-8 bytes. */
    private fun safeSegment(seg: String): String =
        seg.map { ch -> if (ch.code < 0x20 || ch.code == 0x7f || ch in "\\:*?\"<>|") '_' else ch }
            .joinToString("").take(60).trimEnd(' ', '.').ifEmpty { "_" }

    companion object {
        const val PREFIX = "file:"
    }
}
