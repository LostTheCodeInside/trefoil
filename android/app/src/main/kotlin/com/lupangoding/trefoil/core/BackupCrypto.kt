package com.lupangoding.trefoil.core

import android.util.Base64
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.zip.GZIPInputStream
import java.util.zip.GZIPOutputStream
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Password-based encryption for profile backups.
 *
 * A backup holds every server's credentials, so it is never written in the clear —
 * it is meant to travel through whatever the user has to hand, and that is rarely a
 * private channel.
 *
 * Uses the platform's own crypto rather than a Dart package: this is the vetted
 * implementation already on the device, and keeping key material out of the Dart
 * heap means it is never copied around by the VM.
 *
 * Format, all concatenated then base64'd:
 *   magic "THR2" | salt (16) | iv (12) | AES-256-GCM(gzip(json)) ciphertext+tag
 *
 * The magic is also the GCM associated data, so a backup cannot be relabelled as
 * another version without the tag failing. Version 1 ("THR1": 210,000 iterations, no
 * compression, no associated data) is still read, so no backup ever made stops
 * opening.
 */
object BackupCrypto {

    private const val MAGIC_V1 = "THR1"
    private const val MAGIC_V2 = "THR2"
    private const val SALT_BYTES = 16
    private const val IV_BYTES = 12
    private const val TAG_BITS = 128
    private const val KEY_BITS = 256

    /**
     * Deliberately slow. The password is chosen by a human, so the only defence
     * against someone brute-forcing a stolen backup is making each guess expensive.
     *
     * 600,000 is OWASP's figure for PBKDF2-HMAC-SHA256. Version 1 used 210,000, which
     * is their figure for SHA-512 — a third of the work per guess this hash calls for.
     */
    private const val ITERATIONS_V2 = 600_000
    private const val ITERATIONS_V1 = 210_000

    /**
     * The largest a backup may inflate to. Far beyond any real profile — thousands of
     * servers fit in a few megabytes — and small enough that a crafted backup cannot
     * exhaust memory on the way in.
     */
    private const val MAX_PLAINTEXT_BYTES = 64 * 1024 * 1024

    class WrongPassword : Exception("Wrong password, or the backup is damaged")
    class NotABackup : Exception("That does not look like a Trefoil backup")

    fun encrypt(plaintext: String, password: String): String {
        val random = SecureRandom()
        val salt = ByteArray(SALT_BYTES).also(random::nextBytes)
        val iv = ByteArray(IV_BYTES).also(random::nextBytes)
        val magic = MAGIC_V2.toByteArray(Charsets.US_ASCII)

        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(
                Cipher.ENCRYPT_MODE,
                deriveKey(password, salt, ITERATIONS_V2),
                GCMParameterSpec(TAG_BITS, iv),
            )
            updateAAD(magic)
        }
        // Compressed before encryption, never after: ciphertext does not compress.
        // A server list is repetitive JSON, and the result is often pasted or
        // scanned by hand, where every character counts.
        val body = cipher.doFinal(gzip(plaintext.toByteArray(Charsets.UTF_8)))

        val packed = ByteBuffer.allocate(magic.size + salt.size + iv.size + body.size)
            .put(magic).put(salt).put(iv).put(body)
            .array()
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    fun decrypt(encoded: String, password: String): String {
        val packed = try {
            Base64.decode(encoded.trim(), Base64.DEFAULT)
        } catch (_: IllegalArgumentException) {
            throw NotABackup()
        }
        val magicSize = MAGIC_V2.length
        if (packed.size <= magicSize + SALT_BYTES + IV_BYTES) throw NotABackup()
        val magic = packed.copyOfRange(0, magicSize)
        val version = when (String(magic, Charsets.US_ASCII)) {
            MAGIC_V2 -> 2
            MAGIC_V1 -> 1
            else -> throw NotABackup()
        }

        val buffer = ByteBuffer.wrap(packed, magicSize, packed.size - magicSize)
        val salt = ByteArray(SALT_BYTES).also(buffer::get)
        val iv = ByteArray(IV_BYTES).also(buffer::get)
        val body = ByteArray(buffer.remaining()).also(buffer::get)

        val plain = try {
            val iterations = if (version == 2) ITERATIONS_V2 else ITERATIONS_V1
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
                init(Cipher.DECRYPT_MODE, deriveKey(password, salt, iterations), GCMParameterSpec(TAG_BITS, iv))
                if (version == 2) updateAAD(magic)
            }
            cipher.doFinal(body)
        } catch (_: Exception) {
            // GCM authentication failing is indistinguishable from a wrong password,
            // and saying more would only help someone probing a stolen backup.
            throw WrongPassword()
        }
        // Only ever reached with an authenticated body, so a failure here is a backup
        // someone built with the right password and a wrong payload.
        val json = if (version == 2) gunzip(plain) else plain
        return String(json, Charsets.UTF_8)
    }

    private fun deriveKey(password: String, salt: ByteArray, iterations: Int): SecretKeySpec {
        val spec = PBEKeySpec(password.toCharArray(), salt, iterations, KEY_BITS)
        return try {
            val key = SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec)
            SecretKeySpec(key.encoded, "AES")
        } finally {
            spec.clearPassword()
        }
    }

    private fun gzip(bytes: ByteArray): ByteArray {
        val out = ByteArrayOutputStream(bytes.size / 4 + 64)
        GZIPOutputStream(out).use { it.write(bytes) }
        return out.toByteArray()
    }

    private fun gunzip(bytes: ByteArray): ByteArray = try {
        GZIPInputStream(ByteArrayInputStream(bytes)).use { input ->
            val out = ByteArrayOutputStream(bytes.size * 4)
            val chunk = ByteArray(64 * 1024)
            var total = 0
            while (true) {
                val read = input.read(chunk)
                if (read < 0) break
                total += read
                if (total > MAX_PLAINTEXT_BYTES) throw NotABackup()
                out.write(chunk, 0, read)
            }
            out.toByteArray()
        }
    } catch (e: NotABackup) {
        throw e
    } catch (_: Exception) {
        throw NotABackup()
    }
}
