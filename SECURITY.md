# Security Policy

## Reporting a Vulnerability

Email security reports to **security@southernreach.dev** with the subject line:

> `[macos-agent SECURITY] <one-line summary>`

**Do not open public issues for vulnerabilities.** Disclose privately first.

This project is solo-maintained during beta. I aim to acknowledge reports
within 7 days. If a vulnerability is severe and remains unpatched 30 days
after acknowledgement, you are free to disclose publicly.

## Scope — in scope

- Bypass of `SafetyPolicy.classify()` — any path where a proposed `AgentAction`
  executes without going through the safety classifier
- Bypass of capability rule `deny` rules — any action that executes despite a
  matching deny rule
- Receipt-write integrity — a successful action without a corresponding
  JSONL receipt entry
- Sensitive data leakage — agent observations or typed content surfacing in
  unintended places (network requests other than the configured Anthropic
  endpoint, log files, system pasteboard outside the documented
  `typeText` clipboard-fastpath window)
- Privilege boundary breach — agent reading/writing files outside its
  documented state directory (`~/Library/Application Support/MacAgent/`).
  Pre-2026-05-23 builds also wrote `~/MacAgent/throughline.json`; the
  current build migrates that file into Application Support on first
  launch and removes the legacy parent directory.

## Scope — out of scope

- Anthropic API behavior — report directly to Anthropic
- macOS Transparency, Consent, and Control (TCC) behavior — report to Apple
- Hypothetical vulnerabilities without a working reproduction
- Findings already documented in [RED-TEAM.md](RED-TEAM.md) (see the
  ⚠️ "known gap" markers — those are tracked and deferred, not novel)

## Existing adversarial coverage

See [RED-TEAM.md](RED-TEAM.md) for the full adversarial test catalog —
65 specs across AX injection, Vision OCR injection, throughline poisoning,
identity spoofing, excessive agency, DoS / loop abuse, sensitive data
exposure, supply chain, and AuDHD-specific safety regressions. Findings
already covered by passing tests in that catalog are not novel reports.

## Coordinated disclosure

For severe vulnerabilities I will:
1. Acknowledge the report within 7 days
2. Confirm the vulnerability or explain why it isn't one within 14 days
3. Develop and ship a fix on a private branch
4. Publish a release with the fix and credit the reporter (unless they
   prefer anonymity)
5. Update RED-TEAM.md with the corresponding regression test
