package dev.aihaptics.haptics_lab

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.*

/** Visible, bounded user-started session. Never automatically restarts output. */
class SessionService : Service() {
    companion object {
        var onStop: (() -> Unit)? = null
        var onPauseVoice: (() -> Unit)? = null
        var onEndVoice: (() -> Unit)? = null
        const val PAUSE_VOICE = "dev.aihaptics.PAUSE_VOICE"
        const val END_VOICE = "dev.aihaptics.END_VOICE"
        var onReady: ((Boolean) -> Unit)? = null
        const val STOP = "dev.aihaptics.STOP_SESSION"
        var current: SessionService? = null
    }
    private var wakeLock: PowerManager.WakeLock? = null
    private var lastNotification: Notification? = null
    fun refreshNotification() {
        lastNotification?.let { getSystemService(NotificationManager::class.java).notify(771, it) }
    }
    private val handler = Handler(Looper.getMainLooper())
    private val timeout = Runnable { onStop?.invoke(); stopSelf() }
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        current = this
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel("active_session", "正在进行的互动", NotificationManager.IMPORTANCE_LOW))
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) { onStop?.invoke(); stopSelf(); return START_NOT_STICKY }
        if (intent?.action == PAUSE_VOICE) { onPauseVoice?.invoke(); return START_NOT_STICKY }
        if (intent?.action == END_VOICE) { onEndVoice?.invoke(); return START_NOT_STICKY }
        if (intent == null) { stopSelf(); return START_NOT_STICKY }
        try {
            val continuous = intent.getBooleanExtra("continuous", false)
            val mic = intent.getBooleanExtra("microphone", false)
            val device = intent.getBooleanExtra("device", false)
            val mediaPlayback = intent.getBooleanExtra("mediaPlayback", false)
            val simulation = intent.getBooleanExtra("simulation", false) && !device && !mic
            val open = PendingIntent.getActivity(this, 1, Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val stop = PendingIntent.getService(this, 2, Intent(this, SessionService::class.java).setAction(STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, "active_session") else Notification.Builder(this)
            if (continuous) {
                val pauseVoice = PendingIntent.getService(this, 3, Intent(this, SessionService::class.java).setAction(PAUSE_VOICE),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val endVoice = PendingIntent.getService(this, 4, Intent(this, SessionService::class.java).setAction(END_VOICE),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                builder.addAction(Notification.Action.Builder(null, "静音对话", pauseVoice).build())
                    .addAction(Notification.Action.Builder(null, "结束对话", endVoice).build())
            }
            val notification = builder.setSmallIcon(android.R.drawable.ic_btn_speak_now)
                .setContentTitle("AI Haptics · 互动进行中")
                .setContentText(if (continuous) "连续对话已开启 · 麦克风按轮次采集"
                    else if (mic) "麦克风正在采集 · 点击返回，可随时停止"
                    else if (mediaPlayback) "语音回复处理中 · 点击返回，可随时停止"
                    else "任务在后台继续 · 点击返回")
                .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
                .setVisibility(Notification.VISIBILITY_PRIVATE)
                .addAction(Notification.Action.Builder(null, "停止全部", stop).build()).build()
            lastNotification = notification
            if (Build.VERSION.SDK_INT >= 29) {
                var types = if (device) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                    else if (mediaPlayback || mic) 0 else ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                if (mediaPlayback) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
                if (mic && Build.VERSION.SDK_INT >= 30) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                startForeground(771, notification, types)
            } else { startForeground(771, notification) }
            // Continuous voice and pure simulation may last until user stop.
            // Device sessions keep their existing bound; Dart device authorization is separate.
            // All locks are still released by notification stop / task removal / destruction.
            if (wakeLock?.isHeld == true) wakeLock?.release()
            wakeLock = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "AIHaptics:ActiveSession").apply {
                if ((simulation || continuous) && !device) acquire() else acquire(10 * 60 * 1000L)
            }
            handler.removeCallbacks(timeout)
            if (!(simulation || continuous) || device) handler.postDelayed(timeout, 10 * 60 * 1000L)
            onReady?.invoke(true); onReady = null
        } catch (_: Exception) {
            onReady?.invoke(false); onReady = null
            onStop?.invoke(); stopSelf()
        }
        return START_NOT_STICKY
    }
    override fun onTaskRemoved(rootIntent: Intent?) { onStop?.invoke(); stopSelf(); super.onTaskRemoved(rootIntent) }
    override fun onTimeout(startId: Int, fgsType: Int) { onStop?.invoke(); stopSelf() }
    override fun onDestroy() {
        // Native stop does not depend on Dart receiving the notification callback.
        CoyoteBle.stopForService()
        SpeechPlayback.stopForService()
        handler.removeCallbacks(timeout)
        if (wakeLock?.isHeld == true) wakeLock?.release()
        wakeLock = null
        current = null
        lastNotification = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
