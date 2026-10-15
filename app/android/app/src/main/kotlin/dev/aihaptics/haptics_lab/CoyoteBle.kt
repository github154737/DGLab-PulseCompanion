package dev.aihaptics.haptics_lab

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.content.pm.PackageManager
import android.os.*
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/** Process-local controller hosted by SessionService. All GATT and engine mutations run on one worker. */
@SuppressLint("MissingPermission")
class CoyoteBle private constructor(private val context: Context) {
    companion object {
        private var instance: CoyoteBle? = null
        fun get(context: Context): CoyoteBle = instance ?: CoyoteBle(context.applicationContext).also { instance = it }
        fun stopForService() { instance?.shutdown() }
        fun uuid(short: String): UUID = UUID.fromString("0000$short-0000-1000-8000-00805f9b34fb")
    }
    private val worker = HandlerThread("CoyoteBle").apply { start() }
    private val handler = Handler(worker.looper)
    private val main = Handler(Looper.getMainLooper())
    private val adapter get() = context.getSystemService(BluetoothManager::class.java)?.adapter
    private var channel: MethodChannel? = null
    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null
    private var scanCallback: ScanCallback? = null
    private var scanner: BluetoothLeScanner? = null
    private val devices = linkedMapOf<String, Map<String, Any>>()
    private var scanning = false
    private var connecting = false
    private var stage = ""
    private var stageAt = 0L
    private var battery: Int? = null
    private var deviceName = "郊狼 3.0"
    private var deviceId = ""
    private var notice = "仅支持郊狼 3.0；尚未进行实物联调"
    private var request: Pair<String, MethodChannel.Result>? = null
    private var closing = false
    private var cycle = 0
    private var lastEvent = ""
    private val engine = CoyoteEngine(SystemClock::elapsedRealtime, ::write, ::publish, ::broken)
    private val ticker = object : Runnable {
        override fun run() {
            engine.tick()
            if (connecting && SystemClock.elapsedRealtime() - stageAt > 12000) broken("连接或服务发现超时，请关闭 DG-LAB 的蓝牙占用后重试")
            if (stage == "battery" && SystemClock.elapsedRealtime() - stageAt > 1500) broken("电量读取超时，请重新连接")
            if (gatt != null) handler.postDelayed(this, 25)
        }
    }
    fun attach(value: MethodChannel?) { channel = value; handler.post { publish(force = true) } }
    private fun snapshot(): Map<String, Any?> = mapOf(
        "state" to if (connecting) "connecting" else engine.state,
        "status" to (if (connecting) notice else if (engine.state == "disconnected") notice else engine.message),
        "scanning" to scanning, "devices" to devices.values.toList(), "battery" to battery,
        "a" to engine.actualA, "b" to engine.actualB, "name" to deviceName, "id" to deviceId,
        "generation" to engine.generation,
    )
    private fun publish(force: Boolean = false) {
        val snapshot = snapshot()
        val signature = snapshot.toString()
        if (force || signature != lastEvent) {
            lastEvent = signature
            main.post { channel?.invokeMethod("event", snapshot) }
        }
        if (closing && engine.state == "ready") {
            closeGatt("已断开；断开前设备已报告归零"); return
        }
        val p = request ?: return
        if (p.first == "arm" && engine.state == "armed" || p.first == "stop" && engine.state == "ready") {
            request = null; main.post { p.second.success(snapshot) }
        } else if (engine.state in listOf("fault", "disconnected") || p.first == "arm" && engine.state == "stopping") {
            request = null; main.post { p.second.error("ble_state", engine.message, null) }
        }
    }
    fun call(method: String, args: Map<*, *>?, result: MethodChannel.Result) {
        handler.post {
            try {
                when (method) {
                    "state" -> main.post { result.success(snapshot()) }
                    "scan" -> { scan(); main.post { result.success(null) } }
                    "stopScan" -> { stopScan(); main.post { result.success(null) } }
                    "connect" -> { connect(args?.get("id") as String); val value = snapshot(); main.post { result.success(value) } }
                    "arm" -> {
                        check(SessionService.current != null) { "后台服务未启动" }
                        check(request == null && !closing) { "设备正在执行上一项操作" }
                        engine.arm((args?.get("a") as Number).toInt(), (args["b"] as Number).toInt())
                        request = "arm" to result; publish()
                    }
                    "feed" -> {
                        if ((args?.get("generation") as? Number)?.toInt() != engine.generation) {
                            main.post { result.success(null) }; return@post
                        }
                        try {
                            engine.feed((args["a"] as Number).toInt(), (args["b"] as Number).toInt(),
                                args["fa"] as String, args["fb"] as String, (args["remaining"] as Number).toInt())
                            main.post { result.success(null) }
                        } catch (e: Exception) {
                            engine.stop("输出校验未通过，已请求归零")
                            throw e
                        }
                    }
                    "stop" -> {
                        cancelRequest("启用已取消")
                        if (engine.state == "ready") main.post { result.success(snapshot()) }
                        else if (engine.state in listOf("disconnected", "fault")) main.post { result.error("ble_disconnected", "设备已断开，不能确认停止", null) }
                        else { request = "stop" to result; engine.stop(); publish() }
                    }
                    "disconnect" -> { disconnect(); main.post { result.success(null) } }
                    else -> main.post { result.notImplemented() }
                }
            } catch (e: Exception) {
                if (method == "connect") broken("连接失败，请检查蓝牙及设备占用")
                main.post { result.error("ble_error", e.message ?: "蓝牙操作失败", null) }
            }
        }
    }
    private fun scan() {
        check(gatt == null && !connecting) { "请先断开当前设备" }
        check(adapter != null) { "手机不支持蓝牙" }
        check(adapter?.isEnabled == true) { "请先打开手机蓝牙" }
        if (Build.VERSION.SDK_INT <= 30) {
            val location = context.getSystemService(android.location.LocationManager::class.java)
            check(location.isProviderEnabled(android.location.LocationManager.GPS_PROVIDER) ||
                location.isProviderEnabled(android.location.LocationManager.NETWORK_PROVIDER)) { "此 Android 版本扫描蓝牙需要打开系统位置开关" }
        }
        stopScan(); devices.clear(); scanning = true; notice = "正在查找郊狼 3.0（10 秒）"
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                handler.post {
                    if (scanCallback !== this || !scanning) return@post
                    try {
                        val name = result.scanRecord?.deviceName ?: result.device.name
                        if (name != "47L121000") return@post
                        devices[result.device.address] = mapOf("id" to result.device.address, "name" to "郊狼 3.0", "rssi" to result.rssi)
                        publish()
                    } catch (_: SecurityException) {
                        stopScan(); notice = "蓝牙权限已被撤销，请重新授权"; publish()
                    }
                }
            }
            override fun onScanFailed(errorCode: Int) { handler.post {
                if (scanCallback !== this) return@post
                stopScan(); notice = "扫描失败（$errorCode），请稍后重试"; publish()
            } }
        }
        scanCallback = callback
        scanner = adapter!!.bluetoothLeScanner ?: error("蓝牙扫描不可用")
        try {
            scanner!!.startScan(listOf(ScanFilter.Builder().setDeviceName("47L121000").build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), callback)
        } catch (e: Exception) { stopScan(); throw e }
        handler.postDelayed({ if (scanCallback === callback) {
            stopScan(); notice = if (devices.isEmpty()) "未找到设备。请打开郊狼 3.0，并断开其他 App 对它的连接。" else "扫描完成，请选择设备"
            publish()
        } }, 10000)
        publish()
    }
    private fun stopScan() {
        try { scanCallback?.let { scanner?.stopScan(it) } } catch (_: Exception) { }
        scanCallback = null; scanner = null; scanning = false; publish()
    }
    private fun connect(id: String) {
        check(SessionService.current != null) { "后台连接服务未启动" }
        check(gatt == null && !connecting && !closing) { "请先断开当前设备" }
        check(devices.containsKey(id)) { "请先扫描并选择设备" }
        check(adapter?.isEnabled == true) { "请先打开手机蓝牙" }
        stopScan(); cycle++; battery = null; deviceId = id
        connecting = true; stage = "connect"; stageAt = SystemClock.elapsedRealtime(); notice = "正在连接郊狼 3.0"
        publish()
        gatt = adapter!!.getRemoteDevice(id).connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            ?: error("无法建立蓝牙连接")
        handler.removeCallbacks(ticker); handler.post(ticker)
    }
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) { handler.post {
            if (g !== gatt) return@post
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                broken("蓝牙已断开（$status），输出状态未知；请检查设备，重新连接不会恢复输出")
            } else if (newState == BluetoothProfile.STATE_CONNECTED) {
                stage = "services"; stageAt = SystemClock.elapsedRealtime()
                try { if (!g.discoverServices()) broken("无法读取蓝牙服务") }
                catch (_: SecurityException) { broken("蓝牙权限已被撤销，请检查设备并重新授权") }
            }
        } }
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) { handler.post {
            if (g !== gatt || stage != "services") return@post
            try {
                check(status == BluetoothGatt.GATT_SUCCESS) { "服务发现失败" }
                val service = g.getService(uuid("180c")) ?: error("设备不提供郊狼 3.0 服务")
                val w = service.getCharacteristic(uuid("150a")) ?: error("缺少写入特征")
                check(w.properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0)
                writeChar = w
                val n = service.getCharacteristic(uuid("150b")) ?: error("缺少强度反馈特征")
                check(n.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0)
                check(g.setCharacteristicNotification(n, true))
                val d = n.getDescriptor(uuid("2902")) ?: error("设备不支持反馈订阅")
                stage = "notify"; stageAt = SystemClock.elapsedRealtime()
                @Suppress("DEPRECATION")
                val ok = if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(d, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
                    else { d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; g.writeDescriptor(d) }
                check(ok) { "反馈订阅失败" }
            } catch (e: Exception) { broken(e.message ?: "设备协议不兼容") }
        } }
        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) { handler.post {
            if (g !== gatt || stage != "notify") return@post
            if (status != BluetoothGatt.GATT_SUCCESS) { broken("无法订阅设备反馈"); return@post }
            val b = g.getService(uuid("180a"))?.getCharacteristic(uuid("1500"))
            stage = "battery"; stageAt = SystemClock.elapsedRealtime()
            try { if (b == null || !g.readCharacteristic(b)) beginEngine() }
            catch (_: SecurityException) { broken("蓝牙权限已被撤销，请重新授权") }
        } }
        @Deprecated("Legacy Android callback")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION") val data = c.value?.clone() ?: byteArrayOf()
            readBattery(g, c.uuid, data, status)
        }
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) = readBattery(g, c.uuid, value.clone(), status)
        @Deprecated("Legacy Android callback")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION") val data = c.value?.clone() ?: byteArrayOf()
            notify(g, c.uuid, data)
        }
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) = notify(g, c.uuid, value.clone())
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) { handler.post {
            if (g === gatt && c.uuid == uuid("150a")) engine.written(status == BluetoothGatt.GATT_SUCCESS)
        } }
    }
    private fun readBattery(g: BluetoothGatt, id: UUID, value: ByteArray, status: Int) { handler.post {
        if (g !== gatt || id != uuid("1500")) return@post
        if (status == BluetoothGatt.GATT_SUCCESS && value.size == 1 && (value[0].toInt() and 255) <= 100) battery = value[0].toInt() and 255
        if (stage == "battery") beginEngine()
        publish()
    } }
    private fun notify(g: BluetoothGatt, id: UUID, value: ByteArray) { handler.post {
        if (g !== gatt || id != uuid("150b")) return@post
        engine.notify(value)
    } }
    private fun beginEngine() {
        stage = "ready"; connecting = false
        engine.connected()
    }
    private fun write(bytes: ByteArray) {
        val g = gatt ?: error("蓝牙已断开")
        val c = writeChar ?: error("写入特征不可用")
        val type = if (c.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        @Suppress("DEPRECATION")
        val ok = if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(c, bytes, type) == BluetoothStatusCodes.SUCCESS
            else { c.writeType = type; c.value = bytes; g.writeCharacteristic(c) }
        check(ok) { "蓝牙写入未接受" }
    }
    private fun cancelRequest(message: String) {
        request?.let { val r = it.second; main.post { r.error("ble_cancelled", message, null) } }
        request = null
    }
    private fun broken(reason: String) { closeGatt(reason) }
    private fun closeGatt(reason: String) {
        handler.removeCallbacks(ticker)
        cycle++; connecting = false; closing = false; stage = ""
        val old = gatt; gatt = null; writeChar = null; notice = reason; battery = null
        cancelRequest(reason)
        try { old?.disconnect() } catch (_: Exception) { }
        try { old?.close() } catch (_: Exception) { }
        engine.disconnected(reason)
        publish()
    }
    private fun disconnect() {
        stopScan(); cancelRequest("连接已取消")
        if (gatt == null || connecting || engine.state in listOf("fault", "disconnected")) {
            closeGatt("已断开；未确认设备输出状态"); return
        }
        closing = true; engine.stop("正在断开，先请求归零")
        val ticket = cycle
        handler.postDelayed({ if (closing && ticket == cycle) closeGatt("停止未确认，已断开蓝牙；请在设备上停止") }, 2200)
    }
    fun shutdown() { handler.post { disconnect() } }
}

/** Runtime permission boundary is Activity-owned; never requests advertising permission. */
class CoyoteBlePermissions(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null
    fun request(result: MethodChannel.Result) {
        if (pending != null) { result.error("ble_permission", "请先完成系统权限选择", null); return }
        val permissions = if (Build.VERSION.SDK_INT >= 31) arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        val missing = permissions.filter { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) result.success(true)
        else { pending = result; activity.requestPermissions(missing.toTypedArray(), 4803) }
    }
    fun result(code: Int, values: IntArray) {
        if (code != 4803) return
        pending?.success(values.isNotEmpty() && values.all { it == PackageManager.PERMISSION_GRANTED }); pending = null
    }
    fun dispose() { pending?.error("ble_permission", "页面已关闭", null); pending = null }
}
