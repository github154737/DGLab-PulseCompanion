use haptics_core::{waveform::Waveform, Engine};
use serde_json::{json, Value};
fn req(e: &mut Engine, t: u64, v: Value) -> Value {
    e.request(t, &v.to_string())
}
fn envelope() -> Value {
    json!({"format":"envelope_v1","id":"my_wave","name":"测试曲线","channels":1,"frames":[{"duration_ms":500,"levels":[1.0,0.0]},{"duration_ms":500,"levels":[0.2,0.0]}]})
}
fn imported() -> Engine {
    let mut e = Engine::new();
    assert_eq!(
        req(
            &mut e,
            0,
            json!({"op":"import_waveform","source":envelope().to_string()})
        )["ok"],
        true
    );
    req(&mut e, 0, json!({"op":"connect","device_id":"sim_single"}));
    req(
        &mut e,
        0,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    e
}
#[test]
fn import_is_atomic_and_does_not_authorize() {
    let mut e = Engine::new();
    let result = req(
        &mut e,
        0,
        json!({"op":"import_waveform","source":envelope().to_string()}),
    );
    assert_eq!(result["state"]["phase"], "disconnected");
    assert_eq!(result["state"]["output"], json!([0.0, 0.0]));
    assert_eq!(
        req(
            &mut e,
            0,
            json!({"op":"import_waveform","source":envelope().to_string()})
        )["error"],
        "duplicate_waveform_id"
    );
    assert_eq!(
        req(&mut e, 0, json!({"op":"snapshot"}))["state"]["waveforms"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
}
#[test]
fn malformed_waveforms_are_rejected() {
    for field in ["channels", "frames"] {
        let mut w = envelope();
        w[field] = json!(-1);
        assert!(Waveform::parse(&w.to_string()).is_err());
    }
    let mut w = envelope();
    w["frames"][0]["levels"] = json!([1.01, 0]);
    assert!(Waveform::parse(&w.to_string()).is_err());
    let mut w = envelope();
    w["frames"][0]["levels"] = json!([0.1, 0.1]);
    assert!(Waveform::parse(&w.to_string()).is_err());
    let mut w = envelope();
    w["unknown"] = json!(1);
    assert!(Waveform::parse(&w.to_string()).is_err());
    let mut w = envelope();
    w["frames"][0]["duration_ms"] = json!(u64::MAX);
    assert!(Waveform::parse(&w.to_string()).is_err());
    assert!(Waveform::parse(&"x".repeat(32769)).is_err());
}
#[test]
fn native_dglab_bytes_are_validated_and_kept_distinct() {
    let wave =
        json!({"format":"dglab_v3","id":"pulse","name":"脉冲预览","a":["0A0A0A0A00193264"],"b":[]});
    let parsed = Waveform::parse(&wave.to_string()).unwrap();
    assert_eq!(parsed.levels(75), [1.0, 0.0]);
    assert_eq!(parsed.duration(), 100);
    for block in [
        "090A0A0A00193264",
        "0A0A0A0A00193265",
        "0A0A0A0A001932",
        "GG0A0A0A00193264",
    ] {
        let mut w = wave.clone();
        w["a"] = json!([block]);
        assert!(Waveform::parse(&w.to_string()).is_err());
    }
    let mut e = Engine::new();
    req(
        &mut e,
        0,
        json!({"op":"import_waveform","source":wave.to_string()}),
    );
    req(&mut e, 0, json!({"op":"connect","device_id":"sim_dual"}));
    req(
        &mut e,
        0,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    assert_eq!(
        req(
            &mut e,
            0,
            json!({"op":"play_waveform","waveform_id":"pulse"})
        )["error"],
        "waveform_capability_mismatch"
    );
    req(&mut e, 1, json!({"op":"disconnect"}));
    assert_eq!(
        req(&mut e, 2, json!({"op":"connect","device_id":"sim_dglab"}))["ok"],
        true
    );
    req(
        &mut e,
        2,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    assert_eq!(
        req(&mut e, 2, json!({"op":"play","preset_id":"gentle_wave"}))["error"],
        "waveform_capability_mismatch"
    );
    assert_eq!(
        req(
            &mut e,
            2,
            json!({"op":"play_waveform","waveform_id":"pulse"})
        )["ok"],
        true
    );
}
#[test]
fn imported_playback_is_bounded_and_stops() {
    let mut e = imported();
    let r = req(
        &mut e,
        0,
        json!({"op":"play_waveform","waveform_id":"my_wave"}),
    );
    assert_eq!(r["state"]["output"], json!([0.15, 0.0]));
    assert_eq!(
        req(
            &mut e,
            100,
            json!({"op":"remove_waveform","waveform_id":"my_wave"})
        )["error"],
        "waveform_library_locked"
    );
    req(&mut e, 200, json!({"op":"stop"}));
    assert_eq!(
        req(&mut e, 500, json!({"op":"snapshot"}))["state"]["output"],
        json!([0.0, 0.0])
    );
}
fn ai(e: &mut Engine, now: u64, intent: Value) -> Value {
    let ticket = req(e, now, json!({"op":"begin_ai"}))["result"]["ticket"].clone();
    req(
        e,
        now,
        json!({"op":"complete_ai","ticket":ticket,"response":intent.to_string()}),
    )
}
#[test]
fn ai_gain_steps_rates_and_slew_are_enforced() {
    let mut e = imported();
    assert_eq!(
        ai(&mut e, 0, json!({"action":"set_gain","gain":0.9}))["error"],
        "ai_gain_step_too_large"
    );
    assert_eq!(
        ai(&mut e, 1, json!({"action":"set_gain","gain":0.6}))["ok"],
        true
    );
    assert_eq!(
        ai(&mut e, 2, json!({"action":"set_gain","gain":0.7}))["error"],
        "ai_gain_rate_limited"
    );
    let s = req(&mut e, 101, json!({"op":"snapshot"}))["state"].clone();
    assert!(s["gain"].as_f64().unwrap() < 0.53);
    assert_eq!(s["limit"], 0.3);
    assert_eq!(
        ai(&mut e, 102, json!({"action":"set_gain","gain":0.1}))["state"]["gain"],
        0.1
    );
}
#[test]
fn manual_gain_wins_over_pending_ai() {
    let mut e = imported();
    let t = req(&mut e, 0, json!({"op":"begin_ai"}))["result"]["ticket"].clone();
    assert_eq!(
        req(&mut e, 1, json!({"op":"set_gain","gain":0.45}))["ok"],
        true
    );
    let result = req(
        &mut e,
        2,
        json!({"op":"complete_ai","ticket":t,
        "response":json!({"action":"set_gain","gain":0.55}).to_string()}),
    );
    assert_eq!(result["ok"], false);
    assert_eq!(result["state"]["gain_target"], 0.45);
    assert_eq!(result["state"]["phase"], "authorized");
    assert_eq!(
        ai(&mut e, 3, json!({"action":"set_gain","gain":0.5}))["ok"],
        true
    );
}
#[test]
fn ai_disable_revokes_pending_waveform_and_strength_changes() {
    let mut e = imported();
    let t = req(&mut e, 0, json!({"op":"begin_ai"}))["result"]["ticket"].clone();
    req(&mut e, 1, json!({"op":"set_ai_control","enabled":false}));
    assert_eq!(
        req(
            &mut e,
            2,
            json!({"op":"complete_ai","ticket":t,"response":"{\"action\":\"set_gain\",\"gain\":0.6}"})
        )["ok"],
        false
    );
    assert_eq!(
        req(&mut e, 2, json!({"op":"begin_ai"}))["error"],
        "ai_control_disabled"
    );
    assert_eq!(
        req(&mut e, 2, json!({"op":"set_gain","gain":0.2}))["ok"],
        true
    );
}
#[test]
fn approved_import_can_be_selected_by_ai_but_not_uploaded_by_it() {
    let mut e = imported();
    assert_eq!(
        ai(
            &mut e,
            0,
            json!({"action":"import_waveform","source":envelope().to_string()})
        )["ok"],
        false
    );
    assert_eq!(
        ai(
            &mut e,
            1,
            json!({"action":"play_waveform","device_alias":"sim_single","waveform_id":"my_wave"})
        )["ok"],
        true
    );
    req(&mut e, 2, json!({"op":"stop"}));
    assert_eq!(
        req(&mut e, 3, json!({"op":"set_gain","gain":0.5}))["error"],
        "not_authorized"
    );
}
