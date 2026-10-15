use haptics_core::Engine;
use serde_json::{json, Value};

fn call(e: &mut Engine, t: u64, v: Value) -> Value {
    e.request(t, &v.to_string())
}
fn setup() -> Engine {
    let mut e = Engine::new();
    assert_eq!(
        call(&mut e, 0, json!({"op":"connect","device_id":"sim_dual"}))["ok"],
        true
    );
    assert_eq!(
        call(
            &mut e,
            0,
            json!({"op":"authorize","limit":0.3,"lease_ms":30000})
        )["ok"],
        true
    );
    e
}
#[test]
fn channel_clear_is_independent_and_temporary_strength_expires() {
    let mut e = setup();
    let result = call(
        &mut e,
        1,
        json!({"op":"channel_actions","actions":[
            {"channel":0,"command":{"kind":"strength","value":0.4,"duration_ms":1000}},
            {"channel":1,"command":{"kind":"strength","value":0.3}}
        ]}),
    );
    assert_eq!(result["ok"], true);
    assert!(result["state"]["output"][0].as_f64().unwrap() > 0.0);
    let ended = call(&mut e, 1001, json!({"op":"snapshot"}));
    assert_eq!(ended["state"]["output"][0], 0.0);
    assert!(ended["state"]["output"][1].as_f64().unwrap() > 0.0);
    let stopped = call(&mut e, 1002, json!({"op":"stop"}));
    assert_eq!(stopped["state"]["output"], json!([0.0, 0.0]));
    assert_eq!(
        call(&mut e, 1500, json!({"op":"snapshot"}))["state"]["output"],
        json!([0.0, 0.0])
    );
}
#[test]
fn invalid_batch_does_not_partially_apply_and_manual_edit_invalidates_ai() {
    let mut e = setup();
    let ticket = call(&mut e, 1, json!({"op":"begin_ai"}))["result"]["ticket"].clone();
    let bad = call(
        &mut e,
        2,
        json!({"op":"channel_actions","actions":[
            {"channel":0,"command":{"kind":"clear"}},
            {"channel":2,"command":{"kind":"strength","value":0.2}}
        ]}),
    );
    assert_eq!(bad["ok"], false);
    assert_eq!(bad["state"]["channels"][0]["target"], 1.0);
    assert_eq!(
        call(
            &mut e,
            3,
            json!({"op":"channel_actions","actions":[{"channel":0,"command":{"kind":"clear"}}]})
        )["ok"],
        true
    );
    assert_eq!(
        call(
            &mut e,
            4,
            json!({"op":"complete_ai","ticket":ticket,"response":"{\"action\":\"set_gain\",\"gain\":0.6}"})
        )["ok"],
        false
    );
}
#[test]
fn channel_limit_disable_and_absolute_ai_step_are_enforced() {
    let mut e = setup();
    assert_eq!(
        call(
            &mut e,
            1,
            json!({"op":"configure_channel","channel":0,"enabled":true,"limit":0.2})
        )["ok"],
        true
    );
    assert_eq!(
        call(
            &mut e,
            2,
            json!({"op":"configure_channel","channel":0,"enabled":true,"limit":0.3})
        )["error"],
        "channel_policy_locked"
    );
    call(
        &mut e,
        3,
        json!({"op":"channel_actions","actions":[{"channel":0,"command":{"kind":"strength","value":0.2}}]}),
    );
    let ticket = call(&mut e, 4, json!({"op":"begin_ai"}))["result"]["ticket"].clone();
    let response=json!({"action":"channel_actions","actions":[{"channel":0,"command":{"kind":"strength","value":0.9}}]}).to_string();
    assert_eq!(
        call(
            &mut e,
            5,
            json!({"op":"complete_ai","ticket":ticket,"response":response})
        )["error"],
        "channel_step_too_large"
    );
    let disabled = call(
        &mut e,
        6,
        json!({"op":"configure_channel","channel":0,"enabled":false,"limit":0.2}),
    );
    assert_eq!(disabled["state"]["output"][0], 0.0);
    assert_eq!(
        call(
            &mut e,
            7,
            json!({"op":"channel_actions","actions":[{"channel":0,"command":{"kind":"pattern","preset_id":"lab_tide","duration_ms":2000,"repeat":true}}]})
        )["error"],
        "channel_disabled"
    );
}
#[test]
fn independent_patterns_end_and_authorization_still_wins() {
    let mut e = setup();
    let result = call(
        &mut e,
        1,
        json!({"op":"channel_actions","actions":[
            {"channel":0,"command":{"kind":"pattern","preset_id":"lab_short","duration_ms":1000,"repeat":true}},
            {"channel":1,"command":{"kind":"pattern","preset_id":"lab_breathe","duration_ms":20000,"repeat":true}}
        ]}),
    );
    assert_eq!(result["ok"], true);
    assert_eq!(
        call(&mut e, 1002, json!({"op":"snapshot"}))["state"]["output"][0],
        0.0
    );
    assert_eq!(
        call(&mut e, 30000, json!({"op":"snapshot"}))["state"]["phase"],
        "stopped"
    );
    assert_eq!(
        call(&mut e, 30001, json!({"op":"snapshot"}))["state"]["output"],
        json!([0.0, 0.0])
    );
}

