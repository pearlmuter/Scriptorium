//! Kyutai STT behind a C ABI, for Pendragon's Swift side.
//!
//! What crosses the boundary is deliberately small: push samples, receive text
//! and four probabilities. Mimi's framing, the half-second delay line, token
//! ids and detokenisation all stay on this side, because none of them are
//! decisions the application makes.
//!
//! The four probabilities are the reason this crate exists at all. Each is the
//! model's estimate that no voice will occur within a horizon — 0.5 s, 1 s,
//! 2 s and 3 s. They are handed over as four numbers rather than as a
//! "finished speaking" boolean because full duplex needs to distinguish a
//! breath from the end of a turn, and a boolean has already thrown that away.

mod sentencepiece;

use sentencepiece::Vocabulary;
use std::ffi::{c_char, CStr};

/// Mimi's codec rate. The caller resamples to this before pushing; it is
/// exposed through `pdg_stt_sample_rate` so the figure lives in one place.
pub const SAMPLE_RATE: u32 = 24_000;
/// One Mimi frame: 12.5 Hz over 24 kHz audio, so 80 ms.
const FRAME_SAMPLES: usize = 1920;
/// Frames the model is stepped through on `flush` to drain its delay line,
/// derived from the checkpoint's own `audio_delay_seconds` plus a margin.
const FLUSH_MARGIN_FRAMES: usize = 12;

/// Accumulates arbitrary-length pushes into whole Mimi frames.
///
/// Callers get their samples from an audio tap, whose buffer size has nothing
/// to do with Mimi's. Rather than make every caller carry a remainder, the
/// remainder lives here.
struct FrameBuffer {
    pending: Vec<f32>,
}

impl FrameBuffer {
    fn new() -> Self {
        Self { pending: Vec::with_capacity(FRAME_SAMPLES * 2) }
    }

    /// Appends `samples` and returns the whole frames now available, leaving
    /// any partial frame behind for the next call.
    fn push(&mut self, samples: &[f32]) -> Vec<Vec<f32>> {
        self.pending.extend_from_slice(samples);
        let count = self.pending.len() / FRAME_SAMPLES;
        let mut frames = Vec::with_capacity(count);
        for _ in 0..count {
            frames.push(self.pending.drain(..FRAME_SAMPLES).collect());
        }
        frames
    }

    /// Pads whatever is left up to a whole frame, for end of stream. Returns
    /// nothing when there is nothing pending, so flushing twice is harmless.
    fn drain_padded(&mut self) -> Option<Vec<f32>> {
        if self.pending.is_empty() {
            return None;
        }
        let mut frame: Vec<f32> = self.pending.drain(..).collect();
        frame.resize(FRAME_SAMPLES, 0.0);
        Some(frame)
    }

    fn clear(&mut self) {
        self.pending.clear();
    }
}

#[derive(Debug, serde::Deserialize)]
struct SttConfig {
    audio_delay_seconds: f64,
}

#[derive(Debug, serde::Deserialize)]
struct Config {
    mimi_name: String,
    tokenizer_name: String,
    card: usize,
    text_card: usize,
    dim: usize,
    n_q: usize,
    context: usize,
    max_period: f64,
    num_heads: usize,
    num_layers: usize,
    causal: bool,
    stt_config: SttConfig,
    /// Absent in `kyutai/stt-1b-en_fr`, `-mlx` and `stt-2.6b-en-candle`, all of
    /// which ship without the voice-activity heads. Required here, so a
    /// checkpoint that cannot do the job fails at load rather than
    /// transcribing silently and never ending a turn.
    extra_heads_num_heads: usize,
    extra_heads_dim: usize,
}

impl Config {
    fn model_config(&self) -> moshi::lm::Config {
        moshi::lm::Config {
            transformer: moshi::transformer::Config {
                d_model: self.dim,
                num_heads: self.num_heads,
                num_layers: self.num_layers,
                dim_feedforward: self.dim * 4,
                causal: self.causal,
                norm_first: true,
                bias_ff: false,
                bias_attn: false,
                layer_scale: None,
                context: self.context,
                max_period: self.max_period as usize,
                use_conv_block: false,
                use_conv_bias: true,
                cross_attention: None,
                gating: Some(candle_nn::Activation::Silu),
                norm: moshi::NormType::RmsNorm,
                positional_embedding: moshi::transformer::PositionalEmbedding::Rope,
                conv_layout: false,
                conv_kernel_size: 3,
                kv_repeat: 1,
                max_seq_len: 4096 * 4,
                shared_cross_attn: false,
            },
            depformer: None,
            audio_vocab_size: self.card + 1,
            text_in_vocab_size: self.text_card + 1,
            text_out_vocab_size: self.text_card,
            audio_codebooks: self.n_q,
            conditioners: Default::default(),
            extra_heads: Some(moshi::lm::ExtraHeadsConfig {
                num_heads: self.extra_heads_num_heads,
                dim: self.extra_heads_dim,
            }),
        }
    }
}

