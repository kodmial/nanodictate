//! Versioned HUD contract fixture checks for the existing shared primitives.
//!
//! The same JSON consumed by the macOS reference tests and by #212's future
//! Windows meter tests is validated here against the shipping C ABI:
//! `nd_rms_f32`, `nd_dbfs`, and the `nd_session_*` generation/state machine.
//! No GUI state machine is added to Rust; the fixture remains presentation
//! data owned by the native hosts.

use nanodictate_core::abi::*;
use nanodictate_core::audio_metrics::NEAR_SILENCE_THRESHOLD;
use nanodictate_core::error::ND_OK;

const FIXTURE: &str = include_str!("../../../Tests/Fixtures/HUD/hud-contract-v1.json");

// ---------------------------------------------------------------------------
// Minimal JSON reader for the fixture's constrained shape.
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum Json {
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Json>),
    Object(Vec<(String, Json)>),
}

impl Json {
    fn get(&self, key: &str) -> Option<&Json> {
        match self {
            Json::Object(entries) => entries
                .iter()
                .find(|(name, _)| name == key)
                .map(|(_, value)| value),
            _ => None,
        }
    }

    fn as_array(&self) -> &[Json] {
        match self {
            Json::Array(values) => values,
            _ => &[],
        }
    }

    fn as_f64(&self) -> f64 {
        match self {
            Json::Number(value) => *value,
            _ => 0.0,
        }
    }

    fn as_str(&self) -> &str {
        match self {
            Json::String(value) => value,
            _ => "",
        }
    }

    fn as_bool(&self) -> bool {
        match self {
            Json::Bool(value) => *value,
            _ => false,
        }
    }
}

struct Parser<'a> {
    bytes: &'a [u8],
    position: usize,
}

impl<'a> Parser<'a> {
    fn new(text: &'a str) -> Self {
        Self {
            bytes: text.as_bytes(),
            position: 0,
        }
    }

    fn parse(mut self) -> Json {
        self.skip_whitespace();
        self.value()
    }

    fn skip_whitespace(&mut self) {
        while self.position < self.bytes.len()
            && matches!(self.bytes[self.position], b' ' | b'\n' | b'\r' | b'\t')
        {
            self.position += 1;
        }
    }

    fn value(&mut self) -> Json {
        self.skip_whitespace();
        match self.bytes.get(self.position).copied() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Json::String(self.string()),
            Some(b't') => {
                self.expect_literal("true");
                Json::Bool(true)
            }
            Some(b'f') => {
                self.expect_literal("false");
                Json::Bool(false)
            }
            Some(b'n') => {
                self.expect_literal("null");
                Json::Null
            }
            Some(_) => self.number(),
            None => Json::Null,
        }
    }

    fn expect_literal(&mut self, literal: &str) {
        debug_assert!(self.bytes[self.position..].starts_with(literal.as_bytes()));
        self.position += literal.len();
    }

    fn object(&mut self) -> Json {
        self.position += 1; // '{'
        let mut entries = Vec::new();
        loop {
            self.skip_whitespace();
            match self.bytes.get(self.position).copied() {
                Some(b'}') => {
                    self.position += 1;
                    break;
                }
                Some(b'"') => {
                    let key = self.string();
                    self.skip_whitespace();
                    if self.bytes.get(self.position) == Some(&b':') {
                        self.position += 1;
                    }
                    let value = self.value();
                    entries.push((key, value));
                    self.skip_whitespace();
                    if self.bytes.get(self.position) == Some(&b',') {
                        self.position += 1;
                    }
                }
                Some(_) => {
                    self.position += 1;
                }
                None => break,
            }
        }
        Json::Object(entries)
    }

    fn array(&mut self) -> Json {
        self.position += 1; // '['
        let mut values = Vec::new();
        loop {
            self.skip_whitespace();
            match self.bytes.get(self.position).copied() {
                Some(b']') => {
                    self.position += 1;
                    break;
                }
                Some(b',') => {
                    self.position += 1;
                }
                Some(_) => values.push(self.value()),
                None => break,
            }
        }
        Json::Array(values)
    }

    fn string(&mut self) -> String {
        self.position += 1; // opening quote
        let mut value = String::new();
        while let Some(byte) = self.bytes.get(self.position).copied() {
            self.position += 1;
            match byte {
                b'"' => break,
                b'\\' => {
                    let escaped = self.bytes.get(self.position).copied().unwrap_or(b'"');
                    self.position += 1;
                    match escaped {
                        b'"' => value.push('"'),
                        b'\\' => value.push('\\'),
                        b'/' => value.push('/'),
                        b'b' => value.push('\u{0008}'),
                        b'f' => value.push('\u{000c}'),
                        b'n' => value.push('\n'),
                        b'r' => value.push('\r'),
                        b't' => value.push('\t'),
                        b'u' => {
                            let end = (self.position + 4).min(self.bytes.len());
                            let hex = std::str::from_utf8(&self.bytes[self.position..end])
                                .unwrap_or("0000");
                            self.position = end;
                            if let Ok(code) = u32::from_str_radix(hex, 16) {
                                if let Some(ch) = char::from_u32(code) {
                                    value.push(ch);
                                }
                            }
                        }
                        other => value.push(other as char),
                    }
                }
                _ => value.push(byte as char),
            }
        }
        value
    }

    fn number(&mut self) -> Json {
        let start = self.position;
        while let Some(byte) = self.bytes.get(self.position).copied() {
            if matches!(byte, b'0'..=b'9' | b'+' | b'-' | b'.' | b'e' | b'E') {
                self.position += 1;
            } else {
                break;
            }
        }
        let text = std::str::from_utf8(&self.bytes[start..self.position]).unwrap_or("0");
        Json::Number(text.parse().unwrap_or(0.0))
    }
}

