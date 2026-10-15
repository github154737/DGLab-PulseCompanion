use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

pub const MAX_WAVEFORM_BYTES: usize = 32_768;

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Frame {
    pub duration_ms: u64,
    pub levels: [f64; 2],
}

/// Device-native pulse data is kept separate from a motor amplitude envelope.
#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "format", deny_unknown_fields)]
pub enum Waveform {
    #[serde(rename = "envelope_v1")]
    Envelope {
        id: String,
        name: String,
        channels: usize,
        frames: Vec<Frame>,
    },
    #[serde(rename = "dglab_v3")]
    Dglab {
        id: String,
        name: String,
        a: Vec<String>,
        b: Vec<String>,
    },
}

impl Waveform {
    pub fn parse(source: &str) -> Result<Self, String> {
        if source.len() > MAX_WAVEFORM_BYTES {
            return Err("waveform_too_large".into());
        }
        let wave: Self = serde_json::from_str(source).map_err(|_| "invalid_waveform_json")?;
        let id = wave.id();
        if id.is_empty()
            || id.len() > 48
            || !id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
            || ["gentle_wave", "soft_pulse", "dual_alternate"].contains(&id)
        {
            return Err("invalid_waveform_id".into());
        }
        if wave.name().trim().is_empty()
            || wave.name().chars().count() > 60
            || wave.name().chars().any(char::is_control)
        {
            return Err("invalid_waveform_name".into());
        }
        match &wave {
            Self::Envelope {
                channels, frames, ..
            } => {
                if !(1..=2).contains(channels) || frames.is_empty() || frames.len() > 1000 {
                    return Err("invalid_waveform_frames".into());
                }
                for f in frames {
                    if !(25..=2000).contains(&f.duration_ms)
                        || f.levels
                            .iter()
                            .any(|v| !v.is_finite() || !(0.0..=1.0).contains(v))
                        || (*channels == 1 && f.levels[1] != 0.0)
                    {
                        return Err("invalid_envelope_frame".into());
                    }
                }
            }
            Self::Dglab { a, b, .. } => {
                if a.is_empty() || a.len() > 200 || (!b.is_empty() && b.len() != a.len()) {
                    return Err("invalid_waveform_frames".into());
                }
                for block in a.iter().chain(b) {
                    Self::decode_block(block)?;
                }
            }
        }
        if !(100..=20_000).contains(&wave.duration()) {
            return Err("invalid_waveform_duration".into());
        }
        Ok(wave)
    }
    pub fn decode_block(block: &str) -> Result<[u8; 8], String> {
        if block.len() != 16 || !block.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err("invalid_dglab_block".into());
        }
        let mut bytes = [0; 8];
        for (i, byte) in bytes.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&block[i * 2..i * 2 + 2], 16)
                .map_err(|_| "invalid_dglab_block")?;
        }
        if bytes[..4].iter().any(|v| !(10..=240).contains(v)) || bytes[4..].iter().any(|v| *v > 100)
        {
            return Err("invalid_dglab_range".into());
        }
        Ok(bytes)
    }
    pub fn id(&self) -> &str {
        match self {
            Self::Envelope { id, .. } | Self::Dglab { id, .. } => id,
        }
    }
    pub fn name(&self) -> &str {
        match self {
            Self::Envelope { name, .. } | Self::Dglab { name, .. } => name,
        }
    }
    pub fn channels(&self) -> usize {
        match self {
            Self::Envelope { channels, .. } => *channels,
            Self::Dglab { b, .. } => {
                if b.is_empty() {
                    1
                } else {
                    2
                }
            }
        }
    }
    pub fn electrical(&self) -> bool {
        matches!(self, Self::Dglab { .. })
    }
    pub fn native_block(&self, elapsed: u64, channel: usize) -> Option<[u8; 8]> {
        match self {
            Self::Dglab { a, b, .. } => {
                let frames = if channel == 0 { a } else { b };
                frames
                    .get((elapsed / 100) as usize)
                    .and_then(|s| Self::decode_block(s).ok())
            }
            _ => None,
        }
    }
    pub fn duration(&self) -> u64 {
        match self {
            Self::Envelope { frames, .. } => frames.iter().map(|f| f.duration_ms).sum(),
            Self::Dglab { a, .. } => a.len() as u64 * 100,
        }
    }
    pub fn levels(&self, elapsed: u64) -> [f64; 2] {
        if elapsed >= self.duration() {
            return [0.0; 2];
        }
        match self {
            Self::Envelope { frames, .. } => {
                let mut end = 0;
                for f in frames {
                    end += f.duration_ms;
                    if elapsed < end {
                        return f.levels;
                    }
                }
                [0.0; 2]
            }
            Self::Dglab { a, b, .. } => {
                let index = (elapsed / 100) as usize;
                let point = (elapsed % 100 / 25) as usize + 4;
                [
                    Self::decode_block(&a[index]).unwrap()[point] as f64 / 100.0,
                    if b.is_empty() {
                        0.0
                    } else {
                        Self::decode_block(&b[index]).unwrap()[point] as f64 / 100.0
                    },
                ]
            }
        }
    }
    pub fn summary(&self) -> Value {
        json!({"id":self.id(),"name":self.name(),"channels":self.channels(),"duration_ms":self.duration(),
            "format":if self.electrical(){"dglab_v3"}else{"envelope_v1"},
            "preview_only":self.electrical()})
    }
    pub fn preview(&self) -> Value {
        let duration = self.duration();
        let step = (duration / 160).max(25);
        let points: Vec<_> = (0..duration)
            .step_by(step as usize)
            .map(|t| json!({"at_ms":t,"values":self.levels(t)}))
            .collect();
        json!({"waveform":self.summary(),"samples":points,"canonical":self})
    }
}
