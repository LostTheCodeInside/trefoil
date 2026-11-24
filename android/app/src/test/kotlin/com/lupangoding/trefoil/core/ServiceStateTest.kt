package com.lupangoding.trefoil.core

import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test

/**
 * The one place the tunnel's state lives, written to from the main thread, the
 * service's and the core's.
 */
class ServiceStateTest {

    @Before
    fun clear() = ServiceState.update(TunnelStage.STOPPED, profileName = "", clearError = true)

    @Test
    fun `changes what is given and keeps the rest`() {
        ServiceState.update(stage = TunnelStage.STARTED, profileName = "tokyo")
        ServiceState.update(profileName = "osaka")
        assertEquals(TunnelStage.STARTED, ServiceState.current.stage)
        assertEquals("osaka", ServiceState.current.profileName)
    }

    @Test
    fun `naming the server does not restart the clock`() {
        ServiceState.update(stage = TunnelStage.STARTED)
        val started = ServiceState.current.startedAt
        Thread.sleep(5)
        ServiceState.update(profileName = "osaka")
        assertEquals(started, ServiceState.current.startedAt)
    }

    @Test
    fun `a tunnel that comes back has a clock of its own`() {
        ServiceState.update(stage = TunnelStage.STARTED)
        val started = ServiceState.current.startedAt
        Thread.sleep(5)
        ServiceState.update(stage = TunnelStage.STARTING)
        assertEquals(0L, ServiceState.current.startedAt)
        ServiceState.update(stage = TunnelStage.STARTED)
        assertNotEquals(started, ServiceState.current.startedAt)
    }

    @Test
    fun `a failure is kept until a tunnel is started again`() {
        ServiceState.fail("no route")
        ServiceState.update(stage = TunnelStage.STOPPED)
        assertEquals("no route", ServiceState.current.error)
        ServiceState.update(stage = TunnelStage.STARTING, clearError = true)
        assertNull(ServiceState.current.error)
    }

    @Test
    fun `one change never undoes another made at the same moment`() {
        // Read and then written back, a name arriving from the core put back whichever
        // stage it had read: a tunnel just disconnected went on saying it was up.
        repeat(300) {
            ServiceState.update(stage = TunnelStage.STARTED, profileName = "a")
            val go = CountDownLatch(1)
            val naming = thread {
                go.await()
                repeat(20) { ServiceState.update(profileName = "b") }
            }
            val stopping = thread {
                go.await()
                ServiceState.update(stage = TunnelStage.STOPPING)
            }
            go.countDown()
            naming.join()
            stopping.join()
            assertEquals(TunnelStage.STOPPING, ServiceState.current.stage)
            assertEquals("b", ServiceState.current.profileName)
        }
    }
}
