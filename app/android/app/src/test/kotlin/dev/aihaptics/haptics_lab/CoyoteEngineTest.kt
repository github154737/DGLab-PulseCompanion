package dev.aihaptics.haptics_lab

import org.junit.Assert.*
import org.junit.Test

class CoyoteEngineTest {
    private class Rig {
        var time = 1000L
        val sent = mutableListOf<ByteArray>()
        var faults = 0
        val e = CoyoteEngine({ time }, { sent.add(it.clone()) }, {}, { faults++ })
        fun ack(a: Int = 0, b: Int = 0, seq: Int = (sent.last()[1].toInt() and 255) shr 4) =
            e.notify(byteArrayOf(0xB1.toByte(), seq.toByte(), a.toByte(), b.toByte()))
        fun resetDone() { e.written(true); ack(); e.written(true) }
        fun ready() { e.connected(); resetDone(); assertEquals("ready", e.state) }
        fun arm() { ready(); e.arm(20, 20); resetDone(); assertEquals("armed", e.state) }
        fun feed(a: Int = 2, b: Int = 2, remaining: Int = 120000) = e.feed(a, b, "1414141432323232", "1414141432323232", remaining)
        fun tick(ms: Long = 100) { time += ms; e.tick() }
    }
    @Test fun officialDualChannelVector() {
        val frame = CoyoteProtocol.frame("0A0A0A0A000A141E")
        val actual = CoyoteProtocol.output(0, 0, 0, frame, CoyoteProtocol.silence)
        assertEquals("b00000000a0a0a0a000a141e0a0a0a0a00000000", actual.joinToString("") { "%02x".format(it) })
    }
    @Test fun absoluteIntensityAndLimits() {
        val p = CoyoteProtocol.output(15, 20, 15, CoyoteProtocol.silence, CoyoteProtocol.silence)
        assertEquals(20, p.size); assertEquals(255, p[1].toInt() and 255)
        assertArrayEquals(byteArrayOf(0xBF.toByte(), 20, 15, 0, 0, 0, 0), CoyoteProtocol.limits(20, 15))
    }
    @Test fun invalidWaveAndCapsRejected() {
        for (value in listOf("00", "000A0A0A00000000", "0A0A0A0A00650000", "GGGGGGGGGGGGGGGG")) {
            try { CoyoteProtocol.frame(value); fail("invalid frame accepted") } catch (_: IllegalArgumentException) { }
        }
        try { CoyoteProtocol.limits(51, 0); fail() } catch (_: IllegalArgumentException) { }
    }
    @Test fun malformedFeedbackRejected() {
        assertNull(CoyoteProtocol.feedback(byteArrayOf(0xB1.toByte(), 16, 0, 0)))
        assertNull(CoyoteProtocol.feedback(byteArrayOf(0xB1.toByte(), 0, 201.toByte(), 0)))
        assertNull(CoyoteProtocol.feedback(byteArrayOf(0xB1.toByte(), 0, 0)))
    }
    @Test fun connectWritesZeroLimitsBeforeResetAndWaitsForB1() {
        val r = Rig(); r.e.connected()
        assertEquals(0xBF, r.sent.first()[0].toInt() and 255)
        assertEquals(0, r.sent.first()[1].toInt())
        r.e.written(true); r.e.written(true)
        assertEquals("initializing", r.e.state)
        r.ack(); assertEquals("ready", r.e.state)
    }
    @Test fun notificationBeforeWriteCompletionIsSupported() {
        val r = Rig(); r.e.connected(); r.e.written(true); r.ack()
        assertEquals("initializing", r.e.state)
        r.e.written(true); assertEquals("ready", r.e.state)
    }
    @Test fun matchingSequenceRequired() {
        val r = Rig(); r.e.connected(); r.e.written(true); r.e.written(true)
        r.ack(seq = 14); assertEquals("initializing", r.e.state)
        r.ack(); assertEquals("ready", r.e.state)
    }
    @Test fun strengthChangesWaitForPreviousFeedback() {
        val r = Rig(); r.arm(); r.feed(); r.tick(); val first = r.sent.last()
        r.e.written(true); r.feed(4, 4); r.tick()
        assertEquals(0, r.sent.last()[1].toInt()) // Only waveform until B1 arrives.
        r.e.written(true); r.ack(2, 2, (first[1].toInt() and 255) shr 4)
        r.tick(); assertEquals(4, r.sent.last()[2].toInt())
        assertTrue(r.sent.last()[1].toInt() != 0)
    }
    @Test fun noBacklogWhileGattBusy() {
        val r = Rig(); r.arm(); r.feed(); r.tick(); val count = r.sent.size
        repeat(4) { r.feed(); r.tick() }
        assertEquals(count, r.sent.size)
    }
    @Test fun noPositivePacketAfterStopIncludingDelayedWriteCallback() {
        val r = Rig(); r.arm(); r.feed(); r.tick(); val index = r.sent.size
        val oldSeq = (r.sent.last()[1].toInt() and 255) shr 4
        r.e.stop(); r.ack(2, 2, oldSeq); r.e.written(true)
        r.resetDone(); assertEquals("ready", r.e.state)
        assertTrue(r.sent.drop(index).all { it[1].toInt() == 0 || (it[2].toInt() == 0 && it[3].toInt() == 0) })
        r.tick(); assertEquals(index + 2, r.sent.size)
    }
    @Test fun stopCancelsArmingAndLateAckCannotArm() {
        val r = Rig(); r.ready(); r.e.arm(20, 20); r.e.written(true)
        val seq = (r.sent.last()[1].toInt() and 255) shr 4
        r.e.stop(); r.ack(seq = seq); r.e.written(true); r.resetDone()
        assertEquals("ready", r.e.state)
    }
    @Test fun knobRevokesAuthorization() {
        val r = Rig(); r.arm(); r.e.notify(byteArrayOf(0xB1.toByte(), 0, 3, 1))
        assertEquals("stopping", r.e.state); assertEquals(3, r.e.actualA)
        r.resetDone(); assertEquals("ready", r.e.state)
    }
    @Test fun mismatchedTargetStops() {
        val r = Rig(); r.arm(); r.feed(); r.tick(); r.e.written(true); r.ack(1, 2)
        assertEquals("stopping", r.e.state)
    }
    @Test fun inputStallStopsWithoutDart() {
        val r = Rig(); r.arm(); repeat(7) { r.tick() }
        assertEquals("stopping", r.e.state)
    }
    @Test fun workerClockGapStops() {
        val r = Rig(); r.arm(); r.tick(501)
        assertEquals("stopping", r.e.state)
    }
    @Test fun ackTimeoutStopsDespiteFreshTargets() {
        val r = Rig(); r.arm(); r.feed(); r.tick(); r.e.written(true)
        repeat(8) { r.feed(); r.tick(); r.e.written(true) }
        assertEquals("stopping", r.e.state)
    }
    @Test fun gattWriteFailureNeverClaimsStopped() {
        val r = Rig(); r.arm(); r.feed(); r.tick(); r.e.written(false)
        assertEquals("fault", r.e.state); assertEquals(1, r.faults); assertNull(r.e.actualA)
    }
    @Test fun gattWriteTimeoutHasBoundedFailure() {
        val r = Rig(); r.e.connected(); repeat(10) { r.tick() }
        assertEquals("fault", r.e.state)
    }
    @Test fun missingZeroConfirmationFailsClosed() {
        val r = Rig(); r.e.connected(); r.e.written(true); r.e.written(true)
        repeat(20) { r.tick() }; assertEquals("fault", r.e.state)
    }
    @Test fun wrongZeroFeedbackFailsClosed() {
        val r = Rig(); r.e.connected(); r.e.written(true); r.ack(1, 0)
        assertEquals("fault", r.e.state)
    }
    @Test fun shortLeaseExpiresWithoutRenewal() {
        val r = Rig(); r.arm(); r.feed(0, 0, 250)
        repeat(3) { r.tick(); r.e.written(true) }
        assertEquals("stopping", r.e.state)
    }
    @Test fun continuousInputRunsPast120SecondsButStopStillRevokes() {
        val r = Rig(); r.arm()
        repeat(2400) {
            r.feed(0, 0, 1000); r.tick(); r.e.written(true)
            assertEquals("armed", r.e.state)
        }
        r.e.stop(); r.resetDone(); assertEquals("ready", r.e.state)
        try { r.feed(); fail() } catch (_: IllegalStateException) { }
    }
    @Test fun reconnectClearsAuthorizationAndRewritesLimits() {
        val r = Rig(); r.arm(); val old = r.e.generation
        r.e.disconnected("lost"); r.e.connected(); assertTrue(r.e.generation > old)
        assertEquals(0xBF, r.sent.last()[0].toInt() and 255); assertEquals(0, r.sent.last()[1].toInt())
        r.resetDone(); assertEquals("ready", r.e.state)
        try { r.feed(); fail() } catch (_: IllegalStateException) { }
    }
    @Test fun capAndSingleStepAreEnforcedLocally() {
        val r = Rig(); r.arm()
        for (level in listOf(-1, 6, 21)) {
            try { r.feed(level, 0); fail() } catch (_: IllegalArgumentException) { }
        }
    }
    @Test fun sequenceWrapAndDuplicateFeedback() {
        val r = Rig(); r.arm()
        repeat(40) { i ->
            val level = if (i % 2 == 0) 2 else 4
            r.feed(level, level); r.tick(); val seq = (r.sent.last()[1].toInt() and 255) shr 4
            assertTrue(seq in 1..15); r.e.written(true); r.ack(level, level, seq); r.ack(level, level, seq)
            assertEquals("armed", r.e.state)
        }
    }
}
