use haptics_core::Engine;
use serde_json::{json, Value};

fn send(e: &mut Engine, time: u64, req: Value) -> Value {
    e.request(time, &req.to_string())
}
fn setup(device: &str, limit: f64) -> Engine {
    let mut e = Engine::new();
    assert_eq!(
        send(&mut e, 0, json!({"op":"connect","device_id":device}))["ok"],
        true
    );
    assert_eq!(
        send(
            &mut e,
            0,
            json!({"op":"authorize","limit":limit,"lease_ms":30000})
        )["ok"],
        true
    );
    e
}
fn ticket(e: &mut Engine, now: u64) -> u64 {
    send(e, now, json!({"op":"begin_ai"}))["result"]["ticket"]
        .as_u64()
        .unwrap()
}
fn complete(e: &mut Engine, now: u64, t: u64, response: Value) -> Value {
    send(
        e,
        now,
        json!({"op":"complete_ai","ticket":t,"response":response.to_string()}),
    )
}
fn intent() -> Value {
    json!({"action":"play_preset","device_alias":"sim_single","preset_id":"soft_pulse"})
}
fn snap(e: &mut Engine, now: u64) -> Value {
    send(e, now, json!({"op":"snapshot"}))["state"].clone()
}

#[test]
fn no_output_without_authorization() {
    let mut e = Engine::new();
    for req in [
        json!({"op":"play","preset_id":"soft_pulse"}),
        json!({"op":"begin_ai"}),
    ] {
        assert_eq!(send(&mut e, 0, req)["ok"], false);
    }
    assert_eq!(snap(&mut e, 100)["output"], json!([0.0, 0.0]));
}
#[test]
fn missing_devices_and_capabilities_are_not_substituted() {
    let mut e = Engine::new();
    assert_eq!(
        send(&mut e, 0, json!({"op":"connect","device_id":"real_device"}))["error"],
        "unknown_device"
    );
    let mut e = setup("sim_single", 0.3);
    assert_eq!(
        send(&mut e, 0, json!({"op":"play","preset_id":"dual_alternate"}))["error"],
        "capability_mismatch"
    );
    assert_eq!(
        send(&mut e, 0, json!({"op":"play","preset_id":"arbitrary"}))["error"],
        "unknown_preset"
    );
}
#[test]
fn stop_invalidates_late_model_responses_even_after_reauthorize() {
    let mut e = setup("sim_single", 0.3);
    let t = ticket(&mut e, 0);
    send(&mut e, 20, json!({"op":"stop"}));
    send(
        &mut e,
        30,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    assert_eq!(complete(&mut e, 40, t, intent())["ok"], false);
    assert_eq!(snap(&mut e, 50)["output"], json!([0.0, 0.0]));
}
#[test]
fn response_is_single_use() {
    let mut e = setup("sim_single", 0.3);
    let t = ticket(&mut e, 0);
    assert_eq!(complete(&mut e, 10, t, intent())["ok"], true);
    assert_eq!(
        complete(&mut e, 2500, t, intent())["error"],
        "stale_or_duplicate_ticket"
    );
}
#[test]
fn reconnect_discards_old_requests() {
    let mut e = setup("sim_single", 0.3);
    let t = ticket(&mut e, 0);
    send(&mut e, 10, json!({"op":"disconnect"}));
    send(&mut e, 20, json!({"op":"connect","device_id":"sim_single"}));
    send(
        &mut e,
        30,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    assert_eq!(complete(&mut e, 40, t, intent())["ok"], false);
}
#[test]
fn model_cannot_modify_policy_or_use_extra_fields() {
    for bad in [
        json!({"action":"authorize","limit":1.0}),
        json!({"action":"stop","unlock":true}),
        json!({"action":"play_preset","device_alias":"sim_single","preset_id":"soft_pulse","intensity":1.0}),
    ] {
        let mut e = setup("sim_single", 0.3);
        let t = ticket(&mut e, 0);
        assert_eq!(complete(&mut e, 10, t, bad)["error"], "invalid_intent");
        assert_eq!(snap(&mut e, 20)["limit"], 0.3);
    }
}
#[test]
fn malformed_and_partial_model_output_never_executes() {
    for bad in [
        "{",
        "Here is the action: {}",
        "<play>soft_pulse</play>",
        "{\"action\":\"stop\",\"action\":\"noop\"}",
    ] {
        let mut e = setup("sim_single", 0.3);
        let t = ticket(&mut e, 0);
        assert_eq!(
            send(
                &mut e,
                10,
                json!({"op":"complete_ai","ticket":t,"response":bad})
            )["ok"],
            false
        );
        assert_eq!(snap(&mut e, 20)["output"], json!([0.0, 0.0]));
    }
}
#[test]
fn mismatch_device_rejected() {
    let mut e = setup("sim_single", 0.3);
    let t = ticket(&mut e, 0);
    assert_eq!(
        complete(
            &mut e,
            10,
            t,
            json!({"action":"play_preset","device_alias":"sim_dual","preset_id":"soft_pulse"})
        )["error"],
        "device_mismatch"
    );
}
#[test]
fn cancelled_or_timed_out_request_cannot_play() {
    let mut e = setup("sim_single", 0.3);
    let t = ticket(&mut e, 0);
    send(&mut e, 1, json!({"op":"cancel_ai","ticket":t}));
    assert_eq!(complete(&mut e, 2, t, intent())["ok"], false);
    let t = ticket(&mut e, 3);
    assert_eq!(complete(&mut e, 20003, t, intent())["ok"], false);
}
#[test]
fn deadline_wins_at_exact_boundary() {
    let mut e = setup("sim_single", 0.3);
    let t = ticket(&mut e, 29000);
    assert_eq!(complete(&mut e, 30000, t, intent())["ok"], false);
    assert_eq!(snap(&mut e, 30000)["phase"], "stopped");
}
#[test]
fn preset_cannot_extend_beyond_lease() {
    let mut e = setup("sim_single", 0.3);
    assert_eq!(
        send(&mut e, 28000, json!({"op":"play","preset_id":"soft_pulse"}))["error"],
        "lease_too_short"
    );
}
#[test]
fn stop_prevents_all_later_ticks_from_restarting() {
    let mut e = setup("sim_single", 0.3);
    send(&mut e, 0, json!({"op":"play","preset_id":"soft_pulse"}));
    send(&mut e, 100, json!({"op":"stop"}));
    for now in (100..40000).step_by(17) {
        assert_eq!(snap(&mut e, now)["output"], json!([0.0, 0.0]));
    }
}
#[test]
fn disconnect_can_retain_output_and_unknown_is_locked() {
    let mut e = setup("sim_fault", 0.3);
    send(
        &mut e,
        0,
        json!({"op":"set_fault","fault":"hold_on_disconnect"}),
    );
    send(&mut e, 0, json!({"op":"play","preset_id":"soft_pulse"}));
    let before = snap(&mut e, 10)["output"].clone();
    assert!(before[0].as_f64().unwrap() > 0.0);
    let after = send(&mut e, 20, json!({"op":"disconnect"}))["state"].clone();
    assert_eq!(after["output"], before);
    assert_eq!(after["phase"], "unknown");
    assert_eq!(
        send(&mut e, 30, json!({"op":"connect","device_id":"sim_single"}))["ok"],
        false
    );
    assert_eq!(snap(&mut e, 40000)["output"], before);
}
#[test]
fn unacknowledged_stop_does_not_claim_zero() {
    let mut e = setup("sim_fault", 0.3);
    send(
        &mut e,
        0,
        json!({"op":"set_fault","fault":"stop_unconfirmed"}),
    );
    send(&mut e, 0, json!({"op":"play","preset_id":"soft_pulse"}));
    let state = send(&mut e, 10, json!({"op":"stop"}))["state"].clone();
    assert_eq!(state["output_evidence"], "unknown");
    assert_eq!(
        send(
            &mut e,
            20,
            json!({"op":"authorize","limit":0.3,"lease_ms":30000})
        )["ok"],
        false
    );
}
#[test]
fn cannot_renew_authorization_during_playback() {
    let mut e = setup("sim_single", 0.3);
    send(&mut e, 0, json!({"op":"play","preset_id":"soft_pulse"}));
    assert_eq!(
        send(
            &mut e,
            10,
            json!({"op":"authorize","limit":1.0,"lease_ms":30000})
        )["ok"],
        false
    );
}
#[test]
fn natural_preset_completion_keeps_unknown_when_stop_cannot_be_confirmed() {
    let mut e = setup("sim_fault", 0.3);
    send(
        &mut e,
        0,
        json!({"op":"set_fault","fault":"stop_unconfirmed"}),
    );
    send(&mut e, 0, json!({"op":"play","preset_id":"soft_pulse"}));
    let state = snap(&mut e, 2500);
    assert_eq!(state["phase"], "unknown");
    assert!(state["output"][0].as_f64().unwrap() > 0.0);
}
#[test]
fn simulator_reset_does_not_reuse_old_ticket_ids() {
    let mut e = setup("sim_single", 0.3);
    let old = ticket(&mut e, 0);
    send(&mut e, 1, json!({"op":"reset_simulation"}));
    send(&mut e, 2, json!({"op":"connect","device_id":"sim_single"}));
    send(
        &mut e,
        3,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    let new = ticket(&mut e, 4);
    assert_ne!(old, new);
    assert_eq!(complete(&mut e, 5, old, intent())["ok"], false);
}
#[test]
fn zero_limit_and_bounded_output_on_both_channels() {
    for cap in [0.0, 0.01, 0.3, 1.0] {
        let mut e = setup("sim_dual", cap);
        send(&mut e, 0, json!({"op":"play","preset_id":"dual_alternate"}));
        for now in (0..2500).step_by(13) {
            for v in snap(&mut e, now)["output"].as_array().unwrap() {
                let v = v.as_f64().unwrap();
                assert!(v >= 0.0 && v <= cap);
            }
        }
        assert_eq!(snap(&mut e, 2500)["output"], json!([0.0, 0.0]));
    }
}
#[test]
fn invalid_policy_rejected_without_mutation() {
    for limit in [-0.01, 1.01] {
        let mut e = Engine::new();
        send(&mut e, 0, json!({"op":"connect","device_id":"sim_single"}));
        assert_eq!(
            send(
                &mut e,
                0,
                json!({"op":"authorize","limit":limit,"lease_ms":30000})
            )["ok"],
            false
        );
    }
    let mut e = Engine::new();
    assert_eq!(
        e.request(0, "{\"op\":\"authorize\",\"limit\":NaN,\"lease_ms\":30000}")["ok"],
        false
    );
}
#[test]
fn bounded_pending_requests_events_samples_and_input() {
    let mut e = setup("sim_single", 0.3);
    for _ in 0..16 {
        ticket(&mut e, 0);
    }
    assert_eq!(
        send(&mut e, 0, json!({"op":"begin_ai"}))["error"],
        "too_many_pending"
    );
    assert_eq!(
        e.request(0, &" ".repeat(70000))["error"],
        "request_too_large"
    );
    for n in 0..1000 {
        e.request(n * 50, "{}");
    }
    let s = snap(&mut e, 50000);
    assert!(s["events"].as_array().unwrap().len() <= 80);
    assert!(s["samples"].as_array().unwrap().len() <= 160);
}
#[test]
fn deterministic_randomized_state_sequences_preserve_output_invariants() {
    let mut e = Engine::new();
    let mut seed = 0x71d29f3_u64;
    for i in 0..20000_u64 {
        seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1);
        let req = match (seed >> 32) % 8 {
            0 => json!({"op":"connect","device_id":"sim_dual"}),
            1 => json!({"op":"authorize","limit":0.4,"lease_ms":30000}),
            2 => json!({"op":"play","preset_id":"dual_alternate"}),
            3 => json!({"op":"stop"}),
            4 => json!({"op":"disconnect"}),
            5 => json!({"op":"complete_ai","ticket":seed,"response":"{}"}),
            6 => json!({"op":"begin_ai"}),
            _ => json!({"op":"snapshot"}),
        };
        let s = send(&mut e, i * 31, req)["state"].clone();
        let phase = s["phase"].as_str().unwrap();
        for v in s["output"].as_array().unwrap() {
            let v = v.as_f64().unwrap();
            assert!(v >= 0.0 && v <= s["limit"].as_f64().unwrap());
            if phase != "playing" {
                assert_eq!(v, 0.0);
            }
        }
    }
}
