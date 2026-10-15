package dev.aihaptics.haptics_lab

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import android.app.Activity
import android.content.Intent

class MainActivity : FlutterActivity() {
    private val blePermissions by lazy { CoyoteBlePermissions(this) }
    private var exportResult: MethodChannel.Result? = null
    private var exportBytes: ByteArray? = null
    private var output: AudioTrack? = null
    private var speechPlayback: SpeechPlayback? = null
    private var networkLifecycle: NetworkLifecycle? = null
    private var voiceCaptureWatch: VoiceCaptureWatch? = null
    private var framesWritten = 0L
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        networkLifecycle = NetworkLifecycle(this, MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aihaptics/network"))
        speechPlayback = SpeechPlayback(this,
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aihaptics/speech"))
        val ble = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aihaptics/coyote_ble")
        CoyoteBle.get(this).attach(ble)
        ble.setMethodCallHandler { call, result ->
            if (call.method == "permissions") blePermissions.request(result)
            else CoyoteBle.get(this).call(call.method, call.arguments as? Map<*, *>, result)
        }
        val background = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aihaptics/background")
        voiceCaptureWatch = VoiceCaptureWatch(this) { background.invokeMethod("pauseVoice", null) }
        SessionService.onStop = { background.invokeMethod("stop", null) }
        SessionService.onPauseVoice = { background.invokeMethod("pauseVoice", null) }
        SessionService.onEndVoice = { background.invokeMethod("endVoice", null) }
        background.setMethodCallHandler { call, result ->
            when (call.method) {
                "stop" -> { voiceCaptureWatch?.setActive(false); stopService(Intent(this, SessionService::class.java)); result.success(null) }
                "update" -> {
                    voiceCaptureWatch?.setActive(call.argument<Boolean>("active") == true && call.argument<Boolean>("continuous") == true)
                    if (call.argument<Boolean>("active") != true) {
                        stopService(Intent(this, SessionService::class.java)); result.success(true)
                    } else {
                        try {
                            if (android.os.Build.VERSION.SDK_INT >= 33 &&
                                checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                                if (!notificationAsked) {
                                    notificationAsked = true
                                    requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 4802)
                                }
                                // Continuous capture must keep visible notification controls.
                                // After granting permission, the user explicitly resumes in-app.
                                if (call.argument<Boolean>("continuous") == true) {
                                    result.success(false)
                                    return@setMethodCallHandler
                                }
                            }
                            SessionService.onReady = { ok -> result.success(ok) }
                            val intent = Intent(this, SessionService::class.java)
                                .putExtra("microphone", call.argument<Boolean>("microphone") == true)
                                .putExtra("continuous", call.argument<Boolean>("continuous") == true)
                                .putExtra("device", call.argument<Boolean>("device") == true)
                                .putExtra("simulation", call.argument<Boolean>("simulation") == true)
                                .putExtra("mediaPlayback", call.argument<Boolean>("mediaPlayback") == true)
                            if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                        } catch (_: Exception) {
                            SessionService.onReady = null
                            result.success(false)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aihaptics/files").setMethodCallHandler { call, result ->
            if (call.method != "export_pulse") {
                result.notImplemented()
            } else if (exportResult != null) {
                result.error("export_busy", "Finish the current export first", null)
            } else {
                try {
                    val bytes = call.argument<ByteArray>("bytes") ?: error("missing_bytes")
                    val name = call.argument<String>("name") ?: error("missing_name")
                    require(bytes.isNotEmpty() && bytes.size <= 65536)
                    require(name.endsWith(".pulse") && !name.contains('/') && !name.contains('\\'))
                    exportResult = result
                    exportBytes = bytes
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "application/octet-stream"
                        putExtra(Intent.EXTRA_TITLE, name)
                    }, 4801)
                } catch (_: Exception) {
                    exportResult = null
                    exportBytes = null
                    result.error("export_failed", "Unable to open document picker", null)
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aihaptics/pcm").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "seal", "unseal" -> {
                        val bytes = call.arguments as ByteArray
                        require(bytes.size <= 16384)
                        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                        val alias = "aihaptics-beta-account"
                        if (!keys.containsAlias(alias)) {
                            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                                init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
                                generateKey()
                            }
                        }
                        val key = keys.getKey(alias, null) as SecretKey
                        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                        if (call.method == "seal") {
                            cipher.init(Cipher.ENCRYPT_MODE, key)
                            result.success(cipher.iv + cipher.doFinal(bytes))
                        } else {
                            require(bytes.size > 28)
                            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
                            result.success(cipher.doFinal(bytes.copyOfRange(12, bytes.size)))
                        }
                    }
                    "setup" -> {
                        releaseOutput()
                        output = AudioTrack.Builder()
                            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                            .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(24000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                            .setBufferSizeInBytes(maxOf(9600, AudioTrack.getMinBufferSize(24000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)))
                            .setTransferMode(AudioTrack.MODE_STREAM).build()
                        check(output!!.state == AudioTrack.STATE_INITIALIZED)
                        if (android.os.Build.VERSION.SDK_INT >= 31) output!!.setStartThresholdInFrames(240)
                        output!!.play(); result.success(null)
                    }
                    "feed" -> {
                        val bytes = call.arguments as ByteArray
                        val track = output ?: error("audio_unavailable")
                        require(bytes.isNotEmpty() && bytes.size % 2 == 0 && bytes.size <= 48000)
                        val written = track.write(bytes, 0, bytes.size, AudioTrack.WRITE_NON_BLOCKING)
                        if (written > 0) framesWritten += written / 2
                        check(written == bytes.size)
                        result.success(null)
                    }
                    "pending" -> result.success(maxOf(0L, framesWritten - ((output?.playbackHeadPosition ?: 0).toLong() and 0xffffffffL)).toInt())
                    "capacity" -> result.success(output?.bufferSizeInFrames ?: 0)
                    "stop" -> { output?.pause(); output?.flush(); framesWritten = 0; output?.play(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) { result.error("audio_error", "PCM output unavailable or queue full", null) }
        }
    }
    private fun releaseOutput() { output?.pause(); output?.flush(); output?.release(); output = null; framesWritten = 0 }
    private var notificationAsked = false
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        blePermissions.result(requestCode, grantResults)
        if (requestCode == 4802 && grantResults.firstOrNull() == android.content.pm.PackageManager.PERMISSION_GRANTED) {
            SessionService.current?.refreshNotification()
        }
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4801) return
        val result = exportResult ?: return
        val bytes = exportBytes
        exportResult = null
        exportBytes = null
        if (resultCode != Activity.RESULT_OK) { result.success(false); return }
        try {
            val uri = data?.data ?: error("missing_uri")
            require(bytes != null)
            val stream = contentResolver.openOutputStream(uri, "wt") ?: error("missing_stream")
            stream.use { it.write(bytes) }
            result.success(true)
        } catch (_: Exception) {
            result.error("export_failed", "Unable to save document", null)
        }
    }
    override fun onDestroy() {
        voiceCaptureWatch?.dispose()
        voiceCaptureWatch = null
        networkLifecycle?.dispose()
        networkLifecycle = null
        speechPlayback?.dispose()
        speechPlayback = null
        blePermissions.dispose()
        CoyoteBle.stopForService()
        CoyoteBle.get(this).attach(null)
        exportResult?.error("export_cancelled", "Activity closed", null)
        exportResult = null
        exportBytes = null
        stopService(Intent(this, SessionService::class.java))
        SessionService.onStop = null
        SessionService.onPauseVoice = null
        SessionService.onEndVoice = null
        releaseOutput(); super.onDestroy()
    }
}