pub struct Transcriber {
    state: moshi::asr::State,
    vocab: Vocabulary,
    frames: FrameBuffer,
    device: candle::Device,
    vad_heads: usize,
    /// The most recent reading, kept so a caller polling less often than the
    /// model steps still sees the latest estimate rather than nothing.
    last_vad: Vec<f32>,
}

impl Transcriber {
    pub fn open(model_dir: &str) -> Result<Self, String> {
        let config_path = format!("{model_dir}/config.json");
        let config: Config = serde_json::from_str(
            &std::fs::read_to_string(&config_path).map_err(|e| format!("{config_path}: {e}"))?,
        )
        .map_err(|e| {
            format!(
                "{config_path}: {e} — a checkpoint without extra_heads cannot \
                 detect end of turn; use kyutai/stt-1b-en_fr-candle"
            )
        })?;

        let device = if candle::utils::metal_is_available() {
            candle::Device::new_metal(0).map_err(|e| e.to_string())?
        } else {
            candle::Device::Cpu
        };

        let dtype = device.bf16_default_to_f32();
        let weights = format!("{model_dir}/model.safetensors");
        let vb = unsafe {
            candle_nn::VarBuilder::from_mmaped_safetensors(&[&weights], dtype, &device)
                .map_err(|e| format!("{weights}: {e}"))?
        };
        let lm = moshi::lm::LmModel::new(
            &config.model_config(),
            moshi::nn::MaybeQuantizedVarBuilder::Real(vb),
        )
        .map_err(|e| format!("{weights}: {e}"))?;

        let mimi_path = format!("{model_dir}/{}", config.mimi_name);
        let mimi = moshi::mimi::load(&mimi_path, Some(config.n_q), &device)
            .map_err(|e| format!("{mimi_path}: {e}"))?;

        let tokenizer_path = format!("{model_dir}/{}", config.tokenizer_name);
        let vocab = Vocabulary::load(&tokenizer_path)?;
        // A tokeniser from a different checkpoint would still parse, and would
        // then silently transcribe into the wrong words. Sizes disagreeing is
        // the cheapest way to notice.
        if vocab.len() < config.text_card {
            return Err(format!(
                "{tokenizer_path}: holds {} pieces but the model emits {} text tokens \
                 — tokeniser and weights are from different checkpoints",
                vocab.len(),
                config.text_card
            ));
        }

        let delay_in_tokens = (config.stt_config.audio_delay_seconds * 12.5) as usize;
        let state = moshi::asr::State::new(1, delay_in_tokens, 0., mimi, lm)
            .map_err(|e| e.to_string())?;

        let vad_heads = config.extra_heads_num_heads;
        Ok(Self {
            state,
            vocab,
            frames: FrameBuffer::new(),
            device,
            vad_heads,
            last_vad: vec![0.0; vad_heads],
        })
    }

    /// Steps the model through one whole frame, appending any completed words.
    fn step(&mut self, frame: &[f32], text: &mut String) -> Result<(), String> {
        let tensor = candle::Tensor::new(frame, &self.device)
            .and_then(|t| t.reshape((1, 1, ())))
            .map_err(|e| e.to_string())?;
        let messages = self
            .state
            .step_pcm(tensor, None, &().into(), |_, _, _| ())
            .map_err(|e| e.to_string())?;
        for message in messages.iter() {
            match message {
                moshi::asr::AsrMsg::Step { prs, .. } => {
                    // `prs[head]` is a per-batch vector and the batch is one.
                    for (head, p) in prs.iter().enumerate().take(self.vad_heads) {
                        if let Some(slot) = self.last_vad.get_mut(head) {
                            *slot = p.first().copied().unwrap_or(0.0);
                        }
                    }
                }
                moshi::asr::AsrMsg::Word { tokens, .. } => {
                    text.push_str(&self.vocab.decode(tokens));
                }
                moshi::asr::AsrMsg::EndWord { .. } => {}
            }
        }
        Ok(())
    }

