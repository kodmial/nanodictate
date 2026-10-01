# STT benchmark harness

Reproducible quality/latency/bandwidth comparison for STT configurations.
Deterministic pieces run locally without network, secrets, or recordings;
live provider runs are explicit opt-in.

## One-command local run

```sh
swift run nanodictate benchmark --local
```

Machine-readable plus human-readable output:

```sh
swift run nanodictate benchmark --local --json /tmp/bench.json --markdown /tmp/bench.md
```

Deterministic unit coverage (WER/CER, fixtures, byte accounting, report
round-trip) runs with the normal suite — no network:

```sh
swift run NanoDictateCoreTests
```

Benchmark results are never CI pass/fail thresholds: timings and byte
counts are reported, not asserted, except for structural properties
(upload >= WAV bytes, WER == 0 for identical text).

## What is measured

Per fixture × config:

- WER and CER against the ground-truth transcript (normalized:
  lowercase, punctuation stripped, whitespace collapsed).
- Upload bytes: exact request body from `ProviderRequestBuilder.plan`
  (multipart overhead included), plus raw WAV bytes.
- Encoding/preprocessing time: `WAVEncoder.encode` wall clock.
- Request latency: provider-call wall clock (scripted provider reports 0
  simulated latency; live runs measure the real STT request).
- End-to-end time to final transcript: case wall clock.
- Peak RSS kilobytes (best effort via `getrusage`; 0 when unavailable).

## Fixture strategy (no recordings in repo)

Fixtures are synthetic and deterministic: `BenchmarkSynth.samples`
generates seeded 16 kHz mono PCM per category (quiet = low gain, noisy =
added hiss, technical = wider pitch variation). These are tones and
noise, not intelligible speech. Ground-truth transcripts are short
redistributable sentences written for this repo, kept as scoring ground
truth for deterministic local runs and tests.

Built-in corpus (`BenchmarkFixtures.builtins()`):

| id | category | bucket | duration |
| --- | --- | --- | --- |
| quiet-short | quiet | short | ~3 s |
| normal-short | normal | short | ~4 s |
| noisy-short | noisy | short | ~4 s |
| technical-short | technical | short | ~5 s |
| normal-long | normal | long | ~55 s |

Ground-truth transcript format: plain UTF-8 text, one utterance per
fixture (`BenchmarkFixture.transcript`). Scoring normalizes before WER/CER,
so punctuation and case do not affect results.

## Adding a fixture

1. Add a `BenchmarkFixture` entry in `BenchmarkFixtures.builtins()` (or
   build your own array for a custom run) with a unique `id`, a
   `BenchmarkCategory`, a duration bucket, a redistributable `transcript`,
   and `BenchmarkSynth.samples(seed:durationSeconds:kind:)` audio.
2. Keep seeds fixed so the corpus stays reproducible.
3. Never commit real user recordings, third-party audio, or API secrets —
   fixtures must remain synthetic or explicitly redistributable.

## Comparing configurations / adding a provider run

- Define each configuration as `BenchmarkSTTConfig(name:adapterID:model:language:)`.
- Provide a `BenchmarkProviderRun` closure
  `(fixture, config) throws -> BenchmarkHypothesis(text:requestSeconds:)`.
- Call `BenchmarkRunner.run(fixtures:configs:provider:)` and render with
  `report.markdown()` (human) and `report.jsonData()` (machine).
- `BenchmarkRunner.scriptedProvider(hypotheses:)` covers deterministic
  local runs and tests.

Example (two configs, scripted provider):

```swift
let fixtures = BenchmarkFixtures.builtins()
let configs = [
  BenchmarkSTTConfig(name: "a", adapterID: "openai", model: "whisper-1"),
  BenchmarkSTTConfig(name: "b", adapterID: "groq", model: "whisper-large-v3"),
]
let report = try BenchmarkRunner.run(
  fixtures: fixtures, configs: configs,
  provider: BenchmarkRunner.scriptedProvider(hypotheses: [:]))
print(report.markdown())
try report.jsonData().write(to: URL(fileURLWithPath: "bench.json"))
```

## Live provider benchmarks (opt-in)

Live runs send fixture audio to a real STT endpoint and cost quota;
they never run in CI. Synthetic tones do not speak the transcripts,
so live quality scoring requires transcript-bearing audio: `--live`
fails without `--live-wav-dir` (or `NANODICTATE_BENCHMARK_LIVE_WAV_DIR`),
fixtures without a readable `<fixture-id>.wav` are skipped and never
scored, and the run fails when no fixture has speech audio. Reported
WER/CER therefore only reflect recognition quality on audio that speaks
each transcript.

```sh
NANODICTATE_BENCHMARK_LIVE=1 swift run nanodictate benchmark --live --json /tmp/live.json
```

To score live speech quality, provide one PCM 16-bit WAV per fixture
(`<fixture-id>.wav`, for example `normal-short.wav`) speaking that
fixture's exact `transcript`, then point the live run at the directory:

```sh
NANODICTATE_BENCHMARK_LIVE=1 swift run nanodictate benchmark --live \
  --live-wav-dir ~/benchmark-speech --json /tmp/live.json
```

`NANODICTATE_BENCHMARK_LIVE_WAV_DIR` is equivalent to `--live-wav-dir`.
`BenchmarkLiveAudio.resolvedLiveFixtures(fromDirectoryPath:)` overlays matching
files onto the synthetic fixtures (mono-downmixed, transcripts kept as
ground truth) and marks each fixture as speech (`isSpeech == true`) or
non-speech. `cmdBenchmarkLive` scores only speech fixtures; missing or
unreadable WAVs are skipped with a stderr warning and excluded from
WER/CER. Never commit third-party audio: keep live speech files outside
the repo unless you recorded them and have redistribution rights.

Keys come from your existing config/env (`NANODICTATE_API_KEY` or the
provider section) and are never written to the report or the repo.

## Chunked final-pass comparison (always vs default)

The local run also prints a `Chunked final-pass` section for the long
fixture (`normal-long`): real `AudioSegmenter` segments, scripted confident
hypotheses (correct transcript slice + word timestamps per segment, correct
full transcript for the final pass), exact multipart upload bytes via
`ProviderRequestBuilder.plan`.

| policy | meaning |
| --- | --- |
| `always` | Historical behavior: final full-recording pass for every multi-segment recording. |
| `on-uncertainty` (default) | Skip the full re-upload when all segments look acceptable; fall back on empty segments or seams without timestamps. |
| `never` | Never re-upload after successful segments (failed segments still recover via the full pass). |

With confident segments the default reaches the same WER/CER as `always`
while saving the whole final upload plus one request of tail latency
(`ChunkedBenchmark.simulatedFinalLatencyMs`). With an empty segment or a
seam without timestamps the default falls back to the final pass, matching
`always` on quality. Decision: default `on-uncertainty`; keep `always` as
the quality-first option; use `never` with true streaming providers, where
the stream's own final hypothesis already carries full context.