fn fixture() -> Json {
    Parser::new(FIXTURE).parse()
}

fn field<'a>(value: &'a Json, name: &str) -> &'a Json {
    value.get(name).expect("fixture field")
}

fn number(value: &Json, name: &str) -> f64 {
    field(value, name).as_f64()
}

fn string<'a>(value: &'a Json, name: &str) -> &'a str {
    field(value, name).as_str()
}

// ---------------------------------------------------------------------------
// Shared RMS/dBFS primitives.
// ---------------------------------------------------------------------------

#[test]
fn hud_fixture_metadata_and_constants_match_shared_engine() {
    let root = fixture();
    assert_eq!(string(&root, "contract"), "nanodictate.shared-hud");
    assert_eq!(number(&root, "version"), 1.0);

    let constants = field(&root, "constants");
    let floor = number(constants, "dbfs_floor") as f32;
    assert!((floor + 50.0).abs() < 1e-6, "fixture floor is -50 dBFS");

    // The existing near-silence threshold is the same -50 dBFS boundary.
    let threshold_db = nd_dbfs(NEAR_SILENCE_THRESHOLD);
    assert!(
        threshold_db <= floor && threshold_db > floor - 0.1,
        "near-silence threshold must map onto the meter floor: {threshold_db}"
    );
}

#[test]
fn hud_fixture_rms_vectors_match_shared_rms_and_dbfs_abi() {
    let root = fixture();
    let floor = number(field(&root, "constants"), "dbfs_floor") as f32;

    for vector in field(&root, "rms_vectors").as_array() {
        let rms = number(vector, "rms") as f32;
        let expected_dbfs = number(vector, "dbfs") as f32;
        let expected_meter = number(vector, "meter") as f32;
        let expected_stroke = number(vector, "stroke_points") as f32;
        let expected_hot = field(vector, "hot").as_bool();

        let samples = [rms];
        let measured_rms = nd_rms_f32(samples.as_ptr(), samples.len());
        assert!(
            (measured_rms - rms).abs() < 1e-5,
            "nd_rms_f32({rms}) = {measured_rms}"
        );

        let measured_dbfs = nd_dbfs(rms);
        assert!(
            (measured_dbfs - expected_dbfs).abs() < 1e-3,
            "nd_dbfs({rms}) = {measured_dbfs}, expected {expected_dbfs}"
        );

        let meter = ((measured_dbfs - floor) / -floor).clamp(0.0, 1.0);
        assert!(
            (meter - expected_meter).abs() < 1e-5,
            "meter for {rms} = {meter}, expected {expected_meter}"
        );
        assert!((3.0 + meter * 6.0 - expected_stroke).abs() < 1e-5);
        assert_eq!(meter > 0.88, expected_hot, "hot zone for {rms}");
    }
}

