// Kyutai STT for Pendragon. Implemented in Rust; see KyutaiKit/rust.
//
// The shape of this interface is the point. Everything Kyutai-specific —
// Mimi's 80 ms framing, the half-second delay line, token ids, SentencePiece —
// stays behind it, because none of those are decisions Pendragon makes. What
// crosses is: push samples, receive text and four probabilities.

#ifndef PENDRAGON_STT_H
#define PENDRAGON_STT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct pdg_stt pdg_stt;

/// The rate samples must be at before being pushed. Mimi's codec rate, which is
/// *not* the 16 kHz the attachment path resamples to for Gemma's audio tower.
uint32_t pdg_stt_sample_rate(void);

/// Loads a model directory holding config.json, model.safetensors, the Mimi
/// codec and the tokeniser named by that config.
///
/// Returns NULL on failure, writing the reason into `err`. The commonest
/// failure is a checkpoint without voice-activity heads: `kyutai/stt-1b-en_fr`,
/// its `-mlx` sibling and `stt-2.6b-en-candle` all ship without them and are
/// rejected here rather than transcribing without ever ending a turn.
pdg_stt *pdg_stt_open(const char *model_dir, char *err, size_t err_cap);

void pdg_stt_close(pdg_stt *transcriber);

/// How many voice-activity heads this checkpoint carries, so callers size their
/// buffer rather than hardcoding it. Four for `kyutai/stt-1b-en_fr-candle`.
size_t pdg_stt_vad_head_count(const pdg_stt *transcriber);

/// Pushes `count` mono samples at `pdg_stt_sample_rate()`. Any count: frames
/// are accumulated internally, so the caller may pass whatever its audio tap
/// hands it.
///
/// Text completed as a result is written to `text` — usually nothing, since a
/// word is only emitted once the model has heard past it.
///
/// `vad` receives the latest estimate that *no* voice will occur within
/// 0.5 s, 1 s, 2 s and 3 s, in that order. Index 0 is the earliest end-of-turn
/// signal; the later horizons fall before the earlier ones when the speaker is
/// about to resume, which is what makes interruption detectable.
///
/// Returns 0, or -1 with the reason written into `text`.
int32_t pdg_stt_push(pdg_stt *transcriber,
                     const float *pcm, size_t count,
                     char *text, size_t text_cap,
                     float *vad, size_t vad_cap);

/// Ends the stream, running silence through the delay line so the last words
/// spoken are emitted. Returns 0, or -1 with the reason written into `text`.
int32_t pdg_stt_flush(pdg_stt *transcriber, char *text, size_t text_cap);

/// Returns the model to its initial state for a fresh recording.
int32_t pdg_stt_reset(pdg_stt *transcriber);

#ifdef __cplusplus
}
#endif

#endif // PENDRAGON_STT_H
