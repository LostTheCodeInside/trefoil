package com.lupangoding.trefoil.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.zip.GZIPOutputStream
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The encrypted backup, which is the one file a user is expected to hand to something
 * that is not this app.
 *
 * It carries every server's credentials, so the questions worth asking of it are not
 * "does a round trip work" alone: a wrong password and a damaged file must be told
 * apart from a correct one and from each other, and a single flipped byte must not
 * decrypt at all. GCM gives that last one, but only if the tag is actually checked,
 * and nothing in the app would notice if it stopped being.
 *
 * Robolectric is here for android.util.Base64 and nothing else.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BackupCryptoTest {

    private val secret = """{"servers":[{"tag":"tokyo","password":"hunter2"}]}"""

    @Test
    fun `round trips the profile it was given`() {
        val sealed = BackupCrypto.encrypt(secret, "correct horse")
        assertEquals(secret, BackupCrypto.decrypt(sealed, "correct horse"))
    }

    @Test
    fun `the ciphertext does not carry the plaintext`() {
        val sealed = BackupCrypto.encrypt(secret, "correct horse")
        // The obvious failure mode for a format like this is a stage that quietly
        // does nothing, leaving the credentials sitting in the base64.
        val decoded = String(android.util.Base64.decode(sealed, android.util.Base64.DEFAULT))
        assertTrue("magic missing", decoded.startsWith("THR2"))
        assertTrue("plaintext leaked", !decoded.contains("hunter2"))
        assertTrue("plaintext leaked", !sealed.contains("hunter2"))
    }

    @Test
    fun `the same profile and password never produce the same file twice`() {
        // A fresh salt and IV each time. Reusing an IV under one key is the single
        // way to break GCM outright, and it would be invisible from the outside.
        val first = BackupCrypto.encrypt(secret, "correct horse")
        val second = BackupCrypto.encrypt(secret, "correct horse")
        assertNotEquals(first, second)
    }

    @Test
    fun `a wrong password is refused`() {
        val sealed = BackupCrypto.encrypt(secret, "correct horse")
        assertThrows(BackupCrypto.WrongPassword::class.java) {
            BackupCrypto.decrypt(sealed, "correct hors")
        }
    }

    @Test
    fun `one flipped byte is refused`() {
        val sealed = BackupCrypto.encrypt(secret, "correct horse")
        val packed = android.util.Base64.decode(sealed, android.util.Base64.DEFAULT)
        // Last byte, which is inside the GCM tag.
        packed[packed.size - 1] = (packed[packed.size - 1].toInt() xor 0x01).toByte()
        val tampered = android.util.Base64.encodeToString(packed, android.util.Base64.NO_WRAP)
        assertThrows(BackupCrypto.WrongPassword::class.java) {
            BackupCrypto.decrypt(tampered, "correct horse")
        }
    }

    @Test
    fun `a flipped byte in the body is refused too`() {
        val sealed = BackupCrypto.encrypt(secret, "correct horse")
        val packed = android.util.Base64.decode(sealed, android.util.Base64.DEFAULT)
        // Just past the magic, salt and IV: the first byte of ciphertext.
        val bodyStart = 4 + 16 + 12
        packed[bodyStart] = (packed[bodyStart].toInt() xor 0x01).toByte()
        val tampered = android.util.Base64.encodeToString(packed, android.util.Base64.NO_WRAP)
        assertThrows(BackupCrypto.WrongPassword::class.java) {
            BackupCrypto.decrypt(tampered, "correct horse")
        }
    }

    @Test
    fun `something that is not a backup says so, rather than blaming the password`() {
        // The distinction is the whole point: told "wrong password" for a file that
        // was never a backup, a user retypes a password that was right all along.
        val notOurs = android.util.Base64.encodeToString(
            "just some text, long enough to clear the header".toByteArray(),
            android.util.Base64.NO_WRAP,
        )
        assertThrows(BackupCrypto.NotABackup::class.java) { BackupCrypto.decrypt(notOurs, "any") }
    }

    @Test
    fun `a truncated backup says so, rather than blaming the password`() {
        val sealed = BackupCrypto.encrypt(secret, "correct horse")
        val packed = android.util.Base64.decode(sealed, android.util.Base64.DEFAULT)
        // Header only: magic, salt and IV, with nothing after them.
        val header = packed.copyOfRange(0, 4 + 16 + 12)
        val short = android.util.Base64.encodeToString(header, android.util.Base64.NO_WRAP)
        assertThrows(BackupCrypto.NotABackup::class.java) { BackupCrypto.decrypt(short, "any") }
    }

    @Test
    fun `an empty password still round trips`() {
        // Not encouraged, but the UI can reach it, and PBKDF2 with an empty password
        // is a real derivation rather than an error.
        val sealed = BackupCrypto.encrypt(secret, "")
        assertEquals(secret, BackupCrypto.decrypt(sealed, ""))
    }

    @Test
    fun `a password outside ASCII round trips`() {
        val password = "パスワード🔐café"
        val sealed = BackupCrypto.encrypt(secret, password)
        assertEquals(secret, BackupCrypto.decrypt(sealed, password))
    }

    @Test
    fun `a backup made by the previous version still opens`() {
        // Every backup ever handed out has to keep working: it may be the only copy
        // of someone's servers.
        val legacy = seal("THR1", 210_000, secret.toByteArray(), "correct horse", aad = false)
        assertEquals(secret, BackupCrypto.decrypt(legacy, "correct horse"))
    }

    @Test
    fun `a backup relabelled as the older version does not open`() {
        // The version is bound into the tag, so it cannot be swapped for the weaker
        // derivation without the whole file being refused.
        val sealed = BackupCrypto.encrypt(secret, "correct horse")
        val packed = android.util.Base64.decode(sealed, android.util.Base64.DEFAULT)
        "THR1".toByteArray().copyInto(packed)
        val relabelled = android.util.Base64.encodeToString(packed, android.util.Base64.NO_WRAP)
        assertThrows(BackupCrypto.WrongPassword::class.java) {
            BackupCrypto.decrypt(relabelled, "correct horse")
        }
    }

    @Test
    fun `a large profile comes out smaller than it went in`() {
        // Backups are pasted and scanned by hand; a server list is repetitive JSON.
        val profile = (1..500).joinToString(",", "[", "]") {
            """{"tag":"server $it","type":"vless","server":"edge$it.example.com","uuid":"11111111-2222-3333-4444-555555555555"}"""
        }
        val sealed = BackupCrypto.encrypt(profile, "correct horse")
        assertTrue("${sealed.length} >= ${profile.length}", sealed.length < profile.length / 3)
        assertEquals(profile, BackupCrypto.decrypt(sealed, "correct horse"))
    }

    @Test
    fun `a backup that inflates without limit is refused`() {
        // Authenticated, so only someone with the password can build one — but people
        // are handed backups along with their password, and this must not take the
        // app down on the way in.
        val zeros = ByteArray(1024 * 1024)
        val bomb = ByteArrayOutputStream().also { out ->
            GZIPOutputStream(out).use { gz -> repeat(65) { gz.write(zeros) } }
        }.toByteArray()
        val sealed = seal("THR2", 600_000, bomb, "correct horse", aad = true)
        assertThrows(BackupCrypto.NotABackup::class.java) {
            BackupCrypto.decrypt(sealed, "correct horse")
        }
    }

    /** Builds a backup by hand, to the letter of the format, around any payload. */
    private fun seal(magic: String, iterations: Int, payload: ByteArray, password: String, aad: Boolean): String {
        val random = SecureRandom()
        val salt = ByteArray(16).also(random::nextBytes)
        val iv = ByteArray(12).also(random::nextBytes)
        val spec = PBEKeySpec(password.toCharArray(), salt, iterations, 256)
        val key = SecretKeySpec(
            SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(spec).encoded,
            "AES",
        )
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, iv))
            if (aad) updateAAD(magic.toByteArray())
        }
        val body = cipher.doFinal(payload)
        val packed = ByteBuffer.allocate(4 + 16 + 12 + body.size)
            .put(magic.toByteArray()).put(salt).put(iv).put(body).array()
        return android.util.Base64.encodeToString(packed, android.util.Base64.NO_WRAP)
    }

    @Test
    fun `whitespace around a pasted backup is tolerated`() {
        // Backups travel through chat apps and text editors, which add newlines.
        val sealed = BackupCrypto.encrypt(secret, "correct horse")
        assertEquals(secret, BackupCrypto.decrypt("\n  $sealed \n", "correct horse"))
    }
}
