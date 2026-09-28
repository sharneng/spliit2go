package com.sharneng.spliit2go

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var receiptScan: ReceiptScanChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = ReceiptScanChannel(this)
        receiptScan = channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ReceiptScanChannel.NAME)
            .setMethodCallHandler(channel)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (receiptScan?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
