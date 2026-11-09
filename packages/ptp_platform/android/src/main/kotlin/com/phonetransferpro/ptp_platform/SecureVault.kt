// Audit P1-10: secret storage for the continuation key. NOT TESTED ON DEVICES.
// The secret is encrypted with an AES-256-GCM key that lives in Android Keystore (non-exportable, never in app
// files); only the ciphertext is written, under noBackupFilesDir so it is never part of a cloud/device backup.
// The entry name is bound as GCM associated data, so a ciphertext copied under another name does not decrypt.
package com.phonetransferpro.ptp_platform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class SecureVault(private val context: Context) {
    companion object {
        private const val ALIAS = "ptp_continuation_v1"
        private const val IV_LEN = 12
    }

    @Synchronized
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun file(name: String): File {
        require(name.matches(Regex("^[A-Za-z0-9_-]{1,64}$"))) { "name" }
        return File(File(context.noBackupFilesDir, "vault").apply { mkdirs() }, "$name.bin")
    }

    fun put(name: String, secret: ByteArray) {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        c.updateAAD(name.toByteArray(Charsets.UTF_8))
        val ct = c.doFinal(secret)
        val f = file(name)
        val tmp = File(f.parentFile, "${f.name}.tmp")
        tmp.outputStream().use { out ->
            out.write(c.iv)
            out.write(ct)
            out.fd.sync()
        }
        if (!tmp.renameTo(f)) throw IllegalStateException("vault write")
    }

    /** Null when absent, or when it no longer decrypts (Keystore key reset, tampered file): the entry is dropped. */
    fun get(name: String): ByteArray? {
        val f = file(name)
        if (!f.exists()) return null
        return try {
            val all = f.readBytes()
            if (all.size <= IV_LEN) throw IllegalStateException("short")
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, all.copyOfRange(0, IV_LEN)))
            c.updateAAD(name.toByteArray(Charsets.UTF_8))
            c.doFinal(all, IV_LEN, all.size - IV_LEN)
        } catch (e: Exception) {
            f.delete()
            null
        }
    }

    fun delete(name: String) {
        file(name).delete()
    }
}
