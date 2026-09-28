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
added hiss, technical = wider pitch variation). Ground-truth transcripts
are short redistributable sentences written for this repo.

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

Live runs send synthetic fixture audio to a real STT endpoint and cost
quota; they never run in CI.

```sh
NANODICTATE_BENCHMARK_LIVE=1 swift run nanodictate benchmark --live --json /tmp/live.json
```

Keys come from your existing config/env (`NANODICTATE_API_KEY` or the
provider section) and are never written to the report or the repo.
