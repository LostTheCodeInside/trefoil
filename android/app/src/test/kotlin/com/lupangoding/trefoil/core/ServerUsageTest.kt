package com.lupangoding.trefoil.core

import android.content.Context
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * The lifetime per-server totals, which the service records while the app is closed.
 *
 * The figure a user reads in the server list comes from here, and the ways it can be
 * wrong are all silent: traffic attributed to whichever server happened to be active
 * when the write landed, a reconnect counted as one enormous transfer because the
 * session totals restarted at zero, or the file growing without limit as one
 * subscription refresh after another brings a new set of names.
 *
 * ServerUsage is an object with mutable state, so each test starts by clearing both
 * halves of it: the file and the counters held in memory.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ServerUsageTest {

    private val context: Context get() = RuntimeEnvironment.getApplication()

    private fun read(): JSONObject {
        val file = ServerUsage.file(context)
        return if (file.isFile) JSONObject(file.readText()) else JSONObject()
    }

    private fun totalFor(tag: String): Long {
        val entry = read().optJSONObject(tag) ?: return 0
        return entry.optLong("up") + entry.optLong("down")
    }

    @Before
    fun clear() {
        ServerUsage.file(context).delete()
        // Drops whatever is pending and puts the session counters back to zero.
        ServerUsage.setActive(context, "")
        ServerUsage.reset(context)
        ServerUsage.file(context).delete()
    }

    @Test
    fun `counts a session against the server that carried it`() {
        ServerUsage.setActive(context, "tokyo")
        ServerUsage.observe(context, uplinkTotal = 100, downlinkTotal = 400)
        ServerUsage.flush(context)

        assertEquals(100L, read().getJSONObject("tokyo").getLong("up"))
        assertEquals(400L, read().getJSONObject("tokyo").getLong("down"))
    }

    @Test
    fun `counts the increase, not the running total, on every tick`() {
        ServerUsage.setActive(context, "tokyo")
        ServerUsage.observe(context, uplinkTotal = 100, downlinkTotal = 100)
        ServerUsage.observe(context, uplinkTotal = 250, downlinkTotal = 300)
        ServerUsage.flush(context)

        // 250 and 300, not 350 and 400: the ticks carry totals, and adding them
        // whole would inflate every reading by the sum of the ones before it.
        assertEquals(250L, read().getJSONObject("tokyo").getLong("up"))
        assertEquals(300L, read().getJSONObject("tokyo").getLong("down"))
    }

    @Test
    fun `a reconnect is not counted as one enormous transfer`() {
        ServerUsage.setActive(context, "tokyo")
        ServerUsage.observe(context, uplinkTotal = 1_000, downlinkTotal = 1_000)
        // A new session: the core's totals start again from zero, so this tick is
        // smaller than the last. Treated as a difference it would be negative; the
        // figure that is actually meant is the new total itself.
        ServerUsage.observe(context, uplinkTotal = 30, downlinkTotal = 40)
        ServerUsage.flush(context)

        assertEquals(1_030L, read().getJSONObject("tokyo").getLong("up"))
        assertEquals(1_040L, read().getJSONObject("tokyo").getLong("down"))
    }

    @Test
    fun `switching server flushes first, so nothing lands under the wrong name`() {
        ServerUsage.setActive(context, "tokyo")
        ServerUsage.observe(context, uplinkTotal = 500, downlinkTotal = 500)
        // A live switch, with no reconnect: what has accumulated belongs to tokyo.
        ServerUsage.setActive(context, "osaka")
        ServerUsage.observe(context, uplinkTotal = 700, downlinkTotal = 700)
        ServerUsage.flush(context)

        assertEquals(1_000L, totalFor("tokyo"))
        assertEquals(400L, totalFor("osaka"))
    }

    @Test
    fun `traffic with no server named is dropped rather than guessed at`() {
        ServerUsage.observe(context, uplinkTotal = 900, downlinkTotal = 900)
        ServerUsage.flush(context)

        assertEquals(0, read().length())
    }

    @Test
    fun `totals survive across flushes`() {
        ServerUsage.setActive(context, "tokyo")
        ServerUsage.observe(context, uplinkTotal = 10, downlinkTotal = 10)
        ServerUsage.flush(context)
        ServerUsage.observe(context, uplinkTotal = 60, downlinkTotal = 60)
        ServerUsage.flush(context)

        assertEquals(120L, totalFor("tokyo"))
    }

    @Test
    fun `forget removes one server and leaves the rest`() {
        ServerUsage.setActive(context, "tokyo")
        ServerUsage.observe(context, uplinkTotal = 100, downlinkTotal = 100)
        ServerUsage.setActive(context, "osaka")
        ServerUsage.observe(context, uplinkTotal = 300, downlinkTotal = 300)
        ServerUsage.flush(context)

        ServerUsage.forget(context, "tokyo")

        assertFalse(read().has("tokyo"))
        assertTrue(read().has("osaka"))
    }

    @Test
    fun `forgetting something that was never there does no harm`() {
        ServerUsage.setActive(context, "tokyo")
        ServerUsage.observe(context, uplinkTotal = 100, downlinkTotal = 100)
        ServerUsage.flush(context)

        ServerUsage.forget(context, "never-existed")

        assertEquals(200L, totalFor("tokyo"))
    }

    @Test
    fun `the file stops growing, and it is the smallest totals that go`() {
        // Every subscription refresh can bring a new set of names, so without a
        // ceiling this file grows for as long as the app stays installed.
        val root = JSONObject()
        for (i in 1..320) {
            root.put("server-$i", JSONObject().put("up", i.toLong()).put("down", 0L))
        }
        ServerUsage.file(context).writeText(root.toString())

        // One more flush is what triggers the prune.
        ServerUsage.setActive(context, "server-320")
        ServerUsage.observe(context, uplinkTotal = 1, downlinkTotal = 0)
        ServerUsage.flush(context)

        val after = read()
        assertEquals(300, after.length())
        // 320 entries capped at 300 drops the 20 smallest, which are 1 through 20.
        assertFalse("smallest should have gone", after.has("server-1"))
        assertFalse("smallest should have gone", after.has("server-20"))
        assertTrue("largest should have stayed", after.has("server-21"))
        assertTrue("largest should have stayed", after.has("server-320"))
    }

    @Test
    fun `a file left unparseable does not take the totals down with it`() {
        ServerUsage.file(context).writeText("{ this is not json")

        ServerUsage.setActive(context, "tokyo")
        ServerUsage.observe(context, uplinkTotal = 50, downlinkTotal = 50)
        ServerUsage.flush(context)

        // Started again rather than throwing: another process writes this file, and
        // a partial write must cost the history, never the tunnel.
        assertEquals(100L, totalFor("tokyo"))
    }

    @Test
    fun `no temp file is left behind after a write`() {
        ServerUsage.setActive(context, "tokyo")
        ServerUsage.observe(context, uplinkTotal = 10, downlinkTotal = 10)
        ServerUsage.flush(context)

        val file = ServerUsage.file(context)
        val temp = java.io.File(file.parentFile, "${file.name}.tmp")
        assertFalse("temp file should have been renamed away", temp.exists())
    }

    @Test
    fun `recording can be switched off`() {
        AppPrefs.setTrafficStats(context, false)
        try {
            ServerUsage.setActive(context, "tokyo")
            ServerUsage.observe(context, uplinkTotal = 999, downlinkTotal = 999)
            ServerUsage.flush(context)
            assertEquals(0L, totalFor("tokyo"))
        } finally {
            AppPrefs.setTrafficStats(context, true)
        }
    }
}
