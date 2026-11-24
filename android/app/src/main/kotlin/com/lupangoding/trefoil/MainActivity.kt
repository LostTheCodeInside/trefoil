package com.lupangoding.trefoil

import android.content.Intent
import com.lupangoding.trefoil.bridge.TrefoilBridge
import com.lupangoding.trefoil.bridge.UpdateBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var bridge: TrefoilBridge? = null
    private var updates: UpdateBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = TrefoilBridge(this, flutterEngine.dartExecutor.binaryMessenger).also { it.attach() }
        updates = UpdateBridge(this, flutterEngine.dartExecutor.binaryMessenger).also { it.attach() }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // The VPN consent dialog and the backup file pickers report back here;
        // anything else belongs to plugins.
        if (bridge?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        bridge?.detach()
        bridge = null
        updates?.detach()
        updates = null
        super.onDestroy()
    }
}
