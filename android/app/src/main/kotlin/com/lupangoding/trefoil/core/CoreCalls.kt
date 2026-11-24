package com.lupangoding.trefoil.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

/**
 * Calls to the running core, made where waiting for the answer hurts nobody.
 *
 * They are all RPCs to the command server, and none of them has a limit of its own: a
 * core that has wedged simply never answers. Made on the main thread, as they used to
 * be, that froze the app with it, at exactly the moment someone was trying to find out
 * what was wrong.
 */
internal object CoreCalls {

    private const val TIMEOUT_MS = 5_000L

    /** A few, so calls a dead core is sitting on cannot pile up without end. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(4))

    /** Runs [block] and gives back what it returned, or throws when it took too long. */
    suspend fun <T> call(block: () -> T): T {
        // Apart from the waiting: a call into Go cannot be cancelled, only left behind.
        val work = scope.async { block() }
        return try {
            withTimeout(TIMEOUT_MS) { work.await() }
        } catch (e: TimeoutCancellationException) {
            work.cancel()
            throw IllegalStateException("The core did not answer", e)
        }
    }

    /**
     * One thing at a time, in the order asked.
     *
     * For a subscription, whose start waits for the core to answer and whose stop must
     * not overtake it.
     */
    class Lane {
        private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO.limitedParallelism(1))

        fun post(block: () -> Unit) {
            scope.launch { runCatching(block) }
        }
    }
}
