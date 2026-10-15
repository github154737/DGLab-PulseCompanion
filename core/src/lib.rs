use serde::{Deserialize, Serialize};
mod channel_control;
pub mod patterns;
pub mod waveform;
use channel_control::{Channel, ChannelAction, ChannelCommand};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    ffi::{CStr, CString},
    os::raw::c_char,
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant},
};
use waveform::Waveform;

const MAX_INPUT: usize = 65_536;
const MAX_EVENTS: usize = 80;
const MAX_SAMPLES: usize = 160;
const MAX_PENDING: usize = 16;

#[derive(Clone, Serialize)]
pub struct Device {
    pub id: &'static str,
    pub name: &'static str,
    pub channels: usize,
}
fn devices() -> Vec<Device> {
    vec![
        Device {
            id: "sim_single",
            name: "单通道模拟器",
            channels: 1,
        },
        Device {
            id: "sim_dual",
            name: "双通道模拟器",
            channels: 2,
        },
        Device {
            id: "sim_fault",
            name: "故障模拟器",
            channels: 1,
        },
        Device {
            id: "sim_dglab",
            name: "郊狼波形预览器",
            channels: 2,
        },
    ]
}

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Disconnected,
    Ready,
    Authorized,
    Playing,
    Stopped,
    Unknown,
}
#[derive(Clone, Copy, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Fault {
    None,
    HoldOnDisconnect,
    StopUnconfirmed,
}
#[derive(Clone, Serialize)]
pub struct Event {
    pub at_ms: u64,
    pub message: String,
}
#[derive(Clone, Serialize)]
pub struct Sample {
    pub at_ms: u64,
    pub values: [f64; 2],
}
#[derive(Clone)]
struct Ticket {
    epoch: u64,
    generation: u64,
    expires: u64,
}
#[derive(Clone)]
pub(crate) struct Playback {
    preset: String,
    started: u64,
    ends: u64,
    waveform: Option<Arc<Waveform>>,
    repeat: bool,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Request {
    ConfigureChannel {
        channel: usize,
        enabled: bool,
        limit: f64,
    },
    ChannelActions {
        actions: Vec<ChannelAction>,
    },
    ExportPattern {
        preset_id: String,
        electrical: bool,
    },
    Snapshot {},
    ResetSimulation {},
    Connect {
        device_id: String,
    },
    Disconnect {},
    Authorize {
        limit: f64,
        lease_ms: u64,
    },
    AuthorizeSimulationSession {
        limit: f64,
        lease_ms: u64,
    },
    SimulationHeartbeat {},
    Stop {},
    Play {
        preset_id: String,
    },
    SetFault {
        fault: Fault,
    },
    BeginAi {},
    CompleteAi {
        ticket: u64,
        response: String,
    },
    CancelAi {
        ticket: u64,
    },
    ValidateWaveform {
        source: String,
    },
    ImportWaveform {
        source: String,
    },
    RemoveWaveform {
        waveform_id: String,
    },
    PlayWaveform {
        waveform_id: String,
    },
    SetGain {
        gain: f64,
    },
    SetAiControl {
        enabled: bool,
    },
    StartExperience {
        preset_id: Option<String>,
        waveform_id: Option<String>,
    },
}
#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum Intent {
    ChannelActions {
        actions: Vec<ChannelAction>,
    },
    PlayPreset {
        device_alias: String,
        preset_id: String,
    },
    Stop {},
    Noop {},
    PlayWaveform {
        device_alias: String,
        waveform_id: String,
    },
    SetGain {
        gain: f64,
    },
}

