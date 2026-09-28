package com.sharneng.spliit2go

import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import android.graphics.BitmapFactory
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.tasks.Task
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Receipt scanning on the phone (#125), for lib/services/receipt_scanner.dart.
 *
 * ML Kit is called directly rather than through the pub.dev plugins, which
 * would bring CocoaPods into the SwiftPM-only iOS build (#105).
 *
 * - scanDocument: ML Kit's Document Scanner, whose code and UI Google Play
 *   services downloads on first use, so it isn't in the app. It's checked
 *   for before it's started: launched without it, Play services shows its
 *   own download page, which offline is a dead end ("Can't reach the
 *   Internet", and Back doesn't leave it). When it isn't there, or anything
 *   stops it starting, the error is "unavailable" and the app uses the
 *   camera instead, while Play services fetches it for next time.
 * - prepareScanner: has Play services download the Document Scanner when it
 *   isn't there yet, called at launch and when a new expense's form opens,
 *   while online, so it's usually ready by the first scan. True when it's
 *   already installed.
 * - recognizeText: ML Kit text recognition with the Latin model bundled in
 *   the app (com.google.mlkit:text-recognition), so it works offline from
 *   the first use.
 */
class ReceiptScanChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val NAME = "com.sharneng.spliit2go/receipt_scan"
        private const val SCAN_REQUEST = 0x5ca9
    }

    private var pendingScan: MethodChannel.Result? = null
    private val recognizer by lazy { TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scanDocument" -> scanDocument(result)
            "prepareScanner" -> prepareScanner(result)
            "recognizeText" -> recognizeText(call.argument<ByteArray>("jpeg")!!, result)
            else -> result.notImplemented()
        }
    }

    private fun scanner() = GmsDocumentScanning.getClient(
        GmsDocumentScannerOptions.Builder()
            .setGalleryImportAllowed(true)
            .setPageLimit(1)
            .setResultFormats(GmsDocumentScannerOptions.RESULT_FORMAT_JPEG)
            .setScannerMode(GmsDocumentScannerOptions.SCANNER_MODE_FULL)
            .build()
    )

    /** Best effort: any failure is false, and the scan falls back as usual. */
    private fun prepareScanner(result: MethodChannel.Result) {
        try {
            val scanner = scanner()
            val modules = ModuleInstall.getClient(activity)
            modules.areModulesAvailable(scanner)
                .addOnSuccessListener { response ->
                    if (!response.areModulesAvailable()) {
                        modules.installModules(ModuleInstallRequest.newBuilder().addApi(scanner).build())
                    }
                    result.success(response.areModulesAvailable())
                }
                .addOnFailureListener { result.success(false) }
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun scanDocument(result: MethodChannel.Result) {
        // One scanner at a time: a second tap while one is open is ignored.
        if (pendingScan != null) return result.success(null)
        try {
            val scanner = scanner()
            val modules = ModuleInstall.getClient(activity)
            modules.areModulesAvailable(scanner)
                .addOnSuccessListener { response ->
                    if (response.areModulesAvailable()) {
                        start(scanner.getStartScanIntent(activity), result)
                    } else {
                        // In the background, with no UI; offline it just fails.
                        modules.installModules(ModuleInstallRequest.newBuilder().addApi(scanner).build())
                        result.error("unavailable", "The Document Scanner isn't installed yet", null)
                    }
                }
                .addOnFailureListener { e -> result.error("unavailable", e.message, null) }
        } catch (e: Exception) {
            result.error("unavailable", e.toString(), null)
        }
    }

    private fun start(intent: Task<IntentSender>, result: MethodChannel.Result) {
        intent
            .addOnSuccessListener { sender ->
                try {
                    pendingScan = result
                    activity.startIntentSenderForResult(sender, SCAN_REQUEST, null, 0, 0, 0)
                } catch (e: IntentSender.SendIntentException) {
                    pendingScan = null
                    result.error("unavailable", e.message, null)
                }
            }
            .addOnFailureListener { e -> result.error("unavailable", e.message, null) }
    }

    /** The Document Scanner's answer: the page's JPEG, or null when cancelled. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != SCAN_REQUEST) return false
        val result = pendingScan ?: return true
        pendingScan = null
        val uri = if (resultCode == Activity.RESULT_OK) {
            GmsDocumentScanningResult.fromActivityResultIntent(data)?.pages?.firstOrNull()?.imageUri
        } else {
            null
        }
        if (uri == null) {
            result.success(null)
            return true
        }
        try {
            val bytes = activity.contentResolver.openInputStream(uri)!!.use { it.readBytes() }
            result.success(bytes)
        } catch (e: Exception) {
            result.error("read", e.message, null)
        }
        return true
    }

    /** Every line of text, with its box in the image's pixels. */
    private fun recognizeText(jpeg: ByteArray, result: MethodChannel.Result) {
        val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
            ?: return result.error("decode", "Not an image", null)
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { text ->
                val lines = text.textBlocks.flatMap { it.lines }.mapNotNull { line ->
                    val box = line.boundingBox ?: return@mapNotNull null
                    mapOf(
                        "text" to line.text,
                        "left" to box.left,
                        "top" to box.top,
                        "right" to box.right,
                        "bottom" to box.bottom,
                    )
                }
                result.success(mapOf("width" to bitmap.width, "height" to bitmap.height, "lines" to lines))
            }
            .addOnFailureListener { e -> result.error("recognize", e.message, null) }
    }
}
