//! Dumps the voice-activity heads frame by frame, for calibrating what the app
//! should treat as end of turn.
//!
//!   cargo run --release --features metal --example vad_trace -- <model_dir> <wav>
//!
//! Time is counted from frames pushed, not from `moshi`'s `model_step_idx`:
//! that counter survives `State::reset`, so anything derived from it is offset
//! by however many frames were pushed before the reset.

use pendragon_stt::Transcriber;

fn read_wav_24k(path: &str) -> Vec<f32> {
    let bytes = std::fs::read(path).expect("wav");
    assert_eq!(u16::from_le_bytes([bytes[22], bytes[23]]), 1, "mono only");
    assert_eq!(
        u32::from_le_bytes([bytes[24], bytes[25], bytes[26], bytes[27]]),
        24_000,
        "24 kHz only"
    );
    let mut pos = 12;
    loop {
        let id = &bytes[pos..pos + 4];
        let size =
            u32::from_le_bytes([bytes[pos + 4], bytes[pos + 5], bytes[pos + 6], bytes[pos + 7]])
                as usize;
        if id == b"data" {
            return bytes[pos + 8..pos + 8 + size]
                .chunks_exact(2)
                .map(|s| i16::from_le_bytes([s[0], s[1]]) as f32 / 32768.0)
                .collect();
        }
        pos += 8 + size + (size & 1);
    }
}

fn main() {
    let mut args = std::env::args().skip(1);
    let dir = args.next().expect("usage: vad_trace <model_dir> <wav>");
    let wav = args.next().expect("usage: vad_trace <model_dir> <wav>");

    let mut transcriber = Transcriber::open(&dir).expect("model");
    let samples = read_wav_24k(&wav);
    println!("audio: {:.2} s", samples.len() as f64 / 24_000.0);

    let mut trace: Vec<(f64, Vec<f32>)> = Vec::new();
    let mut text = String::new();
    for (index, chunk) in samples.chunks(1920).enumerate() {
        text.push_str(&transcriber.push(chunk).expect("push"));
        trace.push((index as f64 * 0.08, transcriber.vad().to_vec()));
    }
    text.push_str(&transcriber.flush().expect("flush"));
    println!("transcript: {}", text.trim());

    println!("\n time     0.5s     1s      2s      3s");
    for (t, p) in &trace {
        let row = p.iter().map(|v| format!("{v:6.3}")).collect::<Vec<_>>().join("  ");
        println!("{t:5.2}   {row}");
    }

    println!("\nfirst crossing of 0.5:");
    for (head, name) in ["0.5s", "1s", "2s", "3s"].iter().enumerate() {
        match trace.iter().find(|(_, p)| p[head] > 0.5) {
            Some((t, _)) => println!("  head {head} ({name:4}): {t:.2} s"),
            None => println!("  head {head} ({name:4}): never"),
        }
    }
}
