use haptics_core::Engine;
use serde_json::{json, Value};

fn req(e: &mut Engine, now: u64, value: Value) -> Value {
    e.request(now, &value.to_string())
}
fn setup() -> Engine {
    let mut e = Engine::new();
    req(&mut e, 0, json!({"op":"connect","device_id":"sim_single"}));
    req(
        &mut e,
        0,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    e
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
fn continuous_experience_obeys_deadline_and_never_auto_renews() {
    let mut e = setup();
    assert_eq!(
        req(
            &mut e,
            0,
            json!({"op":"start_experience","preset_id":"gentle_wave"})
        )["ok"],
        true
    );
    let state = req(&mut e, 5500, json!({"op":"snapshot"}))["state"].clone();
    assert_eq!(state["phase"], "playing");
    assert_eq!(state["continuous"], true);
    assert!(state["output"][0].as_f64().unwrap() > 0.0);
    let state = req(&mut e, 30000, json!({"op":"snapshot"}))["state"].clone();
    assert_eq!(state["phase"], "stopped");
    assert_eq!(state["output"], json!([0.0, 0.0]));
    assert_eq!(
        req(
            &mut e,
            31000,
            json!({"op":"start_experience","preset_id":"gentle_wave"})
        )["ok"],
        false
    );
}

#[test]
fn gain_changes_and_pattern_switches_affect_continuous_output() {
    let mut e = setup();
    req(
        &mut e,
        0,
        json!({"op":"start_experience","preset_id":"gentle_wave"}),
    );
    let before = req(&mut e, 600, json!({"op":"snapshot"}))["state"]["output"][0]
        .as_f64()
        .unwrap();
    assert_eq!(
        ai(&mut e, 600, json!({"action":"set_gain","gain":0.6}))["ok"],
        true
    );
    for time in (650..=1800).step_by(50) {
        e.tick(time);
    }
    let after = req(&mut e, 1800, json!({"op":"snapshot"}))["state"]["output"][0]
        .as_f64()
        .unwrap();
    assert!(after > before);
    assert_eq!(
        ai(
            &mut e,
            1900,
            json!({"action":"play_preset","device_alias":"sim_single","preset_id":"soft_pulse"})
        )["ok"],
        true
    );
    let result = ai(
        &mut e,
        2000,
        json!({"action":"play_preset","device_alias":"sim_single","preset_id":"bad"}),
    );
    assert_eq!(result["ok"], false);
    assert_eq!(result["state"]["preset"], "soft_pulse");
    assert_eq!(result["state"]["continuous"], true);
    assert_eq!(result["state"]["remaining_ms"], 28000);
}

#[test]
fn only_local_start_can_enable_continuous_experience() {
    let mut e = Engine::new();
    assert_eq!(
        req(
            &mut e,
            0,
            json!({"op":"start_experience","preset_id":"gentle_wave"})
        )["ok"],
        false
    );
    let mut e = setup();
    assert_eq!(
        ai(
            &mut e,
            0,
            json!({"action":"start_experience","preset_id":"gentle_wave"})
        )["ok"],
        false
    );
    assert_eq!(
        req(
            &mut e,
            1,
            json!({"op":"start_experience","preset_id":"gentle_wave","waveform_id":"x"})
        )["ok"],
        false
    );
    assert_eq!(
        req(&mut e, 2, json!({"op":"snapshot"}))["state"]["phase"],
        "authorized"
    );
}

#[test]
fn manual_start_and_stop_revoke_pending_replies() {
    let mut e = setup();
    let old = req(&mut e, 0, json!({"op":"begin_ai"}))["result"]["ticket"].clone();
    req(
        &mut e,
        1,
        json!({"op":"start_experience","preset_id":"soft_pulse"}),
    );
    assert_eq!(
        req(
            &mut e,
            2,
            json!({"op":"complete_ai","ticket":old,"response":"{\"action\":\"set_gain\",\"gain\":0.6}"})
        )["ok"],
        false
    );
    req(&mut e, 3, json!({"op":"stop"}));
    assert_eq!(
        req(&mut e, 4, json!({"op":"snapshot"}))["state"]["output"],
        json!([0.0, 0.0])
    );
}

#[test]
fn imported_waveform_repeats_from_its_first_frame() {
    let mut e = Engine::new();
    let wave = json!({"format":"envelope_v1","id":"loop","name":"Loop","channels":1,
        "frames":[{"duration_ms":250,"levels":[0.1,0.0]},{"duration_ms":250,"levels":[0.8,0.0]}]});
    assert_eq!(
        req(
            &mut e,
            0,
            json!({"op":"import_waveform","source":wave.to_string()})
        )["ok"],
        true
    );
    req(&mut e, 0, json!({"op":"connect","device_id":"sim_single"}));
    req(
        &mut e,
        0,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    req(
        &mut e,
        0,
        json!({"op":"start_experience","waveform_id":"loop"}),
    );
    let first = req(&mut e, 100, json!({"op":"snapshot"}))["state"]["output"].clone();
    assert_eq!(
        req(&mut e, 600, json!({"op":"snapshot"}))["state"]["output"],
        first
    );
    assert_eq!(
        req(&mut e, 600, json!({"op":"snapshot"}))["state"]["continuous"],
        true
    );
}
