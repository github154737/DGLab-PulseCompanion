use crate::Playback;
use serde::{Deserialize, Serialize};

#[derive(Clone)]
pub struct Channel {
    pub enabled: bool,
    pub limit: f64,
    pub gain: f64,
    pub target: f64,
    pub muted: bool,
    pub until: Option<u64>,
    pub playback: Option<Playback>,
    pub last_increase: Option<u64>,
}
impl Default for Channel {
    fn default() -> Self {
        Self {
            enabled: true,
            limit: 1.0,
            gain: 1.0,
            target: 1.0,
            muted: false,
            until: None,
            playback: None,
            last_increase: None,
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum ChannelCommand {
    Strength {
        value: f64,
        duration_ms: Option<u64>,
    },
    Adjust {
        delta: f64,
    },
    Pattern {
        preset_id: String,
        duration_ms: u64,
        repeat: bool,
    },
    Waveform {
        waveform_id: String,
        duration_ms: u64,
        repeat: bool,
    },
    Clear {},
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ChannelAction {
    pub channel: usize,
    pub command: ChannelCommand,
}