    /// Pushes samples and returns whatever text completed as a result. Most
    /// pushes return nothing: a word is only emitted once the model has heard
    /// past it.
    pub fn push(&mut self, samples: &[f32]) -> Result<String, String> {
        let mut text = String::new();
        for frame in self.frames.push(samples) {
            self.step(&frame, &mut text)?;
        }
        Ok(text)
    }

    /// Ends the stream: pads the partial frame and runs silence through the
    /// delay line so the last words spoken are actually emitted.
    pub fn flush(&mut self) -> Result<String, String> {
        let mut text = String::new();
        if let Some(frame) = self.frames.drain_padded() {
            self.step(&frame, &mut text)?;
        }
        let silence = vec![0.0f32; FRAME_SAMPLES];
        for _ in 0..FLUSH_MARGIN_FRAMES {
            self.step(&silence, &mut text)?;
        }
        Ok(text)
    }

    pub fn vad(&self) -> &[f32] {
        &self.last_vad
    }

    pub fn reset(&mut self) -> Result<(), String> {
        self.frames.clear();
        self.last_vad.iter_mut().for_each(|p| *p = 0.0);
        self.state.reset().map_err(|e| e.to_string())
    }
}

// MARK: - C ABI

/// Writes `message` into `buffer` as a NUL-terminated string, truncating on a
/// character boundary so the result is always valid UTF-8.
fn write_cstr(message: &str, buffer: *mut c_char, capacity: usize) {
    if buffer.is_null() || capacity == 0 {
        return;
    }
    let mut end = message.len().min(capacity - 1);
    while end > 0 && !message.is_char_boundary(end) {
        end -= 1;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(message.as_ptr(), buffer as *mut u8, end);
        *buffer.add(end) = 0;
    }
}

#[no_mangle]
pub extern "C" fn pdg_stt_sample_rate() -> u32 {
    SAMPLE_RATE
}

#[no_mangle]
pub extern "C" fn pdg_stt_open(
    model_dir: *const c_char,
    err: *mut c_char,
    err_cap: usize,
) -> *mut Transcriber {
    if model_dir.is_null() {
        write_cstr("model directory was null", err, err_cap);
        return std::ptr::null_mut();
    }
    let dir = match unsafe { CStr::from_ptr(model_dir) }.to_str() {
        Ok(dir) => dir,
        Err(e) => {
            write_cstr(&format!("model directory was not UTF-8: {e}"), err, err_cap);
            return std::ptr::null_mut();
        }
    };
    match Transcriber::open(dir) {
        Ok(transcriber) => Box::into_raw(Box::new(transcriber)),
        Err(message) => {
            write_cstr(&message, err, err_cap);
            std::ptr::null_mut()
        }
    }
}

#[no_mangle]
pub extern "C" fn pdg_stt_close(handle: *mut Transcriber) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle) });
    }
}

/// Number of voice-activity heads, so the caller need not hardcode four.
#[no_mangle]
pub extern "C" fn pdg_stt_vad_head_count(handle: *const Transcriber) -> usize {
    match unsafe { handle.as_ref() } {
        Some(transcriber) => transcriber.vad_heads,
        None => 0,
    }
}

