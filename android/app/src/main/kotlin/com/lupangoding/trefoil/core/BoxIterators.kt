package com.lupangoding.trefoil.core

import io.nekohasekai.libbox.NetworkInterfaceIterator
import io.nekohasekai.libbox.RoutePrefix
import io.nekohasekai.libbox.RoutePrefixIterator
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.NetworkInterface as BoxNetworkInterface

/**
 * gomobile cannot marshal Java collections across the JNI boundary, so every list
 * passed to or from libbox is a one-shot cursor. These adapters keep that detail
 * from leaking into the rest of the code.
 *
 * Note the cursors are single-pass: draining one twice yields nothing the second
 * time, which is why the `toList` helpers copy eagerly.
 */

fun Iterable<String>.toBoxStringIterator(): StringIterator = object : StringIterator {
    private val backing = this@toBoxStringIterator.toList()
    private var index = 0
    override fun hasNext(): Boolean = index < backing.size
    override fun next(): String = backing[index++]
    override fun len(): Int = backing.size
}

fun StringIterator?.toList(): List<String> {
    val out = mutableListOf<String>()
    while (this != null && hasNext()) out.add(next())
    return out
}

fun RoutePrefixIterator?.toList(): List<RoutePrefix> {
    val out = mutableListOf<RoutePrefix>()
    while (this != null && hasNext()) out.add(next())
    return out
}

fun Iterable<BoxNetworkInterface>.toBoxInterfaceIterator(): NetworkInterfaceIterator =
    object : NetworkInterfaceIterator {
        private val backing = this@toBoxInterfaceIterator.toList()
        private var index = 0
        override fun hasNext(): Boolean = index < backing.size
        override fun next(): BoxNetworkInterface = backing[index++]
    }
