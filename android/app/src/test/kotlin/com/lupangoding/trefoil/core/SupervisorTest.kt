package com.lupangoding.trefoil.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * When a core that has gone quiet is restarted, and when that stops being worth it.
 *
 * A policy that is wrong is worse than none: it turns one failure into a loop that
 * burns the battery and keeps the tunnel half up.
 */
class SupervisorTest {

    @Test
    fun `waits longer each time, and then gives up`() {
        val supervisor = Supervisor()
        assertEquals(
            listOf(2_000L, 4_000L, 8_000L, 16_000L, 32_000L),
            List(5) { supervisor.nextDelayMs(it * 1_000L) },
        )
        assertNull(supervisor.nextDelayMs(6_000))
    }

    @Test
    fun `a stretch of health earns the attempts back`() {
        val supervisor = Supervisor(maxAttempts = 2)
        supervisor.nextDelayMs(0)
        supervisor.nextDelayMs(1_000)
        supervisor.onHealthy(60_000)
        assertNull("too soon to call it recovered", supervisor.nextDelayMs(60_000))
        supervisor.onHealthy(121_000)
        assertEquals(2_000L, supervisor.nextDelayMs(121_000))
    }

    @Test
    fun `quiet is measured against how often it is asked to report`() {
        val supervisor = Supervisor()
        assertFalse(supervisor.isStale(now = 20_000, lastReportAt = 1, intervalSeconds = 1))
        assertTrue(supervisor.isStale(now = 20_002, lastReportAt = 1, intervalSeconds = 1))
        assertFalse(supervisor.isStale(now = 50_000, lastReportAt = 1, intervalSeconds = 10))
        assertTrue(supervisor.isStale(now = 50_002, lastReportAt = 1, intervalSeconds = 10))
    }

    @Test
    fun `nothing is stale while no report is expected`() {
        assertFalse(Supervisor().isStale(now = 1_000_000, lastReportAt = 0, intervalSeconds = 1))
    }
}