/// Pushes `count` mono samples at `pdg_stt_sample_rate()`.
///
/// Newly completed text is written to `text`; the latest voice-activity
/// probabilities are written to `vad`. Returns 0 on success and -1 on failure,
/// in which case `text` holds the reason.
#[no_mangle]
pub extern "C" fn pdg_stt_push(
    handle: *mut Transcriber,
    pcm: *const f32,
    count: usize,
    text: *mut c_char,
    text_cap: usize,
    vad: *mut f32,
    vad_cap: usize,
) -> i32 {
    let Some(transcriber) = (unsafe { handle.as_mut() }) else {
        write_cstr("transcriber handle was null", text, text_cap);
        return -1;
    };
    // A null pointer with a zero count is an empty push, not an error: it is
    // how a caller polls the voice-activity heads without new audio.
    let samples = if count == 0 || pcm.is_null() {
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(pcm, count) }
    };
    match transcriber.push(samples) {
        Ok(produced) => {
            write_cstr(&produced, text, text_cap);
            if !vad.is_null() {
                let n = vad_cap.min(transcriber.last_vad.len());
                unsafe { std::ptr::copy_nonoverlapping(transcriber.last_vad.as_ptr(), vad, n) };
            }
            0
        }
        Err(message) => {
            write_cstr(&message, text, text_cap);
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn pdg_stt_flush(handle: *mut Transcriber, text: *mut c_char, text_cap: usize) -> i32 {
    let Some(transcriber) = (unsafe { handle.as_mut() }) else {
        write_cstr("transcriber handle was null", text, text_cap);
        return -1;
    };
    match transcriber.flush() {
        Ok(produced) => {
            write_cstr(&produced, text, text_cap);
            0
        }
        Err(message) => {
            write_cstr(&message, text, text_cap);
            -1
        }
    }
}

#[no_mangle]
pub extern "C" fn pdg_stt_reset(handle: *mut Transcriber) -> i32 {
    match unsafe { handle.as_mut() } {
        Some(transcriber) => match transcriber.reset() {
            Ok(()) => 0,
            Err(_) => -1,
        },
        None => -1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_are_whole_and_the_remainder_is_kept() {
        let mut buffer = FrameBuffer::new();
        assert!(buffer.push(&vec![1.0; FRAME_SAMPLES - 1]).is_empty());
        let frames = buffer.push(&[2.0]);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].len(), FRAME_SAMPLES);
        assert_eq!(frames[0][FRAME_SAMPLES - 1], 2.0);
    }

    #[test]
    fn one_push_can_yield_several_frames() {
        let mut buffer = FrameBuffer::new();
        let frames = buffer.push(&vec![0.5; FRAME_SAMPLES * 3 + 7]);
        assert_eq!(frames.len(), 3);
        // The 7 left over are still pending, not lost.
        assert_eq!(buffer.push(&vec![0.5; FRAME_SAMPLES - 7]).len(), 1);
    }

    /// The audio tap hands over 4096 samples at a time and Mimi wants 1920, so
    /// the two never line up. Samples must survive the mismatch exactly.
    #[test]
    fn a_tap_sized_stream_loses_no_samples() {
        let mut buffer = FrameBuffer::new();
        let mut emitted = 0;
        for chunk in 0..50 {
            let samples: Vec<f32> = (0..4096).map(|i| (chunk * 4096 + i) as f32).collect();
            for frame in buffer.push(&samples) {
                assert_eq!(frame.len(), FRAME_SAMPLES);
                for (i, sample) in frame.iter().enumerate() {
                    assert_eq!(*sample, (emitted * FRAME_SAMPLES + i) as f32);
                }
                emitted += 1;
            }
        }
        assert_eq!(emitted, 50 * 4096 / FRAME_SAMPLES);
    }

    #[test]
    fn flushing_pads_the_partial_frame() {
        let mut buffer = FrameBuffer::new();
        buffer.push(&vec![1.0; 100]);
        let frame = buffer.drain_padded().expect("a partial frame was pending");
        assert_eq!(frame.len(), FRAME_SAMPLES);
        assert_eq!(frame[99], 1.0);
        assert_eq!(frame[100], 0.0);
        assert!(buffer.drain_padded().is_none(), "flushing twice must be harmless");
    }

    #[test]
    fn flushing_an_empty_buffer_yields_nothing() {
        assert!(FrameBuffer::new().drain_padded().is_none());
    }

    #[test]
    fn truncation_stops_on_a_character_boundary() {
        let mut buffer = vec![0i8; 6];
        // Four bytes of two-byte characters, into five usable bytes.
        write_cstr("ééé", buffer.as_mut_ptr(), buffer.len());
        let text = unsafe { CStr::from_ptr(buffer.as_ptr()) }.to_str();
        assert_eq!(text.expect("truncation produced invalid UTF-8"), "éé");
    }

    #[test]
    fn writing_to_a_null_or_empty_buffer_is_a_no_op() {
        write_cstr("anything", std::ptr::null_mut(), 16);
        let mut buffer = vec![9i8; 1];
        write_cstr("anything", buffer.as_mut_ptr(), 0);
        assert_eq!(buffer[0], 9);
    }

    #[test]
    fn a_null_handle_is_reported_rather_than_crashing() {
        let mut text = vec![0i8; 128];
        let code = pdg_stt_push(
            std::ptr::null_mut(),
            std::ptr::null(),
            0,
            text.as_mut_ptr(),
            text.len(),
            std::ptr::null_mut(),
            0,
        );
        assert_eq!(code, -1);
        assert_eq!(pdg_stt_reset(std::ptr::null_mut()), -1);
        assert_eq!(pdg_stt_vad_head_count(std::ptr::null()), 0);
    }

    #[test]
    fn sample_rate_is_mimis_not_the_capture_paths() {
        // 16 kHz is what Gemma's attachment path wants; pushing that here would
        // play every recording back at two-thirds speed.
        assert_eq!(pdg_stt_sample_rate(), 24_000);
    }
}
