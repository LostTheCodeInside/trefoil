package com.lupangoding.trefoil.core

import java.io.File
import java.io.FileOutputStream

/**
 * Replaces a file in one step.
 *
 * Written beside the target and renamed over it, so a crash part-way leaves the old
 * file rather than half of the new one. Synced before the rename: without that the
 * rename can reach the disk ahead of the bytes, and a phone that loses power in
 * between comes back to a file that is there and empty.
 */
internal object AtomicFiles {
    fun write(target: File, content: String) {
        val temp = File(target.parentFile, "${target.name}.tmp")
        try {
            FileOutputStream(temp).use { out ->
                out.write(content.toByteArray(Charsets.UTF_8))
                out.fd.sync()
            }
            if (!temp.renameTo(target)) error("Could not replace ${target.name}")
        } catch (t: Throwable) {
            temp.delete()
            throw t
        }
    }
}