#[derive(Clone)]
pub struct Engine {
    channels: [Channel; 2],
    phase: Phase,
    device: Option<Device>,
    connected: bool,
    epoch: u64,
    generation: u64,
    next_ticket: u64,
    limit: f64,
    deadline: Option<u64>,
    simulation_watchdog: Option<u64>,
    playback: Option<Playback>,
    output: [f64; 2],
    fault: Fault,
    events: VecDeque<Event>,
    samples: VecDeque<Sample>,
    tickets: HashMap<u64, Ticket>,
    last_sample: u64,
    waveforms: Vec<Arc<Waveform>>,
    gain: f64,
    gain_target: f64,
    last_tick: u64,
    ai_control: bool,
    last_ai_increase: Option<u64>,
}
impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}
impl Engine {
    pub fn new() -> Self {
        Self {
            channels: [Channel::default(), Channel::default()],
            phase: Phase::Disconnected,
            device: None,
            connected: false,
            epoch: 0,
            generation: 0,
            next_ticket: 0,
            limit: 0.3,
            deadline: None,
            simulation_watchdog: None,
            playback: None,
            output: [0.0; 2],
            fault: Fault::None,
            events: VecDeque::new(),
            samples: VecDeque::new(),
            tickets: HashMap::new(),
            last_sample: 0,
            waveforms: Vec::new(),
            gain: 0.5,
            gain_target: 0.5,
            last_tick: 0,
            ai_control: true,
            last_ai_increase: None,
        }
    }
    fn event(&mut self, now: u64, message: &str) {
        if self.events.len() == MAX_EVENTS {
            self.events.pop_front();
        }
        self.events.push_back(Event {
            at_ms: now,
            message: message.into(),
        });
    }
    fn invalidate(&mut self) {
        self.epoch += 1;
        self.deadline = None;
        self.simulation_watchdog = None;
        self.playback = None;
        self.tickets.clear();
        for channel in &mut self.channels {
            channel.playback = None;
            channel.until = None;
        }
    }
    fn stop(&mut self, now: u64, reason: &str) {
        self.invalidate();
        if (self.fault == Fault::StopUnconfirmed || !self.connected)
            && self.output.iter().any(|v| *v > 0.0)
        {
            self.phase = Phase::Unknown;
        } else {
            self.output = [0.0; 2];
            self.phase = if self.connected {
                Phase::Stopped
            } else {
                Phase::Disconnected
            };
        }
        self.event(now, reason);
    }
    pub fn tick(&mut self, now: u64) {
        let dt = now.saturating_sub(self.last_tick).min(250) as f64 / 1000.0;
        self.last_tick = now;
        self.gain = (self.gain + dt * 0.2).min(self.gain_target);
        self.tickets.retain(|_, t| t.expires > now);
        if self.deadline.is_some_and(|d| now >= d) {
            self.stop(now, "授权到期，撤销所有待执行请求");
        }
        if self.simulation_watchdog.is_some_and(|d| now >= d) {
            self.stop(now, "自主模拟看门狗到期，撤销计划权限");
        }
        if let Some(p) = self.playback.clone() {
            if now >= p.ends {
                if self.fault == Fault::StopUnconfirmed {
                    self.stop(now, "预设结束，但停止未确认");
                } else {
                    self.playback = None;
                    self.output = [0.0; 2];
                    self.phase = Phase::Authorized;
                    self.event(now, "预设已完成（模拟输出归零）");
                }
            } else {
                let elapsed_ms = if p.repeat {
                    now.saturating_sub(p.started)
                        % p.waveform
                            .as_ref()
                            .map_or(patterns::period(&p.preset).unwrap_or(2400), |w| {
                                w.duration()
                            })
                } else {
                    now.saturating_sub(p.started)
                };
                let elapsed = elapsed_ms as f64 / 1000.0;
                let gain = match p.preset.as_str() {
                    "gentle_wave" => 0.5 - 0.5 * (elapsed * std::f64::consts::PI * 2.0 / 2.4).cos(),
                    "soft_pulse" => {
                        if ((elapsed * 4.0) as u64).is_multiple_of(2) {
                            0.65
                        } else {
                            0.15
                        }
                    }
                    "dual_alternate" => 0.5 - 0.5 * (elapsed * std::f64::consts::PI * 2.0).cos(),
                    _ => patterns::level(&p.preset, elapsed_ms, 0),
                };
                self.output = [gain * self.limit, 0.0];
                if self.device.as_ref().is_some_and(|d| d.channels == 2) {
                    self.output[1] = if p.preset == "dual_alternate" {
                        (1.0 - gain) * self.limit
                    } else if patterns::period(&p.preset).is_some() {
                        patterns::level(&p.preset, elapsed_ms, 1) * self.limit
                    } else {
                        self.output[0]
                    };
                }
                if let Some(wave) = &p.waveform {
                    self.output = wave.levels(elapsed_ms).map(|v| v * self.limit);
                }
                self.output = self.output.map(|v| v * self.gain);
            }
        }
        if self.authorized()
            && self.fault == Fault::StopUnconfirmed
            && self.channels.iter().any(|c| {
                c.until.is_some_and(|end| now >= end)
                    || c.playback.as_ref().is_some_and(|p| now >= p.ends)
            })
        {
            self.stop(now, "通道动作到期，但停止未确认");
        }
        if self.authorized() {
            if self.playback.is_none() {
                self.output = [0.0; 2];
            }
            for (index, channel) in self.channels.iter_mut().enumerate() {
                channel.gain = (channel.gain + dt * 0.2).min(channel.target);
                if channel.until.is_some_and(|end| now >= end) {
                    channel.until = None;
                    channel.target = 0.0;
                    channel.gain = 0.0;
                    channel.muted = true;
                    channel.playback = None;
                }
                if channel.playback.as_ref().is_some_and(|p| now >= p.ends) {
                    channel.playback = None;
                    channel.muted = true;
                }
                if let Some(p) = &channel.playback {
                    let period = p
                        .waveform
                        .as_ref()
                        .map_or(patterns::period(&p.preset).unwrap_or(2400), |w| {
                            w.duration()
                        });
                    let elapsed = if p.repeat {
                        now.saturating_sub(p.started) % period
                    } else {
                        now.saturating_sub(p.started)
                    };
                    let level = if let Some(wave) = &p.waveform {
                        wave.levels(elapsed)[index]
                    } else if p.preset == "channel_hold" {
                        1.0
                    } else {
                        patterns::level(&p.preset, elapsed, index)
                    };
                    self.output[index] = level * self.limit * self.gain;
                }
                self.output[index] *= channel.limit * channel.gain;
                if !channel.enabled
                    || channel.muted
                    || index >= self.device.as_ref().unwrap().channels
                {
                    self.output[index] = 0.0;
                }
            }
            self.phase =
                if self.playback.is_some() || self.channels.iter().any(|c| c.playback.is_some()) {
                    Phase::Playing
                } else {
                    Phase::Authorized
                };
        }
        if now.saturating_sub(self.last_sample) >= 50 {
            self.last_sample = now;
            if self.samples.len() == MAX_SAMPLES {
                self.samples.pop_front();
            }
            self.samples.push_back(Sample {
                at_ms: now,
                values: self.output,
            });
        }
    }
    fn authorized(&self) -> bool {
        self.connected
            && matches!(self.phase, Phase::Authorized | Phase::Playing)
            && self.deadline.is_some()
    }
    fn play(&mut self, now: u64, preset: &str) -> Result<Value, String> {
        if !self.authorized() {
            return Err("not_authorized".into());
        }
        if self.device.as_ref().is_some_and(|d| d.id == "sim_dglab")
            && patterns::period(preset).is_none()
        {
            return Err("waveform_capability_mismatch".into());
        }
        if !["gentle_wave", "soft_pulse", "dual_alternate"].contains(&preset)
            && patterns::period(preset).is_none()
        {
            return Err("unknown_preset".into());
        }
        if preset == "dual_alternate" && self.device.as_ref().map(|d| d.channels) != Some(2) {
            return Err("capability_mismatch".into());
        }
        let repeat = self.playback.as_ref().is_some_and(|p| p.repeat);
        if self.playback.is_some() && !repeat {
            return Err("busy".into());
        }
        let ends = if repeat {
            self.deadline.unwrap()
        } else {
            now.checked_add(patterns::period(preset).unwrap_or(2400))
                .ok_or("invalid_time")?
        };
        if ends > self.deadline.unwrap_or(0) {
            return Err("lease_too_short".into());
        }
        self.playback = Some(Playback {
            preset: preset.into(),
            started: now,
            ends,
            waveform: None,
            repeat,
        });
        self.phase = Phase::Playing;
        self.event(now, &format!("开始模拟预设：{preset}"));
        self.tick(now);
        Ok(json!({"accepted": true}))
    }
    fn play_waveform(&mut self, now: u64, id: &str) -> Result<Value, String> {
        if !self.authorized() {
            return Err("not_authorized".into());
        }
        let repeat = self.playback.as_ref().is_some_and(|p| p.repeat);
        if self.playback.is_some() && !repeat {
            return Err("busy".into());
        }
        let wave = self
            .waveforms
            .iter()
            .find(|w| w.id() == id)
            .ok_or("unknown_waveform")?
            .clone();
        let device = self.device.as_ref().unwrap();
        if wave.channels() > device.channels || wave.electrical() != (device.id == "sim_dglab") {
            return Err("waveform_capability_mismatch".into());
        }
        let ends = if repeat {
            self.deadline.unwrap()
        } else {
            now.checked_add(wave.duration()).ok_or("invalid_time")?
        };
        if ends > self.deadline.unwrap_or(0) {
            return Err("lease_too_short".into());
        }
        self.playback = Some(Playback {
            preset: id.into(),
            started: now,
            ends,
            waveform: Some(wave),
            repeat,
        });
        self.phase = Phase::Playing;
        self.event(now, "开始已导入波形（仅模拟）");
        self.tick(now);
        Ok(json!({"accepted":true}))
    }
    fn set_gain(&mut self, now: u64, gain: f64, from_ai: bool) -> Result<Value, String> {
        if !self.authorized() {
            return Err("not_authorized".into());
        }
        if !gain.is_finite() || !(0.0..=1.0).contains(&gain) {
            return Err("invalid_gain".into());
        }
        if from_ai && gain > self.gain_target {
            if gain - self.gain_target > 0.100_001 {
                return Err("ai_gain_step_too_large".into());
            }
            if self
                .last_ai_increase
                .is_some_and(|t| now.saturating_sub(t) < 1000)
            {
                return Err("ai_gain_rate_limited".into());
            }
            self.last_ai_increase = Some(now);
        }
        self.gain_target = gain;
        if gain < self.gain {
            self.gain = gain;
        }
        self.tick(now);
        self.event(
            now,
            if from_ai {
                "AI 调整相对强度，授权上限保持不变"
            } else {
                "用户调整相对强度"
            },
        );
        Ok(json!({"gain_target":gain}))
    }
    fn native_output(&self, now: u64) -> Value {
        let channels: Vec<_> = self.channels.iter().enumerate().map(|(index,c)| {
            let mut bytes = [20u8,20,20,20,0,0,0,0];
            let mut scale = 0.0;
            if self.authorized() && self.device.as_ref().is_some_and(|d|d.id=="sim_dglab") && c.enabled && !c.muted {
                if let Some(p) = c.playback.as_ref().or(self.playback.as_ref()) {
                    let duration = p.waveform.as_ref().map_or(patterns::period(&p.preset).unwrap_or(2400),|w|w.duration());
                    let elapsed = now.saturating_sub(p.started);
                    let point = if p.repeat {elapsed % duration} else {elapsed};
                    if let Some(w) = &p.waveform {
                        if let Some(block)=w.native_block(point,index) {bytes=block;}
                    } else {
                        for (i,byte) in bytes[4..].iter_mut().enumerate() {
                            let at=point+i as u64*25;
                            let level=if p.preset=="channel_hold" {1.0} else if p.repeat || at<duration {patterns::level(&p.preset,at % duration,index)} else {0.0};
                            *byte=(level*100.0).round() as u8;
                        }
                    }
                    let end=p.ends.min(self.deadline.unwrap()).min(c.until.unwrap_or(u64::MAX));
                    for (i,byte) in bytes[4..].iter_mut().enumerate(){if now.saturating_add(i as u64*25)>=end {*byte=0;}}
                    scale=self.limit*self.gain*c.limit*c.gain;
                }
            }
            json!({"frame":bytes.iter().map(|b|format!("{b:02X}")).collect::<String>(),"strength_scale":scale})
        }).collect();
        json!(channels)
    }
    fn snapshot(&self, now: u64) -> Value {
        json!({
        "simulation_only": true, "phase": self.phase, "device": self.device, "devices": devices(), "connected": self.connected,
        "epoch": self.epoch, "generation": self.generation, "limit": self.limit, "remaining_ms": self.deadline.map(|d| d.saturating_sub(now)).unwrap_or(0),
        "output": self.output, "dglab_output":self.native_output(now), "output_evidence": if self.phase == Phase::Unknown {"unknown"} else {"simulated"},
        "preset": self.playback.as_ref().map(|p| &p.preset), "fault": self.fault,
        "continuous": self.playback.as_ref().is_some_and(|p| p.repeat),
        "events": self.events, "samples": self.samples, "pending_ai": self.tickets.len(),
        "gain":self.gain,"gain_target":self.gain_target,"ai_control":self.ai_control,
        "waveforms":self.waveforms.iter().map(|w|w.summary()).collect::<Vec<_>>(),
        "presets": ["gentle_wave", "soft_pulse", "dual_alternate"], "pattern_catalog":patterns::catalog(),
        "channels":self.channels.iter().enumerate().map(|(i,c)|json!({
            "index":i,"enabled":c.enabled,"limit":c.limit,"gain":c.gain,"target":c.target,
            "muted":c.muted,"temporary_ms":c.until.map(|t|t.saturating_sub(now)),
            "pattern":c.playback.as_ref().map(|p|&p.preset),"playing":c.playback.is_some()
        })).collect::<Vec<_>>(), "core_version": env!("CARGO_PKG_VERSION") })
    }

