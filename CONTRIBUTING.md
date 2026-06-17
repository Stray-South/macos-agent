# Contributing

This is a **solo-maintained beta project**. External code contributions
are not being accepted at this time.

## What you can do

- File a [bug report](https://github.com/Stray-South/macos-agent/issues/new)
- File a feature request (same link)
- Report a security issue per [SECURITY.md](SECURITY.md) — never as a public issue

If/when external contributions open up, this file will be updated.

## License terms for any future contribution

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this project by you, as defined in the
Apache-2.0 license, shall be dual-licensed as MIT OR Apache-2.0,
without any additional terms or conditions.

## Development conventions (if you fork)

This project follows the rules in [AGENTS.md](AGENTS.md) — engineering
rules and execution rubric. The short version:

- Swift 6.2, strict concurrency, zero external dependencies
- One concern per commit. Format: `type(scope): description`
- `SafetyPolicy.classify()` must run on every action — never bypassed
- Every executed action writes a receipt
- No `@unchecked Sendable` without an invariant-explaining comment
- AuDHD-first UI defaults (see AGENTS.md §AuDHD-First Defaults)
