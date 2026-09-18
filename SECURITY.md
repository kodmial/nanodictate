# Security Policy

## Reporting a Vulnerability

Please report security vulnerabilities through **GitHub Private Vulnerability
Reporting** instead of opening a public issue — this keeps the details private
until a fix is available:

```
https://github.com/<owner>/<repo>/security/advisories/new
```

(Replace `<owner>` and `<repo>` with this repository's owner and name.)

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
for cloud STT providers are stored locally in the user configuration
(`~/.config/nanodictate/`) and are never committed to this repository — see the
README for details.

## Disclaimer

This project is provided "as is", without warranty of any kind. You are
responsible for the security of your own configuration, credentials, and
deployment.