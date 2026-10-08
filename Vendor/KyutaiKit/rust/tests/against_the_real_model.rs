//! Checks this crate against the reference implementation rather than against
//! itself. The expected values come from a run of kyutai's own `stt-rs` logic
//! driven through `moshi::asr::State` directly, using python `sentencepiece`
//! for detokenisation — so a disagreement here means either the hand-written
//! tokeniser parser or the framing is wrong.
//!
//! Skipped unless `PENDRAGON_STT_MODEL_DIR` points at a
//! `kyutai/stt-1b-en_fr-candle` checkout, because the weights are 2.36 GB and
//! do not belong in CI by default.

use pendragon_stt::Transcriber;

const FIXTURE: &str = "../../PendragonTests/Fixtures/speech-with-pause-24k.wav";
const EXPECTED: &str = "Pendragon runs entirely on device. That is the whole point of it.";

fn model_dir() -> Option<String> {
    std::env::var("PENDRAGON_STT_MODEL_DIR").ok().filter(|d| !d.is_empty())
}

/// Minimal reader for the one fixture: 16-bit PCM, mono, 24 kHz.
fn read_fixture() -> Vec<f32> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(FIXTURE);
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let channels = u16::from_le_bytes([bytes[22], bytes[23]]);
    let sample_rate = u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]);
    assert_eq!(channels, 1, "fixture must be mono");
    assert_eq!(sample_rate, 24_000, "fixture must already be at Mimi's rate");
    // Locate the data chunk rather than assuming it starts at 44: afconvert
    // writes a LIST chunk ahead of it.
    let mut pos = 12;
    loop {
        let id = &bytes[pos..pos + 4];
        let size = u32::from_le_bytes([bytes[pos + 4], bytes[pos + 5], bytes[pos + 6], bytes[pos + 7]])
            as usize;
        if id == b"data" {
            let start = pos + 8;
            return bytes[start..start + size]
                .chunks_exact(2)
                .map(|s| i16::from_le_bytes([s[0], s[1]]) as f32 / 32768.0)
                .collect();
        }
        pos += 8 + size + (size & 1);
    }
}

#[test]
fn transcribes_the_fixture_as_the_reference_does() {
    let Some(dir) = model_dir() else {
        eprintln!("skipped: set PENDRAGON_STT_MODEL_DIR to run");
        return;
    };
    let mut transcriber = Transcriber::open(&dir).expect("model failed to load");
    let samples = read_fixture();

    // Pushed at the audio tap's buffer size, not Mimi's, so the framing is
    // exercised the way the app will exercise it.
    let mut text = String::new();
    for chunk in samples.chunks(4096) {
        text.push_str(&transcriber.push(chunk).expect("push failed"));
    }
    text.push_str(&transcriber.flush().expect("flush failed"));

    assert_eq!(text.trim(), EXPECTED);
}

/// The heads must rise during the pause and recover afterwards. If they were
/// collapsed to a boolean somewhere in the C ABI this would still pass on the
/// rise and fail on the recovery, which is the half that full duplex needs.
#[test]
fn the_voice_activity_heads_rise_in_the_pause_and_recover() {
    let Some(dir) = model_dir() else {
        eprintln!("skipped: set PENDRAGON_STT_MODEL_DIR to run");
        return;
    };
    let mut transcriber = Transcriber::open(&dir).expect("model failed to load");
    let samples = read_fixture();

    assert_eq!(transcriber.vad().len(), 4, "the 1B checkpoint has four heads");

    // One frame at a time, so each reading lines up with a known instant.
    let mut trace: Vec<(f64, Vec<f32>)> = Vec::new();
    for (index, chunk) in samples.chunks(1920).enumerate() {
        transcriber.push(chunk).expect("push failed");
        trace.push((index as f64 * 0.08, transcriber.vad().to_vec()));
    }

    let at = |t: f64| -> Vec<f32> {
        trace.iter().min_by(|a, b| {
            (a.0 - t).abs().partial_cmp(&(b.0 - t).abs()).expect("times are comparable")
        }).expect("trace is not empty").1.clone()
    };

    // The fixture is: speech to 2.23 s, silence to 3.73 s, speech to 5.05 s,
    // silence to the end.
    //
    // Mid-utterance every horizon should be confident there is voice.
    assert!(at(1.5)[0] < 0.1, "head 0 claimed silence mid-utterance: {:?}", at(1.5));
    assert!(at(1.5)[3] < 0.1, "head 3 claimed silence mid-utterance: {:?}", at(1.5));

    // Deep in the pause, every horizon is confident.
    let pause = at(3.4);
    assert!(pause[0] > 0.9, "head 0 missed the pause: {pause:?}");
    assert!(pause[1] > 0.9, "head 1 missed the pause: {pause:?}");

    // The nearest horizon must commit before the furthest one: that ordering is
    // the whole reason four heads exist rather than one.
    let first_above = |head: usize| {
        trace.iter().find(|(_, p)| p[head] > 0.5).map(|(t, _)| *t)
    };
    let (h0, h3) = (first_above(0), first_above(3));
    assert!(h0.is_some() && h3.is_some(), "a head never crossed 0.5: {h0:?} {h3:?}");
    assert!(h0.unwrap() < h3.unwrap(), "0.5 s horizon fired no earlier than the 3 s one");

    // And they come back down when the speaker resumes.
    let resumed = at(4.4);
    assert!(resumed[0] < 0.1, "head 0 stayed high after speech resumed: {resumed:?}");

    // The property full duplex is actually built on. Speech resumes at 3.73 s,
    // and the far horizons abandon the pause while the near ones are still
    // pinned high — the model is predicting the next utterance rather than
    // reporting the current silence. A boolean "has finished speaking" throws
    // exactly this away, which is why the C ABI hands over all four.
    let anticipating = at(3.8);
    assert!(
        anticipating[2] < 0.1 && anticipating[3] < 0.1,
        "the far horizons did not anticipate speech resuming: {anticipating:?}"
    );
    assert!(
        anticipating[0] > 0.9,
        "the near horizon should still read silence at this instant: {anticipating:?}"
    );
}

/// Reset must return the model to a state where a second utterance transcribes
/// as if it were the first — a conversation is many recordings, not one.
#[test]
fn reset_makes_the_next_recording_independent() {
    let Some(dir) = model_dir() else {
        eprintln!("skipped: set PENDRAGON_STT_MODEL_DIR to run");
        return;
    };
    let mut transcriber = Transcriber::open(&dir).expect("model failed to load");
    let samples = read_fixture();

    let mut run = |t: &mut Transcriber| {
        let mut text = String::new();
        for chunk in samples.chunks(4096) {
            text.push_str(&t.push(chunk).expect("push failed"));
        }
        text.push_str(&t.flush().expect("flush failed"));
        text.trim().to_string()
    };

    let first = run(&mut transcriber);
    transcriber.reset().expect("reset failed");
    let second = run(&mut transcriber);
    assert_eq!(first, second);
    assert_eq!(second, EXPECTED);
}
