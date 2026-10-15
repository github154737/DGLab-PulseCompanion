package dev.aihaptics.haptics_lab

/** Coyote 3.0 wire format. Levels are device units, never measured current. */
object CoyoteProtocol {
    val silence = byteArrayOf(10, 10, 10, 10, 0, 0, 0, 0)
    fun frame(hex: String): ByteArray {
        require(hex.matches(Regex("[0-9a-fA-F]{16}"))) { "波形编码无效" }
        return ByteArray(8) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }.also {
            require(it.take(4).all { b -> (b.toInt() and 255) in 10..240 }) { "波形频率超出范围" }
            require(it.drop(4).all { b -> (b.toInt() and 255) in 0..100 }) { "波形幅度超出范围" }
        }
    }
    fun output(seq: Int, a: Int, b: Int, fa: ByteArray, fb: ByteArray): ByteArray {
        require(seq in 0..15 && a in 0..200 && b in 0..200)
        require(fa.size == 8 && fb.size == 8)
        // Validate even callers that did not use frame().
        for (f in listOf(fa, fb)) {
            require(f.take(4).all { (it.toInt() and 255) in 10..240 })
            require(f.drop(4).all { (it.toInt() and 255) in 0..100 })
        }
        // seq=0 keeps intensity; nonzero uses absolute levels on both channels.
        return byteArrayOf(0xB0.toByte(), ((seq shl 4) or if (seq == 0) 0 else 15).toByte(),
            a.toByte(), b.toByte()) + fa + fb
    }
    fun limits(a: Int, b: Int): ByteArray {
        require(a in 0..50 && b in 0..50) // This development build's local cap.
        // BF balance parameters intentionally fixed at 0; real waveform feel awaits hardware validation.
        return byteArrayOf(0xBF.toByte(), a.toByte(), b.toByte(), 0, 0, 0, 0)
    }
    fun feedback(bytes: ByteArray): IntArray? {
        if (bytes.size != 4 || (bytes[0].toInt() and 255) != 0xB1) return null
        val values = intArrayOf(bytes[1].toInt() and 255, bytes[2].toInt() and 255, bytes[3].toInt() and 255)
        return values.takeIf { it[0] in 0..15 && it[1] in 0..200 && it[2] in 0..200 }
    }
}

/** Single-threaded, monotonic-clock state machine, independent of Android for fault injection tests.
 * The adapter serializes GATT writes. A successful write is NOT a B1 acknowledgement.
 */
