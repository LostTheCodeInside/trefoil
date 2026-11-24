package com.lupangoding.trefoil.core

import android.content.Context
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File

/** The checks that stand between a download and the system installer. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class UpdateInstallerTest {

    private lateinit var context: Context
    private lateinit var updates: File

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        updates = UpdateInstaller.updatesDir(context).apply { mkdirs() }
    }

    @Test
    fun hashesTheWholeFile() {
        val file = File(updates, "abc.apk").apply { writeText("abc") }
        assertEquals(
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            UpdateInstaller.sha256(file),
        )
    }

    // A path is checked after resolving it, and a directory merely sharing the name's
    // prefix is not inside it.
    @Test
    fun onlyTheUpdatesDirectoryCounts() {
        assertTrue(UpdateInstaller.isInside(File(updates, "update.apk"), updates))
        assertFalse(UpdateInstaller.isInside(File(updates, "../update.apk"), updates))
        assertFalse(UpdateInstaller.isInside(File(updates.path + "-other", "update.apk"), updates))
        assertFalse(UpdateInstaller.isInside(updates, updates))
    }

    @Test
    fun anyDifferenceInSignersRefuses() {
        assertTrue(UpdateInstaller.sameSigners(setOf("a"), setOf("a")))
        assertFalse(UpdateInstaller.sameSigners(setOf("a"), setOf("b")))
        assertFalse(UpdateInstaller.sameSigners(setOf("a"), setOf("a", "b")))
    }

    // Android could not say: its installer compares the keys itself, so that is left
    // to it rather than blocking every update on an old phone.
    @Test
    fun unknownSignersAreLeftToTheInstaller() {
        assertTrue(UpdateInstaller.sameSigners(null, setOf("a")))
        assertTrue(UpdateInstaller.sameSigners(setOf("a"), emptySet()))
    }

    @Test
    fun aFileOutsideTheCacheIsRefusedBeforeAnythingElse() {
        val outside = File(context.filesDir, "update.apk").apply {
            parentFile?.mkdirs()
            writeText("abc")
        }
        assertEquals("bad_path", UpdateInstaller.verify(context, outside, "0".repeat(64), 2))
    }

    @Test
    fun aFileThatIsNotWhatWasPublishedIsRefused() {
        val apk = File(updates, "update.apk").apply { writeText("not what was published") }
        assertEquals("hash_mismatch", UpdateInstaller.verify(context, apk, "0".repeat(64), 2))
    }
}
