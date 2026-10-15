package dev.aihaptics.haptics_lab

import android.content.Context
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper

/** Detect OS-silenced recordings on Android 10+ without phone-state permission. */
class VoiceCaptureWatch(context: Context, private val interrupted: () -> Unit) {
    private val audio = context.getSystemService(AudioManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var watching = false
    private val routes = object : AudioDeviceCallback() {
        override fun onAudioDevicesRemoved(devices: Array<out AudioDeviceInfo>) {
            if (watching && devices.any { it.type in setOf(
                AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLE_HEADSET
            ) }) interrupted()
        }
    }
    private val callback = object : AudioManager.AudioRecordingCallback() {
        override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>?) {
            if (watching && Build.VERSION.SDK_INT >= 29 && configs?.any { it.isClientSilenced } == true) {
                interrupted()
            }
        }
    }
    fun setActive(active: Boolean) {
        if (watching == active) return
        try {
            if (active) {
                audio.registerAudioDeviceCallback(routes, handler)
                if (Build.VERSION.SDK_INT >= 29) audio.registerAudioRecordingCallback(callback, handler)
                watching = true
                if (Build.VERSION.SDK_INT >= 29 && audio.activeRecordingConfigurations.any { it.isClientSilenced }) interrupted()
            } else {
                watching = false
                audio.unregisterAudioDeviceCallback(routes)
                if (Build.VERSION.SDK_INT >= 29) audio.unregisterAudioRecordingCallback(callback)
            }
        } catch (_: Exception) {
            watching = false
            try { audio.unregisterAudioDeviceCallback(routes) } catch (_: Exception) {}
            if (Build.VERSION.SDK_INT >= 29) {
                try { audio.unregisterAudioRecordingCallback(callback) } catch (_: Exception) {}
            }
            if (active) interrupted()
        }
    }
    fun dispose() = setActive(false)
}
