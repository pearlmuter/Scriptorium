//! Just enough of SentencePiece to turn token ids back into text.
//!
//! The obvious alternatives were both worse. Linking Google's C++ SentencePiece
//! (what kyutai's own `stt-rs` does) drags cmake into the build for one lookup
//! table. Dumping the vocabulary to JSON ahead of time (what kyutai's
//! `moshi-swift` does, in `scripts/sp.py`) creates a second artefact that can
//! drift away from the weights it was generated from.
//!
//! Reading the `.model` file directly keeps the tokeniser travelling with the
//! checkpoint that was downloaded, which is the only arrangement where the two
//! cannot disagree.
//!
//! The file is a protobuf `ModelProto` whose field 1 is `repeated SentencePiece
//! pieces`, and a piece's field 1 is its text. A token id is an index into that
//! sequence, so nothing else in the file matters here.

/// The piece prefix SentencePiece uses to mean "a space preceded this".
const WORD_BOUNDARY: char = '\u{2581}';

pub struct Vocabulary {
    pieces: Vec<String>,
}

impl Vocabulary {
    pub fn load(path: &str) -> Result<Self, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
        Self::parse(&bytes)
    }

    pub fn parse(bytes: &[u8]) -> Result<Self, String> {
        let mut pieces = Vec::new();
        let mut cursor = Cursor::new(bytes);
        while !cursor.is_empty() {
            let (field, wire_type) = cursor.tag()?;
            match (field, wire_type) {
                // pieces
                (1, 2) => {
                    let body = cursor.length_delimited()?;
                    pieces.push(Self::piece_text(body)?);
                }
                _ => cursor.skip(wire_type)?,
            }
        }
        if pieces.is_empty() {
            return Err("tokeniser contained no pieces".into());
        }
        Ok(Self { pieces })
    }

    /// Field 1 of a `SentencePiece` message. Absent means the empty string,
    /// which is what protobuf's optional semantics call for.
    fn piece_text(bytes: &[u8]) -> Result<String, String> {
        let mut cursor = Cursor::new(bytes);
        let mut text = String::new();
        while !cursor.is_empty() {
            let (field, wire_type) = cursor.tag()?;
            if field == 1 && wire_type == 2 {
                let body = cursor.length_delimited()?;
                text = String::from_utf8(body.to_vec()).map_err(|e| e.to_string())?;
            } else {
                cursor.skip(wire_type)?;
            }
        }
        Ok(text)
    }

    pub fn len(&self) -> usize {
        self.pieces.len()
    }

    /// Joins one word's tokens into display text. Unknown ids are dropped
    /// rather than rendered, because a placeholder in the middle of a
    /// transcript reads as something the speaker said.
    pub fn decode(&self, tokens: &[u32]) -> String {
        let mut out = String::new();
        for &token in tokens {
            if let Some(piece) = self.pieces.get(token as usize) {
                out.push_str(&piece.replace(WORD_BOUNDARY, " "));
            }
        }
        out
    }
}