    fn channel_actions(
        &mut self,
        now: u64,
        actions: Vec<ChannelAction>,
        ai: bool,
    ) -> Result<Value, String> {
        if !self.authorized() {
            return Err("not_authorized".into());
        }
        if actions.is_empty() || actions.len() > 8 {
            return Err("invalid_action_count".into());
        }
        // Validate against a copy. A rejected batch never partially changes output or policy.
        let mut candidate = self.clone();
        for action in &actions {
            candidate.channel_action(now, action, ai)?;
        }
        if !ai {
            candidate.tickets.clear();
            candidate.epoch += 1;
        }
        candidate.event(
            now,
            if ai {
                "AI 通道动作已通过校验"
            } else {
                "用户通道动作已通过校验"
            },
        );
        candidate.tick(now);
        *self = candidate;
        Ok(json!({"executed":actions}))
    }

    fn channel_action(&mut self, now: u64, action: &ChannelAction, ai: bool) -> Result<(), String> {
        let index = action.channel;
        if index >= self.device.as_ref().unwrap().channels || index >= 2 {
            return Err("invalid_channel".into());
        }
        if !self.channels[index].enabled && !matches!(action.command, ChannelCommand::Clear {}) {
            return Err("channel_disabled".into());
        }
        let remaining = self.deadline.unwrap().saturating_sub(now);
        let duration = |ms: u64| -> Result<u64, String> {
            if !(100..=20_000).contains(&ms) {
                return Err("invalid_duration".into());
            }
            if ms > remaining {
                return Err("lease_too_short".into());
            }
            Ok(now + ms)
        };
        let mut next = self.channels[index].clone();
        match &action.command {
            ChannelCommand::Clear {} => {
                next.playback = None;
                next.until = None;
                next.muted = true;
                next.target = 0.0;
                next.gain = 0.0;
            }
            ChannelCommand::Strength { value, .. } | ChannelCommand::Adjust { delta: value } => {
                let value = if matches!(action.command, ChannelCommand::Adjust { .. }) {
                    next.target + value
                } else {
                    *value
                };
                if !value.is_finite() || !(0.0..=1.0).contains(&value) {
                    return Err("invalid_gain".into());
                }
                if value > next.target {
                    if value - next.target > if ai { 0.100_001 } else { 0.200_001 } {
                        return Err("channel_step_too_large".into());
                    }
                    if ai
                        && next
                            .last_increase
                            .is_some_and(|t| now.saturating_sub(t) < 1000)
                    {
                        return Err("ai_gain_rate_limited".into());
                    }
                    next.last_increase = Some(now);
                }
                let temporary = match action.command {
                    ChannelCommand::Strength {
                        duration_ms: Some(ms),
                        ..
                    } => Some(duration(ms)?),
                    _ => None,
                };
                next.until = temporary;
                next.target = value;
                if value < next.gain {
                    next.gain = value;
                }
                next.muted = value == 0.0;
                if !next.muted && next.playback.is_none() && self.playback.is_none() {
                    next.playback = Some(Playback {
                        preset: "channel_hold".into(),
                        started: now,
                        ends: self.deadline.unwrap(),
                        waveform: None,
                        repeat: true,
                    });
                }
            }
            ChannelCommand::Pattern {
                preset_id,
                duration_ms,
                repeat,
            } => {
                if patterns::period(preset_id).is_none() {
                    return Err("unknown_preset".into());
                }
                let ends = duration(*duration_ms)?;
                next.playback = Some(Playback {
                    preset: preset_id.clone(),
                    started: now,
                    ends,
                    waveform: None,
                    repeat: *repeat,
                });
                next.muted = false;
            }
            ChannelCommand::Waveform {
                waveform_id,
                duration_ms,
                repeat,
            } => {
                let wave = self
                    .waveforms
                    .iter()
                    .find(|w| w.id() == waveform_id)
                    .ok_or("unknown_waveform")?
                    .clone();
                if wave.electrical() != (self.device.as_ref().unwrap().id == "sim_dglab") {
                    return Err("waveform_capability_mismatch".into());
                }
                if index >= wave.channels() {
                    return Err("capability_mismatch".into());
                }
                let ends = duration(*duration_ms)?;
                next.playback = Some(Playback {
                    preset: waveform_id.clone(),
                    started: now,
                    ends,
                    waveform: Some(wave),
                    repeat: *repeat,
                });
                next.muted = false;
            }
        }
        self.channels[index] = next;
        Ok(())
    }
    pub fn request(&mut self, now: u64, raw: &str) -> Value {
        self.tick(now);
        let result = if raw.len() > MAX_INPUT {
            Err("request_too_large".into())
        } else {
            serde_json::from_str::<Request>(raw)
                .map_err(|_| "invalid_request".into())
                .and_then(|r| self.handle(now, r))
        };
        match result {
            Ok(value) => json!({"ok": true, "result": value, "state": self.snapshot(now)}),
            Err(error) => {
                self.event(now, &format!("请求被拒绝：{error}"));
                json!({"ok": false, "error": error, "state": self.snapshot(now)})
            }
        }
    }
    fn handle(&mut self, now: u64, req: Request) -> Result<Value, String> {
        match req {
            Request::ExportPattern {
                preset_id,
                electrical,
            } => Ok(
                Waveform::parse(&patterns::waveform(&preset_id, electrical)?.to_string())?
                    .preview(),
            ),
            Request::ConfigureChannel {
                channel,
                enabled,
                limit,
            } => {
                if channel >= self.device.as_ref().map_or(2, |d| d.channels) || channel >= 2 {
                    return Err("invalid_channel".into());
                }
                if !limit.is_finite() || !(0.0..=1.0).contains(&limit) {
                    return Err("invalid_policy".into());
                }
                if self.phase == Phase::Unknown {
                    return Err("unknown_state_locked".into());
                }
                if self.authorized()
                    && ((enabled && !self.channels[channel].enabled)
                        || limit > self.channels[channel].limit)
                {
                    return Err("channel_policy_locked".into());
                }
                self.channels[channel].enabled = enabled;
                self.channels[channel].limit = limit;
                if !enabled {
                    self.channels[channel].playback = None;
                    self.channels[channel].muted = true;
                }
                self.tickets.clear();
                self.epoch += 1;
                self.tick(now);
                Ok(json!({}))
            }
            Request::ChannelActions { actions } => self.channel_actions(now, actions, false),
            Request::StartExperience {
                preset_id,
                waveform_id,
            } => {
                if self.playback.is_some() {
                    return Err("busy".into());
                }
                match (preset_id, waveform_id) {
                    (Some(id), None) => {
                        self.play(now, &id)?;
                    }
                    (None, Some(id)) => {
                        self.play_waveform(now, &id)?;
                    }
                    _ => return Err("choose_one_waveform".into()),
                }
                let playback = self.playback.as_mut().unwrap();
                playback.repeat = true;
                playback.ends = self.deadline.unwrap();
                self.tickets.clear();
                self.epoch += 1;
                self.event(now, "用户开始连续仿真体验；到授权期限自动停止");
                Ok(json!({"accepted":true}))
            }
            Request::Snapshot {} => Ok(json!({})),
            Request::ValidateWaveform { source } => Ok(Waveform::parse(&source)?.preview()),
            Request::ImportWaveform { source } => {
                if self.authorized() || self.phase == Phase::Unknown {
                    return Err("waveform_library_locked".into());
                }
                let wave = Waveform::parse(&source)?;
                if self.waveforms.iter().any(|w| w.id() == wave.id()) {
                    return Err("duplicate_waveform_id".into());
                }
                if self.waveforms.len() >= 24 {
                    return Err("waveform_library_full".into());
                }
                let summary = wave.summary();
                self.waveforms.push(Arc::new(wave));
                self.event(now, "已导入波形；导入不会授权或启动输出");
                Ok(summary)
            }
            Request::RemoveWaveform { waveform_id } => {
                if self.authorized() || self.phase == Phase::Unknown {
                    return Err("waveform_library_locked".into());
                }
                self.waveforms.retain(|w| w.id() != waveform_id);
                Ok(json!({}))
            }
            Request::PlayWaveform { waveform_id } => self.play_waveform(now, &waveform_id),
            Request::SetGain { gain } => {
                let result = self.set_gain(now, gain, false)?;
                self.tickets.clear();
                self.epoch += 1;
                Ok(result)
            }
            Request::SetAiControl { enabled } => {
                self.tickets.clear();
                self.epoch += 1;
                self.ai_control = enabled;
                self.event(
                    now,
                    if enabled {
                        "用户允许 AI 在授权范围内提议动作"
                    } else {
                        "AI 动作已禁用，待处理请求已撤销"
                    },
                );
                Ok(json!({}))
            }
            Request::ResetSimulation {} => {
                self.invalidate();
                self.generation += 1;
                self.device = None;
                self.connected = false;
                self.output = [0.0; 2];
                self.phase = Phase::Disconnected;
                self.fault = Fault::None;
                self.samples.clear();
                self.gain = 0.5;
                self.gain_target = 0.5;
                self.channels = [Channel::default(), Channel::default()];
                self.last_ai_increase = None;
                self.event(now, "模拟器已复位；此操作只影响虚拟输出");
                Ok(json!({}))
            }
            Request::Connect { device_id } => {
                if self.phase == Phase::Unknown {
                    return Err("output_unknown_restart_simulator_required".into());
                }
                if self.connected {
                    return Err("already_connected".into());
                }
                let device = devices()
                    .into_iter()
                    .find(|d| d.id == device_id)
                    .ok_or("unknown_device")?;
                self.invalidate();
                self.generation += 1;
                self.device = Some(device);
                self.connected = true;
                self.output = [0.0; 2];
                self.fault = Fault::None;
                self.phase = Phase::Ready;
                self.event(now, "模拟设备已连接");
                Ok(json!({}))
            }
            Request::Disconnect {} => {
                let hold =
                    self.fault == Fault::HoldOnDisconnect || self.fault == Fault::StopUnconfirmed;
                if !hold {
                    self.output = [0.0; 2];
                }
                self.connected = false;
                self.generation += 1;
                self.stop(now, "连接断开；失联行为按故障配置模拟");
                Ok(json!({}))
            }
            Request::AuthorizeSimulationSession { limit, lease_ms } => {
                if self.device.as_ref().map(|d| d.id) != Some("sim_single")
                    || !(2500..=180_000).contains(&lease_ms)
                {
                    return Err("simulation_session_only".into());
                }
                self.handle(
                    now,
                    Request::Authorize {
                        limit,
                        lease_ms: lease_ms.min(30_000),
                    },
                )?;
                self.deadline = Some(now.checked_add(lease_ms).ok_or("invalid_time")?);
                self.simulation_watchdog = Some(now + 2000);
                Ok(json!({"simulation_only":true,"lease_ms":lease_ms}))
            }
            Request::SimulationHeartbeat {} => {
                if self.simulation_watchdog.is_none() || !self.authorized() {
                    return Err("no_simulation_session".into());
                }
                self.simulation_watchdog = Some((now + 2000).min(self.deadline.unwrap()));
                Ok(json!({}))
            }
            Request::Authorize { limit, lease_ms } => {
                if !self.connected || !matches!(self.phase, Phase::Ready | Phase::Stopped) {
                    return Err("cannot_authorize".into());
                }
                if !limit.is_finite()
                    || !(0.0..=1.0).contains(&limit)
                    || !(2500..=30_000).contains(&lease_ms)
                {
                    return Err("invalid_policy".into());
                }
                self.invalidate();
                self.output = [0.0; 2];
                self.limit = limit;
                self.gain = 0.5;
                self.gain_target = 0.5;
                self.last_ai_increase = None;
                self.deadline = Some(now.checked_add(lease_ms).ok_or("invalid_time")?);
                for c in &mut self.channels {
                    let enabled = c.enabled;
                    let limit = c.limit;
                    *c = Channel::default();
                    c.enabled = enabled;
                    c.limit = limit;
                }
                self.phase = Phase::Authorized;
                self.event(now, "用户本地授权模拟会话");
                Ok(json!({}))
            }
            Request::Stop {} => {
                self.stop(now, "用户停止；旧请求已失效，需重新授权");
                Ok(json!({}))
            }
            Request::Play { preset_id } => self.play(now, &preset_id),
            Request::SetFault { fault } => {
                if self.device.as_ref().map(|d| d.id) != Some("sim_fault") {
                    return Err("not_fault_device".into());
                }
                if self.phase == Phase::Unknown {
                    return Err("unknown_state_locked".into());
                }
                self.fault = fault;
                self.event(now, "故障配置已更新");
                Ok(json!({}))
            }
            Request::BeginAi {} => {
                if !self.ai_control {
                    return Err("ai_control_disabled".into());
                }
                if !self.authorized() {
                    return Err("not_authorized".into());
                }
                if self.tickets.len() >= MAX_PENDING {
                    return Err("too_many_pending".into());
                }
                self.next_ticket = self.next_ticket.checked_add(1).ok_or("ticket_exhausted")?;
                self.tickets.insert(
                    self.next_ticket,
                    Ticket {
                        epoch: self.epoch,
                        generation: self.generation,
                        expires: (now + 20_000).min(self.deadline.unwrap()),
                    },
                );
                Ok(
                    json!({"ticket": self.next_ticket, "device_alias": self.device.as_ref().unwrap().id}),
                )
            }
            Request::CancelAi { ticket } => {
                self.tickets.remove(&ticket);
                Ok(json!({}))
            }
            Request::CompleteAi { ticket, response } => {
                let t = self
                    .tickets
                    .remove(&ticket)
                    .ok_or("stale_or_duplicate_ticket")?;
                if t.epoch != self.epoch
                    || t.generation != self.generation
                    || now >= t.expires
                    || !self.authorized()
                    || !self.ai_control
                {
                    return Err("stale_ticket".into());
                }
                if response.len() > 2048 {
                    return Err("intent_too_large".into());
                }
                match serde_json::from_str::<Intent>(&response).map_err(|_| "invalid_intent")? {
                    Intent::ChannelActions { actions } => self.channel_actions(now, actions, true),
                    Intent::PlayPreset {
                        device_alias,
                        preset_id,
                    } => {
                        if self.device.as_ref().map(|d| d.id) != Some(device_alias.as_str()) {
                            return Err("device_mismatch".into());
                        }
                        self.play(now, &preset_id)
                    }
                    Intent::Stop {} => {
                        self.stop(now, "模型请求停止；需用户重新授权");
                        Ok(json!({}))
                    }
                    Intent::Noop {} => Ok(json!({"accepted": false})),
                    Intent::PlayWaveform {
                        device_alias,
                        waveform_id,
                    } => {
                        if self.device.as_ref().map(|d| d.id) != Some(device_alias.as_str()) {
                            return Err("device_mismatch".into());
                        }
                        self.play_waveform(now, &waveform_id)
                    }
                    Intent::SetGain { gain } => self.set_gain(now, gain, true),
                }
            }
        }
    }
}

