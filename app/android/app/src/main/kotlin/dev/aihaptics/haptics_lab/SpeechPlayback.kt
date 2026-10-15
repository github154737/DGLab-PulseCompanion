package dev.aihaptics.haptics_lab

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.AudioDeviceInfo
import android.media.audiofx.AcousticEchoCanceler
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.net.URI
import java.util.concurrent.Executors

/** User-requested MP3 playback only. Never restarts after interruption or process death. */
class SpeechPlayback(context: Context, private val channel: MethodChannel) {
    companion object {
        private var current: SpeechPlayback? = null
        fun stopForService() { current?.stop() }
        private const val MAX_AUDIO_BYTES = 20 * 1024 * 1024
    }

    private val app = context.applicationContext
    private val audio = app.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val handler = Handler(Looper.getMainLooper())
    private val files = Executors.newSingleThreadExecutor()
    private val cache = File(app.cacheDir, "speech-playback")
    private var duplexCapture = false
    private val attributes get() = AudioAttributes.Builder()
        .setUsage(if (duplexCapture) AudioAttributes.USAGE_VOICE_COMMUNICATION else AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build()
    private var player: MediaPlayer? = null
    private var audioFile: File? = null
    private var activeId: Int? = null
    private var generation = 0L
    private var pending: MethodChannel.Result? = null
    private var focusRequest: AudioFocusRequest? = null
    private var focusHeld = false
    private var receiverRegistered = false
    private var disposed = false

    private var focusListener: AudioManager.OnAudioFocusChangeListener? = null
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) stop()
        }
    }
    private val prepareTimeout = Runnable { fail("prepare_timeout") }
    private val progress = object : Runnable {
        override fun run() {
            val mp = player ?: return
            if (activeId == null) return
            try {
                if (mp.isPlaying) {
                    emit("playing", mp.currentPosition, mp.duration)
                    handler.postDelayed(this, 250)
                }
            } catch (_: Exception) { fail("playback_failed") }
        }
    }

    init {
        current?.dispose()
        current = this
        // Delete only this player's abandoned temporary files after a process crash.
        files.execute {
            cache.mkdir()
            cache.listFiles()?.filter { it.isFile && it.name.startsWith("speech-") && it.extension == "mp3" }
                ?.forEach { it.delete() }
        }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "duplexCapture" -> {
                    val headset = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
                        it.type in setOf(AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                            AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_HEADSET)
                    }
                    val supported = headset || AcousticEchoCanceler.isAvailable()
                    duplexCapture = supported
                    result.success(mapOf("supported" to supported, "speaker" to !headset))
                }
                "endDuplexCapture" -> { duplexCapture = false; result.success(null) }
                "play" -> play(call.argument<Int>("id"), call.argument<ByteArray>("bytes"), result)
                "playUrl" -> playUrl(call.argument<Int>("id"), call.argument<String>("url"), result)
                "stop" -> { stop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    private fun play(id: Int?, bytes: ByteArray?, result: MethodChannel.Result) {
        stop()
        if (disposed || id == null || bytes == null || bytes.isEmpty() || bytes.size > MAX_AUDIO_BYTES) {
            result.error("invalid_audio", "Unable to play speech", null)
            return
        }
        activeId = id
        pending = result
        val token = generation
        handler.postDelayed(prepareTimeout, 15000)
        // File writes must not stall text input, keyboard animation or waveform painting.
        files.execute {
            var file: File? = null
            try {
                cache.mkdir()
                val ready = File.createTempFile("speech-", ".mp3", cache)
                file = ready
                ready.outputStream().use { it.write(bytes) }
                handler.post {
                    if (disposed || generation != token || activeId != id) ready.delete()
                    else { audioFile = ready; prepare(ready.absolutePath, token) }
                }
            } catch (_: Exception) {
                file?.delete()
                handler.post { if (!disposed && generation == token) fail("playback_failed") }
            }
        }
    }

    private fun playUrl(id: Int?, url: String?, result: MethodChannel.Result) {
        stop()
        val uri = try { URI(url ?: "") } catch (_: Exception) { null }
        if (disposed || id == null || uri == null || uri.scheme != "http" ||
            uri.host != "127.0.0.1" || uri.port !in 1..65535 || uri.rawUserInfo != null ||
            uri.rawQuery != null || uri.rawFragment != null ||
            !Regex("^/speech/[a-f0-9]{64}\\.mp3$").matches(uri.rawPath ?: "")) {
            result.error("invalid_audio", "Invalid local audio source", null)
            return
        }
        activeId = id
        pending = result
        handler.postDelayed(prepareTimeout, 60000)
        prepare(url!!, generation)
    }

    private fun prepare(source: String, token: Long) {
        try {
            registerNoisyReceiver()
            val mp = MediaPlayer()
            player = mp
            mp.setAudioAttributes(attributes)
            channel.invokeMethod("diagnostic", mapOf("id" to activeId, "stage" to "preparing"))
            mp.setDataSource(source)
            mp.setOnPreparedListener {
                if (disposed || generation != token || player !== mp) return@setOnPreparedListener
                channel.invokeMethod("diagnostic", mapOf("id" to activeId, "stage" to "prepared"))
                try {
                    if (!requestFocus()) { fail("audio_focus_denied"); return@setOnPreparedListener }
                    mp.start()
                    handler.removeCallbacks(prepareTimeout)
                    val reply = pending
                    pending = null
                    reply?.success(null)
                    progress.run()
                } catch (_: Exception) { fail("playback_failed") }
            }
            mp.setOnCompletionListener {
                if (generation == token && player === mp) {
                    val duration = try { mp.duration } catch (_: Exception) { 0 }
                    emit("completed", duration, duration)
                    release()
                }
            }
            mp.setOnErrorListener { _, _, _ ->
                if (generation == token && player === mp) fail("invalid_audio")
                true
            }
            mp.prepareAsync()
        } catch (_: Exception) { fail("invalid_audio") }
    }

    @Suppress("DEPRECATION")
    private fun requestFocus(): Boolean {
        val token = generation
        val listener = AudioManager.OnAudioFocusChangeListener { change ->
            // A queued callback belonging to a replaced reply must not stop the new one.
            // Speech stops instead of ducking and never resumes when focus returns.
            if (generation == token && (change == AudioManager.AUDIOFOCUS_LOSS ||
                change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT ||
                change == AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)) stop()
        }
        focusListener = listener
        val granted = if (Build.VERSION.SDK_INT >= 26) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attributes)
                .setAcceptsDelayedFocusGain(false)
                .setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener(listener, handler).build()
            focusRequest = request
            audio.requestAudioFocus(request)
        } else {
            audio.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
        }
        focusHeld = granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return focusHeld
    }

    private fun registerNoisyReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else {
            @Suppress("DEPRECATION")
            app.registerReceiver(noisyReceiver, filter)
        }
        receiverRegistered = true
    }

    private fun emit(state: String, position: Int = 0, duration: Int = 0, code: String? = null) {
        val id = activeId ?: return
        if (!disposed) channel.invokeMethod("event", mapOf(
            "id" to id, "state" to state, "positionMs" to position.coerceAtLeast(0),
            "durationMs" to duration.coerceAtLeast(0), "code" to code))
    }

    private fun fail(code: String) {
        val reply = pending
        pending = null
        emit("error", code = code)
        release()
        reply?.error(code, "Unable to play speech", null)
    }

    fun stop() {
        emit("stopped")
        release()
    }

    @Suppress("DEPRECATION")
    private fun release() {
        generation++
        handler.removeCallbacks(prepareTimeout)
        handler.removeCallbacks(progress)
        val mp = player
        player = null
        try { mp?.setOnCompletionListener(null); mp?.setOnErrorListener(null); mp?.setOnPreparedListener(null); mp?.release() }
        catch (_: Exception) { /* Release all other resources even after a decoder failure. */ }
        audioFile?.delete()
        audioFile = null
        activeId = null
        if (receiverRegistered) {
            try { app.unregisterReceiver(noisyReceiver) } catch (_: Exception) {}
            receiverRegistered = false
        }
        try {
            if (Build.VERSION.SDK_INT >= 26) focusRequest?.let { audio.abandonAudioFocusRequest(it) }
            else if (focusHeld) focusListener?.let { audio.abandonAudioFocus(it) }
        } catch (_: Exception) {}
        focusRequest = null
        focusListener = null
        focusHeld = false
        // A cancelled prepare is complete but must never start playback later.
        pending?.success(null)
        pending = null
    }

    fun dispose() {
        if (disposed) return
        stop()
        disposed = true
        channel.setMethodCallHandler(null)
        files.shutdown()
        if (current === this) current = null
    }
}
