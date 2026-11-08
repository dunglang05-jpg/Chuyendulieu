// Contacts via the documented vCard export (Contacts Provider) and the system import flow.
// NOT YET BUILT OR DEVICE-TESTED.
package com.phonetransferpro.ptp_platform

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.ContactsContract
import androidx.core.content.FileProvider
import java.io.File

class ContactsAdapter(private val context: Context) {

    fun scan(): List<Map<String, Any?>> {
        var count = 0
        context.contentResolver.query(ContactsContract.Contacts.CONTENT_URI, arrayOf(ContactsContract.Contacts._ID), null, null, null)
            ?.use { count = it.count }
        if (count == 0) return emptyList()
        // One vCard file for all contacts; exact size is known only after export (openForRead).
        return listOf(mapOf("id" to ALL_CONTACTS_ID, "name" to "contacts.vcf", "relPath" to "contacts.vcf",
            "category" to "contacts", "size" to 0L, "mime" to "text/x-vcard", "count" to count))
    }

    /** Requires READ_CONTACTS. Exports in batches so the multi-vCard URI stays short. */
    fun exportAll(dir: File): File {
        dir.mkdirs()
        val keys = ArrayList<String>()
        context.contentResolver.query(ContactsContract.Contacts.CONTENT_URI, arrayOf(ContactsContract.Contacts.LOOKUP_KEY), null, null, null)
            ?.use { c -> while (c.moveToNext()) c.getString(0)?.let { keys.add(it) } }
        val out = File(dir, "contacts.vcf")
        out.outputStream().use { os ->
            for (batch in keys.chunked(200)) {
                val uri = Uri.withAppendedPath(ContactsContract.Contacts.CONTENT_MULTI_VCARD_URI, Uri.encode(batch.joinToString(":")))
                context.contentResolver.openInputStream(uri)?.use { it.copyTo(os, 1 shl 16) }
            }
        }
        return out
    }

    /**
     * Official flow: hand the .vcf to the system Contacts app, which asks the user where to save and
     * handles duplicates. The app never writes the Contacts Provider directly (no WRITE_CONTACTS).
     */
    fun importViaSystemApp(activity: Activity?, vcf: File): Map<String, Any?> {
        val act = activity ?: return mapOf("status" to "failed", "message" to "no activity")
        val uri = FileProvider.getUriForFile(act, "${act.packageName}.ptp.fileprovider", vcf)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "text/x-vcard")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return try {
            act.startActivity(intent)
            mapOf("status" to "requires_user_action", "location" to "Contacts app")
        } catch (e: Exception) {
            mapOf("status" to "saved_to_files", "location" to vcf.absolutePath, "message" to "no app handles vCard")
        }
    }

    companion object {
        const val ALL_CONTACTS_ID = "contacts:all"
    }
}