#[test]
fn native_frames_preserve_frequency_and_deadline_zeros_the_dispatch() {
    let mut e = Engine::new();
    let source=json!({"format":"dglab_v3","id":"native_fixture","name":"Fixture","a":["0A141E28323C4650","141E28323C46505A"],"b":[]}).to_string();
    assert_eq!(
        call(&mut e, 0, json!({"op":"import_waveform","source":source}))["ok"],
        true
    );
    call(&mut e, 0, json!({"op":"connect","device_id":"sim_dglab"}));
    call(
        &mut e,
        0,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    let playing = call(
        &mut e,
        0,
        json!({"op":"start_experience","waveform_id":"native_fixture"}),
    );
    assert_eq!(
        playing["state"]["dglab_output"][0]["frame"],
        "0A141E28323C4650"
    );
    assert_eq!(playing["state"]["dglab_output"][0]["strength_scale"], 0.15);
    assert_eq!(
        playing["state"]["dglab_output"][1]["frame"],
        "1414141400000000"
    );
    let ending = call(&mut e, 29975, json!({"op":"snapshot"}));
    assert!(ending["state"]["dglab_output"][0]["frame"]
        .as_str()
        .unwrap()
        .ends_with("000000"));
    let stopped = call(&mut e, 30000, json!({"op":"snapshot"}));
    assert_eq!(stopped["state"]["dglab_output"][0]["strength_scale"], 0.0);
    assert_eq!(
        stopped["state"]["dglab_output"][0]["frame"],
        "1414141400000000"
    );
}

#[test]
fn channel_expiry_preserves_unknown_for_an_unconfirmed_stop() {
    let mut e = Engine::new();
    call(&mut e, 0, json!({"op":"connect","device_id":"sim_fault"}));
    call(
        &mut e,
        0,
        json!({"op":"authorize","limit":0.3,"lease_ms":30000}),
    );
    call(
        &mut e,
        1,
        json!({"op":"channel_actions","actions":[{"channel":0,"command":{"kind":"strength","value":0.5,"duration_ms":1000}}]}),
    );
    call(
        &mut e,
        2,
        json!({"op":"set_fault","fault":"stop_unconfirmed"}),
    );
    let state = call(&mut e, 1001, json!({"op":"snapshot"}));
    assert_eq!(state["state"]["phase"], "unknown");
    assert!(state["state"]["output"][0].as_f64().unwrap() > 0.0);
    assert_eq!(state["state"]["dglab_output"][0]["strength_scale"], 0.0);
}
