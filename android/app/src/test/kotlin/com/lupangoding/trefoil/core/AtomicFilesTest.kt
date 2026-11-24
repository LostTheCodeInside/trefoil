package com.lupangoding.trefoil.core

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** A file this replaces is either the old one or the new one, and never part of either. */
class AtomicFilesTest {

    @get:Rule
    val folder = TemporaryFolder()

    private fun leftovers() = folder.root.walk().filter { it.name.endsWith(".tmp") }.toList()

    @Test
    fun `replaces what was there`() {
        val file = folder.newFile("state.json").apply { writeText("old, and longer than the new") }
        AtomicFiles.write(file, "new")
        assertEquals("new", file.readText())
        assertTrue(leftovers().isEmpty())
    }

    @Test
    fun `creates what was not`() {
        val file = File(folder.root, "state.json")
        AtomicFiles.write(file, "é")
        assertEquals("é", file.readText())
    }

    @Test
    fun `a write that cannot land leaves the old one and no debris`() {
        // A directory in the way, which no file can be renamed over.
        val target = folder.newFolder("state.json")
        File(target, "kept").writeText("kept")
        assertThrows(IllegalStateException::class.java) { AtomicFiles.write(target, "new") }
        assertEquals("kept", File(target, "kept").readText())
        assertTrue(leftovers().isEmpty())
    }

    @Test
    fun `nowhere to write is an error rather than a file somewhere else`() {
        val target = File(folder.root, "missing/state.json")
        assertThrows(Exception::class.java) { AtomicFiles.write(target, "new") }
        assertFalse(target.exists())
    }
}
