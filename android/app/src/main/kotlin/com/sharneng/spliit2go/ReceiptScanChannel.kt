package com.sharneng.spliit2go

import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import android.graphics.BitmapFactory
import com.google.android.gms.common.moduleinstall.ModuleInstall
import com.google.android.gms.common.moduleinstall.InstallStatusListener
import com.google.android.gms.common.moduleinstall.ModuleInstallClient
import com.google.android.gms.common.moduleinstall.ModuleInstallRequest
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate
import com.google.android.gms.common.moduleinstall.ModuleInstallStatusUpdate.InstallState
import com.google.android.gms.tasks.Task
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.documentscanner.GmsDocumentScannerOptions
import com.google.mlkit.vision.documentscanner.GmsDocumentScanning
import com.google.mlkit.vision.documentscanner.GmsDocumentScanningResult
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
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
 *   isn't there yet, so it's usually ready by the first scan. Called while
 *   online, at launch and whenever a connection comes back, until it's
 *   installed (ReceiptScannerWarmup in receipt_scanner.dart). True when it's
 *   already installed.
 * - recognizeText: every line of text with its box and corners, by ML Kit
 *   text recognition in the receipt language the user
 *   picked (#153). Latin is bundled in the app (com.google.mlkit:text-
 *   recognition), so it works offline from the first use. Chinese and
 *   Japanese are models Google Play services downloads on request, shared
 *   with other apps and not removed with this one; without the model the
 *   error is "model-missing".
 * - textModels: which of the downloadable models Play services has now.
 *   The app never keeps its own record of that.
 * - installTextModel: downloads one, answering when it's installed, or
 *   "install-failed".
 * - removeTextModel: tells Play services the app no longer needs one. It
 *   frees the space later, and only if no other app uses it.
 */
class ReceiptScanChannel(private val activity: Activity) : MethodChannel.MethodCallHandler {
    companion object {
        const val NAME = "com.sharneng.spliit2go/receipt_scan"
        private const val SCAN_REQUEST = 0x5ca9
    }

    private var pendingScan: MethodChannel.Result? = null
    private val recognizers = mutableMapOf<String, TextRecognizer>()

    /** A receipt language's recognizer: "latin", "chinese" or "japanese". */
    private fun recognizer(script: String): TextRecognizer = recognizers.getOrPut(script) {
        when (script) {
            "chinese" -> TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
            "japanese" -> TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())
            "latin" -> TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
            else -> throw IllegalArgumentException("Unknown receipt script $script")
        }
    }

    /** The models Play services downloads; Latin is bundled. */
    private val downloadable = listOf("chinese", "japanese")

    private fun modules(): ModuleInstallClient = ModuleInstall.getClient(activity)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "scanDocument" -> scanDocument(result)
            "prepareScanner" -> prepareScanner(result)
            "recognizeText" -> recognizeText(
                call.argument<ByteArray>("jpeg")!!,
                call.argument<String>("script") ?: "latin",
                result,
            )
            "textModels" -> textModels(result)
            "installTextModel" -> installTextModel(call.argument<String>("script")!!, result)
            "removeTextModel" -> removeTextModel(call.argument<String>("script")!!, result)
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

    /** For each downloadable model, whether Play services has it now. */
    private fun textModels(result: MethodChannel.Result) {
        val answers = mutableMapOf<String, Boolean>()
        for (script in downloadable) {
            modules().areModulesAvailable(recognizer(script)).addOnCompleteListener { task ->
                answers[script] = task.isSuccessful && task.result.areModulesAvailable()
                if (answers.size == downloadable.size) result.success(answers)
            }
        }
    }

    /** Answers true once installed, whether now or already. */
    private fun installTextModel(script: String, result: MethodChannel.Result) {
        if (script !in downloadable) return result.success(true)
        val client = modules()
        var answered = false
        fun answer(installed: Boolean, message: String? = null) {
            if (answered) return
            answered = true
            if (installed) result.success(true) else result.error("install-failed", message, null)
        }
        val listener = object : InstallStatusListener {
            override fun onInstallStatusUpdated(update: ModuleInstallStatusUpdate) {
                when (update.installState) {
                    InstallState.STATE_COMPLETED -> answer(true)
                    InstallState.STATE_FAILED, InstallState.STATE_CANCELED ->
                        answer(false, "Install state ${update.installState}, error ${update.errorCode}")
                    else -> return
                }
                client.unregisterListener(this)
            }
        }
        val request = ModuleInstallRequest.newBuilder()
            .addApi(recognizer(script))
            .setListener(listener)
            .build()
        client.installModules(request)
            .addOnSuccessListener { response ->
                if (response.areModulesAlreadyInstalled()) {
                    client.unregisterListener(listener)
                    answer(true)
                }
            }
            .addOnFailureListener { e ->
                client.unregisterListener(listener)
                answer(false, e.message)
            }
    }

    private fun removeTextModel(script: String, result: MethodChannel.Result) {
        if (script !in downloadable) return result.success(null)
        modules().releaseModules(recognizer(script))
            .addOnSuccessListener { result.success(null) }
            .addOnFailureListener { e -> result.error("remove-failed", e.message, null) }
    }

    /** Every line of text, with its box in the image's pixels. */
    private fun recognizeText(jpeg: ByteArray, script: String, result: MethodChannel.Result) {
        val bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
            ?: return result.error("decode", "Not an image", null)
        val recognizer = recognizer(script)
        if (script !in downloadable) return read(recognizer, bitmap, result)
        // Started without its model, a recognizer fails only after asking
        // Play services for it, so it's checked first.
        modules().areModulesAvailable(recognizer)
            .addOnSuccessListener { response ->
                if (response.areModulesAvailable()) {
                    read(recognizer, bitmap, result)
                } else {
                    result.error("model-missing", "The $script text model isn't installed", null)
                }
            }
            .addOnFailureListener { e -> result.error("model-missing", e.message, null) }
    }

    private fun read(recognizer: TextRecognizer, bitmap: android.graphics.Bitmap, result: MethodChannel.Result) {
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
                        // The line's own corners, clockwise from its top left:
                        // on a tilted photo the box above is larger than the
                        // line, and the tilt shows (#153).
                        "corners" to line.cornerPoints?.flatMap { listOf(it.x, it.y) },
                    )
                }
                result.success(mapOf("width" to bitmap.width, "height" to bitmap.height, "lines" to lines))
            }
            .addOnFailureListener { e -> result.error("recognize", e.message, null) }
    }
}
