package com.sharneng.spliit2go

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Intent
import android.os.Build
import android.view.textclassifier.TextClassifier
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
        // The commit this build is from (#176), set by build.gradle.kts.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sharneng.spliit2go/build_info")
            .setMethodCallHandler { call, result ->
                if (call.method == "gitCommit") result.success(BuildConfig.GIT_COMMIT) else result.notImplemented()
            }
        // The Join screen's paste suggestion (#221): whether the clipboard
        // probably holds a link, from its description, without reading it.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sharneng.spliit2go/paste_link")
            .setMethodCallHandler { call, result ->
                if (call.method == "probablyHasLink") result.success(clipboardProbablyHasLink())
                else result.notImplemented()
            }
    }

    private fun clipboardProbablyHasLink(): Boolean {
        val clip = getSystemService(ClipboardManager::class.java)?.primaryClipDescription ?: return false
        if (clip.hasMimeType(ClipDescription.MIMETYPE_TEXT_URILIST)) return true
        if (!clip.hasMimeType("text/*")) return false
        // Android 12 classifies copied text; before it, any text may be one.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            clip.classificationStatus == ClipDescription.CLASSIFICATION_COMPLETE
        ) {
            return clip.getConfidenceScore(TextClassifier.TYPE_URL) > 0.5f
        }
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (receiptScan?.onActivityResult(requestCode, resultCode, data) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}
