//! Original, deterministic patterns. These are simulator shapes, not calibrated device doses.
use serde_json::{json, Value};
use std::f64::consts::TAU;

pub const PATTERNS: [(&str, &str, &str, u64); 24] = [
    ("lab_breathe", "慢呼吸", "Slow breath", 6000),
    ("lab_tide", "潮汐", "Tide", 4000),
    ("lab_ripple", "细涟漪", "Ripples", 2000),
    ("lab_triangle", "三角起伏", "Triangle", 3000),
    ("lab_rise", "缓升", "Rising", 4000),
    ("lab_fall", "缓降", "Falling", 4000),
    ("lab_steps_up", "阶梯上行", "Steps up", 4000),
    ("lab_steps_down", "阶梯下行", "Steps down", 4000),
    ("lab_double", "双拍", "Double beat", 2000),
    ("lab_triple", "三拍", "Triple beat", 3000),
    ("lab_short", "短脉冲", "Short pulse", 1000),
    ("lab_long", "长脉冲", "Long pulse", 2400),
    ("lab_flutter", "轻颤", "Flutter", 1000),
    ("lab_swells", "叠浪", "Layered swell", 6000),
    ("lab_echo", "回声", "Echo", 3000),
    ("lab_drift", "漂流", "Drift", 5000),
    ("lab_sway", "左右摇摆", "Sway", 4000),
    ("lab_answer", "双通道应答", "Call and response", 4000),
    ("lab_cross", "交错起伏", "Crossfade", 5000),
    ("lab_pause", "呼吸留白", "Breath and pause", 6000),
    ("lab_notches", "锯齿缓波", "Soft notches", 3200),
    ("lab_spark", "星点", "Sparks", 4000),
    ("lab_plateau", "平台", "Plateau", 4000),
    ("lab_glow", "余光", "Afterglow", 5000),
];

pub fn period(id: &str) -> Option<u64> {
    PATTERNS.iter().find(|p| p.0 == id).map(|p| p.3)
}

pub fn level(id: &str, elapsed: u64, channel: usize) -> f64 {
    let Some(index) = PATTERNS.iter().position(|p| p.0 == id) else {
        return 0.0;
    };
    let t = (elapsed % PATTERNS[index].3) as f64 / PATTERNS[index].3 as f64;
    let smooth = |x: f64| 0.5 - 0.5 * (TAU * x).cos();
    let pulse = |x: f64, width: f64| if x.fract() < width { 0.7 } else { 0.0 };
    let result = match index {
        0..=2 => smooth(t) * 0.75,
        3 => (1.0 - (2.0 * t - 1.0).abs()) * 0.75,
        4 => t * 0.7,
        5 => (1.0 - t) * 0.7,
        6 => (t * 5.0).floor() / 5.0 * 0.75,
        7 => (4.0 - (t * 5.0).floor()) / 5.0 * 0.75,
        8 => {
            if t < 0.15 || (0.3..0.45).contains(&t) {
                0.65
            } else {
                0.0
            }
        }
        9 => pulse(t * 3.0, 0.25),
        10 => pulse(t, 0.2),
        11 => pulse(t, 0.7),
        12 => 0.2 + smooth(t * 5.0) * 0.3,
        13 => smooth(t) * (0.35 + smooth(t * 3.0) * 0.4),
        14 => pulse(t * 3.0, 0.35) * (1.0 - t),
        15 => 0.15 + smooth(t) * 0.45,
        16 => smooth(t + channel as f64 * 0.5) * 0.7,
        17 => {
            if (t < 0.5) == (channel == 0) {
                smooth(t * 2.0) * 0.65
            } else {
                0.0
            }
        }
        18 => (if channel == 0 { t } else { 1.0 - t }) * 0.65,
        19 => {
            if t < 0.6 {
                smooth(t / 0.6) * 0.7
            } else {
                0.0
            }
        }
        20 => smooth(t) * (0.25 + 0.45 * (t * 8.0).fract()),
        21 => pulse(t * 7.0, 0.18) * (0.4 + 0.5 * smooth(t)),
        22 => {
            if t < 0.25 {
                t * 2.4
            } else if t < 0.75 {
                0.6
            } else {
                (1.0 - t) * 2.4
            }
        }
        _ => (1.0 - t).powi(2) * (0.2 + smooth(t * 4.0) * 0.5),
    };
    result.clamp(0.0, 1.0)
}

pub fn catalog() -> Value {
    Value::Array(
        PATTERNS
            .iter()
            .map(|p| {
                json!({
                    "id":p.0,"name":p.1,"name_en":p.2,"duration_ms":p.3,
                    "dual": (["lab_sway","lab_answer","lab_cross"].contains(&p.0)),
                })
            })
            .collect(),
    )
}

pub fn waveform(id: &str, electrical: bool) -> Result<Value, String> {
    let index = PATTERNS
        .iter()
        .position(|p| p.0 == id)
        .ok_or("unknown_preset")?;
    let pattern = PATTERNS[index];
    if electrical {
        let frames = |channel| {
            (0..pattern.3 / 100)
                .map(|i| {
                    let frequency = 20 + index * 4;
                    let mut frame = format!("{frequency:02X}").repeat(4);
                    for sub in 0..4 {
                        frame.push_str(&format!(
                            "{:02X}",
                            (level(id, i * 100 + sub * 25, channel) * 100.0).round() as u8
                        ));
                    }
                    frame
                })
                .collect::<Vec<_>>()
        };
        Ok(
            json!({"format":"dglab_v3","id":format!("{id}_v3"),"name":pattern.1,"a":frames(0),"b":frames(1)}),
        )
    } else {
        let frames = (0..pattern.3 / 50)
            .map(|i| {
                json!({"duration_ms":50,
            "levels":[level(id,i*50,0),level(id,i*50,1)]})
            })
            .collect::<Vec<_>>();
        Ok(
            json!({"format":"envelope_v1","id":format!("{id}_env"),"name":pattern.1,"channels":2,"frames":frames}),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn all_original_patterns_export_valid_bounded_waveforms() {
        for p in PATTERNS {
            for electrical in [false, true] {
                let source = waveform(p.0, electrical).unwrap().to_string();
                let wave = crate::waveform::Waveform::parse(&source).unwrap();
                assert_eq!(wave.duration(), p.3);
                for time in (0..p.3 * 2).step_by(17) {
                    for channel in 0..2 {
                        assert!((0.0..=1.0).contains(&level(p.0, time, channel)));
                    }
                }
            }
        }
    }
}
