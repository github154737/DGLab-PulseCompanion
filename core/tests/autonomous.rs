use haptics_core::Engine;
use serde_json::{json, Value};
fn call(e: &mut Engine, now: u64, v: Value) -> Value {
    e.request(now, &v.to_string())
}
#[test]
fn explicit_simulation_scope_keeps_old_authorization_limit() {
    let mut e = Engine::new();
    call(&mut e, 0, json!({"op":"connect","device_id":"sim_single"}));
    assert_eq!(
        call(
            &mut e,
            0,
            json!({"op":"authorize","limit":0.3,"lease_ms":60000})
        )["ok"],
        false
    );
    assert_eq!(
        call(
            &mut e,
            0,
            json!({"op":"authorize_simulation_session","limit":0.3,"lease_ms":60000})
        )["ok"],
        true
    );
    for now in (1000..60000).step_by(1000) {
        assert_eq!(
            call(&mut e, now, json!({"op":"simulation_heartbeat"}))["ok"],
            true
        );
    }
    assert_eq!(
        call(&mut e, 60001, json!({"op":"simulation_heartbeat"}))["ok"],
        false
    );
    assert_eq!(
        call(&mut e, 60001, json!({"op":"snapshot"}))["state"]["phase"],
        "stopped"
    );
}
#[test]
fn missing_watchdog_and_stop_expire_all_tickets() {
    let mut e = Engine::new();
    call(&mut e, 0, json!({"op":"connect","device_id":"sim_single"}));
    call(
        &mut e,
        0,
        json!({"op":"authorize_simulation_session","limit":0.3,"lease_ms":60000}),
    );
    let ticket = call(&mut e, 0, json!({"op":"begin_ai"}))["result"]["ticket"].clone();
    e.tick(2001);
    assert_eq!(
        call(
            &mut e,
            2001,
            json!({"op":"complete_ai","ticket":ticket,"response":"{\"action\":\"set_gain\",\"gain\":0.6}"})
        )["ok"],
        false
    );
    assert_eq!(
        call(&mut e, 2001, json!({"op":"simulation_heartbeat"}))["ok"],
        false
    );
}
#[test]
fn extended_scope_rejects_other_adapters_and_excessive_duration() {
    for device in ["sim_dual", "sim_fault", "sim_dglab"] {
        let mut e = Engine::new();
        call(&mut e, 0, json!({"op":"connect","device_id":device}));
        assert_eq!(
            call(
                &mut e,
                0,
                json!({"op":"authorize_simulation_session","limit":0.3,"lease_ms":60000})
            )["ok"],
            false
        );
    }
    let mut e = Engine::new();
    call(&mut e, 0, json!({"op":"connect","device_id":"sim_single"}));
    assert_eq!(
        call(
            &mut e,
            0,
            json!({"op":"authorize_simulation_session","limit":0.3,"lease_ms":180001})
        )["ok"],
        false
    );
}