struct Cursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, pos: 0 }
    }

    fn is_empty(&self) -> bool {
        self.pos >= self.bytes.len()
    }

    fn varint(&mut self) -> Result<u64, String> {
        let mut value = 0u64;
        let mut shift = 0;
        loop {
            let byte = *self.bytes.get(self.pos).ok_or("truncated varint")?;
            self.pos += 1;
            // 10 groups of 7 bits is the most a u64 can hold; more means the
            // file is not what it claims to be.
            if shift >= 64 {
                return Err("varint overflows 64 bits".into());
            }
            value |= ((byte & 0x7f) as u64) << shift;
            if byte & 0x80 == 0 {
                return Ok(value);
            }
            shift += 7;
        }
    }

    fn tag(&mut self) -> Result<(u64, u8), String> {
        let tag = self.varint()?;
        Ok((tag >> 3, (tag & 0x7) as u8))
    }

    fn length_delimited(&mut self) -> Result<&'a [u8], String> {
        let len = self.varint()? as usize;
        let end = self.pos.checked_add(len).ok_or("length overflows")?;
        let slice = self.bytes.get(self.pos..end).ok_or("truncated field")?;
        self.pos = end;
        Ok(slice)
    }

    fn skip(&mut self, wire_type: u8) -> Result<(), String> {
        match wire_type {
            0 => {
                self.varint()?;
            }
            1 => self.advance(8)?,
            2 => {
                self.length_delimited()?;
            }
            5 => self.advance(4)?,
            other => return Err(format!("unsupported protobuf wire type {other}")),
        }
        Ok(())
    }

    fn advance(&mut self, n: usize) -> Result<(), String> {
        let end = self.pos.checked_add(n).ok_or("length overflows")?;
        if end > self.bytes.len() {
            return Err("truncated field".into());
        }
        self.pos = end;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a `ModelProto` holding the given pieces, so the parser is tested
    /// against bytes rather than against itself.
    fn model_proto(pieces: &[&str]) -> Vec<u8> {
        fn varint(mut v: u64, out: &mut Vec<u8>) {
            loop {
                let byte = (v & 0x7f) as u8;
                v >>= 7;
                if v == 0 {
                    out.push(byte);
                    return;
                }
                out.push(byte | 0x80);
            }
        }
        let mut out = Vec::new();
        for piece in pieces {
            let mut body = Vec::new();
            varint(1 << 3 | 2, &mut body); // piece, length-delimited
            varint(piece.len() as u64, &mut body);
            body.extend_from_slice(piece.as_bytes());
            varint(2 << 3 | 5, &mut body); // score, 32-bit
            body.extend_from_slice(&0.0f32.to_le_bytes());
            varint(3 << 3, &mut body); // type, varint
            varint(1, &mut body);

            varint(1 << 3 | 2, &mut out); // pieces, length-delimited
            varint(body.len() as u64, &mut out);
            out.extend_from_slice(&body);
        }
        out
    }

    #[test]
    fn reads_pieces_in_id_order() {
        let vocab = Vocabulary::parse(&model_proto(&["<unk>", "\u{2581}the", "quick"])).unwrap();
        assert_eq!(vocab.len(), 3);
        assert_eq!(vocab.decode(&[1, 2]), " thequick");
    }

    #[test]
    fn word_boundary_becomes_a_space() {
        let vocab = Vocabulary::parse(&model_proto(&["a", "\u{2581}b"])).unwrap();
        assert_eq!(vocab.decode(&[1]), " b");
        assert_eq!(vocab.decode(&[0]), "a");
    }

    #[test]
    fn unknown_ids_are_dropped_not_rendered() {
        let vocab = Vocabulary::parse(&model_proto(&["a"])).unwrap();
        assert_eq!(vocab.decode(&[0, 99]), "a");
    }

    /// Fields the ModelProto carries that we do not read must not derail the
    /// scan: trainer_spec and normalizer_spec sit alongside the pieces.
    #[test]
    fn skips_unknown_fields() {
        let mut bytes = model_proto(&["a"]);
        bytes.push(2 << 3 | 2); // trainer_spec, length-delimited
        bytes.push(3);
        bytes.extend_from_slice(b"xyz");
        bytes.push(4 << 3); // some varint field
        bytes.push(7);
        let mut tail = model_proto(&["b"]);
        bytes.append(&mut tail);
        let vocab = Vocabulary::parse(&bytes).unwrap();
        assert_eq!(vocab.len(), 2);
        assert_eq!(vocab.decode(&[1]), "b");
    }

    #[test]
    fn rejects_a_file_with_no_pieces() {
        assert!(Vocabulary::parse(&[]).is_err());
    }

    #[test]
    fn rejects_a_truncated_file() {
        let bytes = model_proto(&["hello"]);
        assert!(Vocabulary::parse(&bytes[..bytes.len() - 2]).is_err());
    }
}