#[test]
fn hud_fixture_vu_targets_match_shared_dbfs() {
    let root = fixture();
    let floor = number(field(&root, "constants"), "dbfs_floor") as f32;

    for trace in field(&root, "vu_traces").as_array() {
        let reduce_motion = field(trace, "reduce_motion").as_bool();
        for step in field(trace, "steps").as_array() {
            let rms = number(step, "rms") as f32;
            let target = number(step, "target_meter") as f32;
            let meter = number(step, "meter") as f32;
            let derived = ((nd_dbfs(rms) - floor) / -floor).clamp(0.0, 1.0);
            assert!(
                (derived - target).abs() < 1e-5,
                "target meter for {rms}: {derived} != {target}"
            );
            if reduce_motion {
                assert!(
                    (meter - target).abs() < 1e-5,
                    "reduce motion must bypass the envelope"
                );
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Existing session ABI replayed from the fixture.
// ---------------------------------------------------------------------------

fn state_code(name: &str) -> u32 {
    match name {
        "idle" => ND_STATE_IDLE,
        "recording" => ND_STATE_RECORDING,
        "transcribing" => ND_STATE_TRANSCRIBING,
        other => panic!("unknown fixture state {other}"),
    }
}

struct SessionDriver {
    handle: *mut NdSession,
}

impl SessionDriver {
    fn new() -> Self {
        let handle = nd_session_new();
        assert!(!handle.is_null());
        Self { handle }
    }

    fn apply(&mut self, event: &str, generation: u64) {
        let state = nd_session_state(self.handle);
        match event {
            "double_alt" => {
                if state == ND_STATE_RECORDING {
                    assert_eq!(
                        nd_session_event(self.handle, ND_EVENT_STOP_REQUESTED, generation),
                        ND_OK
                    );
                } else {
                    // Idle starts normally; a new gesture during processing
                    // starts generation N+1 and abandons the old owner.
                    let started = nd_session_start(self.handle);
                    assert_eq!(
                        started, generation,
                        "fixture double_alt must start its declared generation"
                    );
                    assert!(started > 0);
                    assert_eq!(
                        nd_session_event(self.handle, ND_EVENT_ENGINE_STARTED, started),
                        ND_OK
                    );
                }
            }
            "first_buffer" => {
                assert_eq!(
                    nd_session_event(self.handle, ND_EVENT_FIRST_BUFFER, generation),
                    ND_OK
                );
            }
            "escape" => {
                assert_eq!(
                    nd_session_event(self.handle, ND_EVENT_CANCELLED, generation),
                    ND_OK
                );
            }
            "owner_done" => {
                assert_eq!(
                    nd_session_event(self.handle, ND_EVENT_TRANSCRIPTION_DONE, generation),
                    ND_OK
                );
            }
            "audio_error" => {
                assert_eq!(
                    nd_session_event(self.handle, ND_EVENT_ENGINE_FAILED, generation),
                    ND_OK
                );
            }
            _ => {}
        }
    }
}

impl Drop for SessionDriver {
    fn drop(&mut self) {
        nd_session_free(self.handle);
    }
}

#[test]
fn hud_fixture_session_checkpoints_match_existing_session_abi() {
    let root = fixture();
    for scenario in field(&root, "presentation_scenarios").as_array() {
        let mut driver = SessionDriver::new();
        let events = field(scenario, "events").as_array();
        let mut next_event = 0usize;

        for checkpoint in field(scenario, "checkpoints").as_array() {
            let at_ms = number(checkpoint, "at_ms");
            while next_event < events.len() && number(&events[next_event], "at_ms") <= at_ms {
                // The initial checkpoint observes the pre-boot state, before
                // the same-timestamp double_alt event starts the session.
                if at_ms == 0.0 && number(&events[next_event], "at_ms") == 0.0 {
                    break;
                }
                let event = &events[next_event];
                driver.apply(string(event, "event"), number(event, "generation") as u64);
                next_event += 1;
            }

            let scenario_name = string(scenario, "name");
            if at_ms == 0.0 {
                assert_eq!(
                    nd_session_state(driver.handle),
                    ND_STATE_IDLE,
                    "scenario {scenario_name} initial state"
                );
                continue;
            }

            let rust_state = checkpoint
                .get("rust_state")
                .filter(|v| matches!(v, Json::String(text) if !text.is_empty()))
                .unwrap_or_else(|| {
                    panic!(
                        "scenario {scenario_name} checkpoint at {at_ms} ms must declare rust_state"
                    )
                });
            assert_eq!(
                nd_session_state(driver.handle),
                state_code(rust_state.as_str()),
                "scenario {scenario_name} at {at_ms} ms"
            );
        }
    }
}
