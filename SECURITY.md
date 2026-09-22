# Security Policy

## Reporting a Vulnerability

Please report security vulnerabilities **privately** instead of opening a
public issue — this keeps the details private until a fix is available.
GitHub Private Vulnerability Reporting appears not to be enabled for this
repository (the GitHub API does not expose the field, so the owner should
verify in the repository settings); until it is, the private channel is email
to the maintainer:

```
kodmial@gmail.com
```

Use the subject prefix `[nanodictate-security]`. If email is unavailable, open
a regular issue instead, but keep it sanitized — no live keys, no personal data
(issues on a public repository are fully visible): describe the vulnerability,
its impact, and a minimal repro.

In the report, please include:

- A description of the vulnerability and its impact.
- Steps to reproduce (minimal repro, affected configuration/version).
- Any suggested fix, if you have one.

Do not include live credentials, API keys, or other personal data in the
report.

## Response

- Reports are acknowledged within a few business days.
- You will receive updates while the report is being evaluated, and, for
  confirmed issues, an expected fix timeline.
- Fixes are shipped through normal releases and, where appropriate, noted in
  the release notes. We ask that you refrain from public disclosure until a
  fix is available.

## Scope

This project is an on-screen dictation tool for macOS. API keys and credentials
for cloud STT providers are stored only on the local machine and are never
committed to this repository. Credentials may come from three places (priority
order: `NANODICTATE_API_KEY` env var > `api_key` config key > `api_key_file`
config key pointing at a separate key file):

- the user config file at `~/.config/nanodictate/config.toml` (the default
  location; the CLI creates it with mode 0600 on first run);
- a separate key file referenced by the `api_key_file` config key;
- the `NANODICTATE_API_KEY` environment variable (never written to disk).

See the README and `Sources/NanoDictateCore/Config.swift` (`Config.load`) for
details.

## Disclaimer

This project is provided "as is", without warranty of any kind. You are
responsible for the security of your own configuration, credentials, and
deployment.