class CoyoteEngine(
    private val now: () -> Long,
    private val write: (ByteArray) -> Unit,
    private val changed: () -> Unit,
    private val broken: (String) -> Unit,
) {
    var state = "disconnected"; private set
    var message = "蓝牙未连接"; private set
    var actualA: Int? = null; private set
    var actualB: Int? = null; private set
    var generation = 0; private set
    private var seq = 0
    private var caps = intArrayOf(0, 0)
    private var queue = ArrayDeque<ByteArray>()
    private var writing: ByteArray? = null
    private var writeAt = 0L
    private var pending: IntArray? = null // seq, expected A/B
    private var ackAt = 0L
    private var resetAck = false
    private var target: Target? = null
    private var freshAt = 0L
    private var deadline = 0L
    private var lastTick = 0L
    private var stopAt = 0L
    private var lastSent = -1000L
    data class Target(val a: Int, val b: Int, val fa: ByteArray, val fb: ByteArray)
    private fun nextSeq(): Int { seq = seq % 15 + 1; return seq }
    fun connected() {
        check(state == "disconnected" || state == "fault")
        actualA = null; actualB = null; writing = null; pending = null
        lastTick = now()
        reset("initializing", "已连接，正在设置零上限并确认归零", 0, 0)
    }
    fun arm(a: Int, b: Int) {
        check(state == "ready") { "设备尚未确认归零" }
        require(a in 0..50 && b in 0..50)
        caps = intArrayOf(a, b)
        reset("arming", "正在设置本次上限并确认归零", a, b)
    }
    fun feed(a: Int, b: Int, fa: String, fb: String, remaining: Int) {
        check(state == "armed") { "蓝牙输出未授权" }
        require(a in 0..caps[0] && b in 0..caps[1] && remaining in 1..120000)
        val previous = target
        require(a - (previous?.a ?: 0) <= 5 && b - (previous?.b ?: 0) <= 5) { "单步增加超出 5" }
        target = Target(a, b, CoyoteProtocol.frame(fa), CoyoteProtocol.frame(fb))
        freshAt = now()
        // Renew only the short input lease. Freshness and clock-gap watchdogs
        // still stop independently; no fixed total-session timeout.
        deadline = now() + minOf(remaining, 1000)
    }
    fun stop(reason: String = "已请求停止") {
        if (state in listOf("disconnected", "fault", "stopping")) return
        reset("stopping", reason, 0, 0)
    }
    private fun reset(next: String, reason: String, a: Int, b: Int) {
        generation++
        state = next; message = reason; target = null; pending = null; resetAck = false
        queue.clear(); stopAt = now()
        queue.add(CoyoteProtocol.limits(a, b))
        queue.add(CoyoteProtocol.output(nextSeq(), 0, 0, CoyoteProtocol.silence, CoyoteProtocol.silence))
        changed(); pump()
    }
    private fun pump() {
        if (writing != null || queue.isEmpty() || state in listOf("fault", "disconnected")) return
        val bytes = queue.removeFirst()
        writing = bytes; writeAt = now()
        if ((bytes[0].toInt() and 255) == 0xB0 && (bytes[1].toInt() and 255) shr 4 != 0) {
            pending = intArrayOf((bytes[1].toInt() and 255) shr 4, bytes[2].toInt() and 255, bytes[3].toInt() and 255)
            ackAt = now()
        }
        try { write(bytes) } catch (_: Exception) { fault("蓝牙写入失败，停止未确认，请在设备上停止") }
    }
    fun written(success: Boolean) {
        if (writing == null || state in listOf("fault", "disconnected")) return
        writing = null
        if (!success) { fault("蓝牙写入失败，停止未确认，请在设备上停止"); return }
        pump(); finishReset()
    }
    fun notify(bytes: ByteArray) {
        val f = CoyoteProtocol.feedback(bytes) ?: return
        if (state in listOf("disconnected", "fault")) return
        val p = pending
        // Ignore unmatched/late nonzero sequence values, including retired stop generations.
        if (f[0] != 0 && (p == null || p[0] != f[0])) return
        actualA = f[1]; actualB = f[2]
        if (f[0] == 0) {
            if (state == "armed" || state == "arming" || (state == "ready" && (f[1] != 0 || f[2] != 0))) {
                stop("检测到设备旋钮变化，已撤销本次授权并请求归零")
            }
        } else if (p != null) {
            pending = null
            if (f[1] != p[1] || f[2] != p[2]) {
                if (state == "stopping" || state == "initializing") fault("设备未确认归零，请在设备上停止并重新连接")
                else stop("设备反馈与目标不一致，已请求停止")
            } else if (state in listOf("initializing", "arming", "stopping")) {
                resetAck = true; finishReset()
            }
        }
        changed()
    }
    private fun finishReset() {
        if (!resetAck || writing != null || queue.isNotEmpty() || pending != null) return
        if (state == "arming") {
            state = "armed"; freshAt = now(); lastTick = now(); deadline = now() + 1000
            message = "蓝牙输出已授权；等待连续目标数据，可随时停止"
        } else if (state in listOf("initializing", "stopping")) {
            state = "ready"; caps = intArrayOf(0, 0)
            message += "；设备已报告 A/B 归零（非实测电流）"
        }
        resetAck = false; changed()
    }
    fun tick() {
        val time = now()
        val gap = time - lastTick; lastTick = time
        if (state in listOf("fault", "disconnected")) return
        if (writing != null && time - writeAt >= 1000) {
            fault("蓝牙写入超时，停止未确认，请在设备上停止"); return
        }
        if (state in listOf("stopping", "initializing", "arming") && time - stopAt >= 2000) {
            if (state == "arming") stop("启用超时，已请求归零")
            else fault("归零反馈超时，请在设备上停止并重新连接")
            return
        }
        if (state == "armed" && (gap > 500 || time - freshAt > 600 || time >= deadline ||
                    pending != null && time - ackAt >= 800)) {
            stop("授权到期、控制时钟中断或设备反馈超时，已请求归零"); return
        }
        if (state != "armed" || writing != null || time - lastSent < 100) return
        val t = target ?: return
        // No accumulation: use the latest frame, never replay a delayed packet backlog.
        val change = pending == null && (actualA != t.a || actualB != t.b)
        queue.add(CoyoteProtocol.output(if (change) nextSeq() else 0, t.a, t.b, t.fa, t.fb))
        lastSent = time; pump()
    }
    fun disconnected(reason: String) {
        generation++
        state = "disconnected"; message = reason; target = null; pending = null
        writing = null; queue.clear(); actualA = null; actualB = null; changed()
    }
    private fun fault(reason: String) {
        state = "fault"; message = reason; target = null; pending = null; queue.clear(); writing = null
        actualA = null; actualB = null; changed(); broken(reason)
    }
}