struct Runtime {
    engine: Mutex<Engine>,
    start: Instant,
}
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static WORKER: OnceLock<()> = OnceLock::new();
fn runtime() -> &'static Runtime {
    let r = RUNTIME.get_or_init(|| Runtime {
        engine: Mutex::new(Engine::new()),
        start: Instant::now(),
    });
    WORKER.get_or_init(|| {
        std::thread::spawn(|| loop {
            std::thread::sleep(Duration::from_millis(25));
            if let Some(r) = RUNTIME.get() {
                if let Ok(mut e) = r.engine.lock() {
                    e.tick(r.start.elapsed().as_millis() as u64);
                }
            }
        });
    });
    r
}

/// Executes one bounded JSON request.
///
/// # Safety
/// Input must be a valid NUL-terminated UTF-8 buffer owned by the caller.
/// Returned memory must be released exactly once with haptics_free.
#[no_mangle]
pub unsafe extern "C" fn haptics_request(input: *const c_char) -> *mut c_char {
    let value = std::panic::catch_unwind(|| {
        if input.is_null() {
            return json!({"ok":false,"error":"null_input"});
        }
        match CStr::from_ptr(input).to_str() {
            Ok(raw) => {
                let r = runtime();
                match r.engine.lock() {
                    Ok(mut e) => e.request(r.start.elapsed().as_millis() as u64, raw),
                    Err(_) => json!({"ok":false,"error":"core_unavailable"}),
                }
            }
            Err(_) => json!({"ok":false,"error":"invalid_utf8"}),
        }
    })
    .unwrap_or_else(|_| json!({"ok":false,"error":"core_panic"}));
    CString::new(value.to_string()).unwrap().into_raw()
}
/// Releases a response allocation.
///
/// # Safety
/// Pointer must be NULL or a live pointer returned by haptics_request, used once.
#[no_mangle]
pub unsafe extern "C" fn haptics_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
