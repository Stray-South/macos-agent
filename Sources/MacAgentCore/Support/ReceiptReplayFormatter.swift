/// ReceiptReplayFormatter.swift
///
/// Unit 16 / Path D Candidate 3 Phase 1.
///
/// Pure-function rendering for the `MacAgentReplay` CLI and any future
/// consumer that wants to display `ActionLogEntry` rows uniformly. No
/// I/O: the formatter takes an array of decoded entries and emits
/// printable lines. File reading lives in `ReceiptReader`; the CLI
/// composes the two.
///
/// **Privacy invariant.** `action.text` for `.typeText` actions can
/// carry verbatim password / 2FA cleartext (operator-approved per the
/// receipt schema's cleartext-by-design rule). The formatter REDACTS
/// `action.text` to `***` for `.typeText` actions by default; the CLI
/// surfaces this via the `--show-text` opt-in flag. Other action types
/// (`.keyCombo` text = `"cmd+v"`, `.menuSelect` text = `"File > New"`)
/// are structural and NOT redacted — those payloads carry no risk and
/// hiding them blocks diagnosis.
import Foundation

public enum ReceiptReplayFormatter {

    /// Returns true when the entry is in the "error" class for the
    /// `--errors` CLI filter. Union of two semantics:
    ///   - `approved == false`: capability-deny or user-reject path
    ///     (rejection receipt with executionResult like `"rejected"` or
    ///     `"rejected-immediate-complete"`).
    ///   - `executionResult.hasPrefix("error:")`: Orchestrator's
    ///     executor-error catch site writes `"error: \(localizedDescription)"`.
    /// Both surfaces are operator-relevant when triaging dogfood failures.
    public static func isError(_ entry: ActionLogEntry) -> Bool {
        if !entry.approved { return true }
        return entry.executionResult.hasPrefix("error:")
    }

    /// Filter the entries down to what the CLI should display.
    /// - `date`: when non-nil, keep only entries whose UTC calendar day
    ///   matches the supplied date's UTC calendar day (filename-aligned).
    /// - `errorsOnly`: when true, drop entries where `isError` is false.
    /// - `cap`: truncate the result to at most this many entries (after
    ///   filtering; assumes the input is already in the desired order).
    public static func filter(
        entries: [ActionLogEntry],
        date: Date? = nil,
        errorsOnly: Bool = false,
        cap: Int = 30
    ) -> [ActionLogEntry] {
        var result = entries
        if let date {
            let cal = Self.utcCalendar
            let target = cal.dateComponents([.year, .month, .day], from: date)
            result = result.filter {
                let comps = cal.dateComponents([.year, .month, .day], from: $0.timestamp)
                return comps.year == target.year
                    && comps.month == target.month
                    && comps.day == target.day
            }
        }
        if errorsOnly {
            result = result.filter(isError)
        }
        if cap >= 0, result.count > cap {
            result = Array(result.prefix(cap))
        }
        return result
    }

    /// Render an entry as a single line. Format:
    ///
    ///   YYYY-MM-DD HH:MM:SSZ  [✓|✗] type[idx] "text"  tier=TIER  result=...
    ///
    /// `action.text` for `.typeText` is replaced with `***` when
    /// `showText == false`. Other action types' `text` is printed
    /// verbatim regardless of the flag — they carry no privacy risk.
    /// `targetIndex` appears as `[N]` when present.
    public static func format(_ entry: ActionLogEntry, showText: Bool = false) -> String {
        let ts = makeISOFormatter().string(from: entry.timestamp)
        // Reviewer-caught Sev-2: previous design used a 2-state marker
        // (✓/✗) which conflated "operator permitted" with "execution
        // succeeded". Smoke output `[✓] click result=error: …` reads
        // as "this worked" at a glance even when the executor threw.
        // Three orthogonal states:
        //   ✓ — operator approved AND executed cleanly
        //   ⚠ — operator approved BUT execution failed (Orchestrator
        //       wrote a receipt with executionResult starting "error:")
        //   ⏭ — operator approved BUT the action was never executed:
        //       the Unit-29b stale-approval guard superseded it because
        //       the screen changed while the gate was parked
        //   ✗ — rejected (capability deny or user reject; approved=false)
        let mark: String
        if !entry.approved {
            mark = "✗"
        } else if entry.executionResult.hasPrefix("error:") {
            mark = "⚠"
        } else if entry.executionResult.hasPrefix("superseded") {
            mark = "⏭"
        } else {
            mark = "✓"
        }
        let typeStr = entry.action.type.rawValue
        let idxStr = entry.action.targetIndex.map { "[\($0)]" } ?? ""

        let textRendered: String
        if let text = entry.action.text {
            // Reviewer-caught Sev-2: previous design redacted ONLY for
            // .typeText. AgentAction.text is `String?` with no schema
            // enforcement of "what kinds of text live here per action
            // type" — a hallucinated `.clarify` or unknown future
            // action type could carry sensitive content. Flip to a
            // whitelist of action types whose `text` is STRUCTURALLY
            // safe (key combos, menu paths, bundle IDs). Everything
            // else gets redacted by default; --show-text overrides.
            if !showText && !Self.textAlwaysSafe(entry.action.type) {
                textRendered = " \"***\""
            } else {
                // Cap displayed text so a 2000-char paste doesn't blow up
                // the terminal width (the schema caps at 2000; we cap
                // display at 60 for readability).
                let capped = text.count > 60 ? String(text.prefix(57)) + "..." : text
                textRendered = " \"\(capped)\""
            }
        } else {
            textRendered = ""
        }

        let tierUp = entry.tier.uppercased()
        // Unit 35 — readClipboard's executionResult IS the clipboard
        // content (possibly a password). Redact by default, same posture
        // as typeText payloads; --show-text reveals.
        let rawResult: String
        if entry.action.type == .readClipboard && !showText
            && entry.executionResult.hasPrefix("clipboard contents:") {
            rawResult = "(clipboard contents — \(entry.executionResult.count) chars; --show-text to reveal)"
        } else {
            rawResult = entry.executionResult
        }
        let result = rawResult.count > 80
            ? String(rawResult.prefix(77)) + "..."
            : rawResult

        return "\(ts)  [\(mark)] \(typeStr)\(idxStr)\(textRendered)  tier=\(tierUp)  result=\(result)"
    }

    /// Render a list of entries. The caller is responsible for
    /// ordering (newest-first matches `MacAgentReplay`'s default).
    public static func format(
        entries: [ActionLogEntry],
        showText: Bool = false
    ) -> [String] {
        entries.map { format($0, showText: showText) }
    }

    // MARK: - Snapshot rendering (Unit 19)

    /// Pretty-print a `PerceptionSnapshot` as a two-table report:
    /// elements + vision observations. Used by
    /// `MacAgentReplay --snapshot <hash>` after `SnapshotReader.load`
    /// returns the persisted sidecar.
    ///
    /// Returns a single multi-line string; caller writes to stdout.
    /// Designed for terminal width ~120 chars; truncates labels and
    /// vision text past their column budget.
    public static func formatSnapshot(_ snapshot: PerceptionSnapshot) -> String {
        var lines: [String] = []
        // Summary header
        let ts = makeISOFormatter().string(from: snapshot.timestamp)
        lines.append("Snapshot \(snapshot.hash)")
        lines.append("  timestamp: \(ts)")
        lines.append("  bundleID:  \(snapshot.focusedAppBundleID)")
        lines.append("  elements:  \(snapshot.elements.count)  (visionIndexOffset=\(snapshot.visionIndexOffset))")
        lines.append("  vision:    \(snapshot.visionObservations.count)\(snapshot.visionUsedFullScreenFallback ? " (full-screen fallback)" : "")")
        if snapshot.elementListTruncated {
            lines.append("  truncated: YES (snapshot UI exceeded the 300-element cap)")
        }
        if snapshot.agentIsOverlaid {
            lines.append("  agentIsOverlaid: YES (the agent's own UI was frontmost when this snapshot was captured)")
        }

        // Elements table
        if !snapshot.elements.isEmpty {
            lines.append("")
            lines.append("Elements (\(snapshot.elements.count)):")
            lines.append("  idx  role                  label                                     enabled  focused  frame")
            lines.append("  ---  --------------------  ----------------------------------------  -------  -------  --------------------")
            for el in snapshot.elements {
                let idx = "\(el.index)".padded(to: 3)
                let role = el.role.padded(to: 20, truncate: true)
                let label = el.label.padded(to: 40, truncate: true)
                let enabled = el.isEnabled ? "yes    " : "no     "
                // Unit 25 — focused column. Snapshots pre-Unit-25 decode
                // isFocused=false (Codable default), so the column reads
                // "no" for every element in older sidecars.
                let focused = el.isFocused ? "yes    " : "no     "
                let frame = "(\(Int(el.frame.x)),\(Int(el.frame.y))) \(Int(el.frame.width))x\(Int(el.frame.height))"
                lines.append("  \(idx)  \(role)  \(label)  \(enabled)  \(focused)  \(frame)")
            }
        }

        // Vision observations
        if !snapshot.visionObservations.isEmpty {
            lines.append("")
            lines.append("Vision observations (\(snapshot.visionObservations.count), starting at index \(snapshot.visionIndexOffset)):")
            lines.append("  vidx  text                                                                      bbox")
            lines.append("  ----  ------------------------------------------------------------------------  ----------------")
            for (i, obs) in snapshot.visionObservations.enumerated() {
                let vidx = "\(snapshot.visionIndexOffset + i)".padded(to: 4)
                let text = obs.text.padded(to: 72, truncate: true)
                let bbox = "(\(Int(obs.boundingBox.x)),\(Int(obs.boundingBox.y))) \(Int(obs.boundingBox.width))x\(Int(obs.boundingBox.height))"
                lines.append("  \(vidx)  \(text)  \(bbox)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Snapshot diff (Unit 21 / Path D Candidate 3 Phase 2b)

    /// Pretty-print a positional diff between two snapshots. Used by
    /// `MacAgentReplay --diff <hash-A-prefix> <hash-B-prefix>` to
    /// answer "what changed between these two observations?"
    ///
    /// **Positional, not identity-based.** Elements are compared by
    /// index. Same index = same UIElement is the assumption — UI
    /// reflow (a button removed earlier in the tree) will cause every
    /// downstream index to register as CHANGED. The operator interprets
    /// accordingly; this is forensic raw signal, not semantic identity.
    ///
    /// Output structure:
    ///   - Header summary (bundleID, element-count + vision-count deltas)
    ///   - Elements: positional walk over min(a.count, b.count); list
    ///     CHANGED with affected field names, plus additions/removals
    ///   - Vision observations: same treatment
    public static func formatSnapshotDiff(
        _ a: PerceptionSnapshot,
        _ b: PerceptionSnapshot
    ) -> String {
        // Fast path: identical hash → identical snapshot by construction
        // (PerceptionSnapshot.hash is computed from all observable fields).
        if a.hash == b.hash {
            return "Snapshots are identical (hash \(a.hash) matches)."
        }

        var lines: [String] = []
        lines.append("DIFF \(a.hash) → \(b.hash)")

        // Header — high-signal at-a-glance summary.
        if a.focusedAppBundleID != b.focusedAppBundleID {
            lines.append("  bundleID: \(a.focusedAppBundleID) → \(b.focusedAppBundleID)  (CHANGED)")
        } else {
            lines.append("  bundleID: \(a.focusedAppBundleID)")
        }
        let elDelta = b.elements.count - a.elements.count
        let elSign = elDelta >= 0 ? "+" : ""
        lines.append("  elements: \(a.elements.count) → \(b.elements.count)  (\(elSign)\(elDelta))")
        let vDelta = b.visionObservations.count - a.visionObservations.count
        let vSign = vDelta >= 0 ? "+" : ""
        lines.append("  vision:   \(a.visionObservations.count) → \(b.visionObservations.count)  (\(vSign)\(vDelta))")

        // Elements: positional walk over shared range.
        let elementChanges = diffElements(a.elements, b.elements)
        if !elementChanges.isEmpty {
            lines.append("")
            lines.append("Element changes (\(elementChanges.count)):")
            for line in elementChanges {
                lines.append("  \(line)")
            }
        }

        // Vision observations: positional walk over shared range.
        let visionChanges = diffVisionObservations(a.visionObservations, b.visionObservations)
        if !visionChanges.isEmpty {
            lines.append("")
            lines.append("Vision changes (\(visionChanges.count)):")
            for line in visionChanges {
                lines.append("  \(line)")
            }
        }

        // Truly empty diff (different hashes, no rendered changes) means
        // a non-element / non-vision field differs — e.g. timestamp,
        // captureOrigin. Surface explicitly so the operator isn't
        // confused by "different hash but nothing shown."
        if elementChanges.isEmpty && visionChanges.isEmpty
            && a.focusedAppBundleID == b.focusedAppBundleID
            && a.elements.count == b.elements.count
            && a.visionObservations.count == b.visionObservations.count {
            lines.append("")
            lines.append("(Hashes differ but element + vision + bundleID match — a metadata field differs: timestamp, captureOrigin, or flags.)")
        }

        return lines.joined(separator: "\n")
    }

    /// Walk two element arrays positionally. Returns one-line summaries
    /// for each CHANGED, ADDED, or REMOVED entry. Empty array if both
    /// arrays are pairwise equal.
    private static func diffElements(_ a: [UIElement], _ b: [UIElement]) -> [String] {
        var out: [String] = []
        let shared = min(a.count, b.count)
        for i in 0..<shared where a[i] != b[i] {
            // Identify which fields differ. Up to 7 possible fields
            // (Unit 25 added isFocused); typical change touches 1-2 so
            // a compact comma list is readable.
            var fields: [String] = []
            if a[i].role != b[i].role { fields.append("role") }
            if a[i].label != b[i].label { fields.append("label") }
            if a[i].value != b[i].value { fields.append("value") }
            if a[i].frame != b[i].frame { fields.append("frame") }
            if a[i].isEnabled != b[i].isEnabled { fields.append("isEnabled") }
            if a[i].isVisible != b[i].isVisible { fields.append("isVisible") }
            if a[i].isFocused != b[i].isFocused { fields.append("isFocused") }
            let fieldsStr = fields.joined(separator: ", ")
            out.append("[\(i)] CHANGED:\(fieldsStr)  \(a[i].role) '\(a[i].label)' → \(b[i].role) '\(b[i].label)'")
        }
        // Additions: b has more elements than a.
        if b.count > a.count {
            for i in a.count..<b.count {
                out.append("[+\(i)] ADDED    \(b[i].role) '\(b[i].label)'")
            }
        }
        // Removals: a has more elements than b.
        if a.count > b.count {
            for i in b.count..<a.count {
                out.append("[-\(i)] REMOVED  \(a[i].role) '\(a[i].label)'")
            }
        }
        return out
    }

    /// Walk two vision-observation arrays positionally. Same pattern
    /// as diffElements. VisionObservation has 2 fields (text, boundingBox);
    /// either changing produces a CHANGED line.
    private static func diffVisionObservations(_ a: [VisionObservation], _ b: [VisionObservation]) -> [String] {
        var out: [String] = []
        let shared = min(a.count, b.count)
        for i in 0..<shared where a[i] != b[i] {
            var fields: [String] = []
            if a[i].text != b[i].text { fields.append("text") }
            if a[i].boundingBox != b[i].boundingBox { fields.append("boundingBox") }
            let fieldsStr = fields.joined(separator: ", ")
            let aText = a[i].text.count > 40 ? String(a[i].text.prefix(37)) + "…" : a[i].text
            let bText = b[i].text.count > 40 ? String(b[i].text.prefix(37)) + "…" : b[i].text
            out.append("[\(i)] CHANGED:\(fieldsStr)  '\(aText)' → '\(bText)'")
        }
        if b.count > a.count {
            for i in a.count..<b.count {
                let t = b[i].text.count > 40 ? String(b[i].text.prefix(37)) + "…" : b[i].text
                out.append("[+\(i)] ADDED    '\(t)'")
            }
        }
        if a.count > b.count {
            for i in b.count..<a.count {
                let t = a[i].text.count > 40 ? String(a[i].text.prefix(37)) + "…" : a[i].text
                out.append("[-\(i)] REMOVED  '\(t)'")
            }
        }
        return out
    }

    // MARK: - Date helpers (UTC, filename-aligned)

    /// Parse a `YYYY-MM-DD` string (or the literal `"today"`) into a
    /// UTC `Date` representing the start of that day. Returns nil for
    /// invalid input. Used by the CLI to translate `--date` flag input
    /// into the value `filter(date:)` expects.
    public static func parseDateFlag(_ input: String, now: Date = Date()) -> Date? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "today" {
            return Self.utcCalendar.startOfDay(for: now)
        }
        // YYYY-MM-DD strict match. ReceiptWriter's filename format.
        // We do shape validation FIRST because DateFormatter normalizes
        // separator characters even with `isLenient = false` — it
        // accepts "2026/05/23" as a match for `yyyy-MM-dd` and silently
        // resolves to the same date. Operator typos must surface as
        // parse failures, not auto-correct to a possibly-different
        // intended date.
        guard trimmed.count == 10,
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)] == "-",
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)] == "-" else {
            return nil
        }
        // Year/month/day positions must all be ASCII digits.
        for (i, ch) in trimmed.enumerated() where i != 4 && i != 7 {
            guard ch.isASCII, ch.isNumber else { return nil }
        }
        // Reviewer-caught Sev-1: explicit month/day range validation
        // BEFORE handing off to DateFormatter. `isLenient = false`
        // documents separator strictness but Foundation's contract for
        // calendar-overflow rejection (e.g. "2026-02-30" → March 2 vs
        // nil) is platform-dependent. Range-check here so the
        // CLI's behavior doesn't silently depend on Foundation
        // internals — operator typos surface as parse failures
        // regardless of OS version.
        let parts = trimmed.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else {
            return nil
        }
        let df = DateFormatter()
        df.calendar = Self.utcCalendar
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        df.dateFormat = "yyyy-MM-dd"
        df.isLenient = false
        // Final calendar-day validation. DateFormatter handles
        // month-specific upper bounds (Feb 30, Apr 31 etc.) on
        // platforms where `isLenient = false` enforces them; on
        // platforms where it doesn't, our 1-31 day pre-check has
        // already rejected the most egregious cases. The remaining
        // gap (Feb 30 on a lenient Foundation) is acceptable —
        // a parsed Date for Feb 30 would resolve to March 2 in the
        // UTC calendar, and `filter(date:)` matches by UTC y/m/d
        // components, so the operator would see "no receipts" for
        // March 2 (which is what they didn't ask for) — a wrong-day
        // surprise but not a security issue. Documented gap.
        return df.date(from: trimmed)
    }

    private static let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// Whitelist of action types whose `text` field is STRUCTURALLY
    /// safe to print without `--show-text`. These types carry only
    /// non-sensitive operational content:
    ///   - `keyCombo`: "cmd+v", "ctrl+shift+t" etc.
    ///   - `menuSelect`: menu paths like "File > New Note"
    ///   - `switchApp`: bundle IDs
    /// Everything else — including `.typeText` and any future or
    /// hallucinated action type where the schema doesn't constrain
    /// `text` — gets redacted by default. Defense-in-depth against a
    /// model emitting sensitive content in `text` on an action whose
    /// canonical `text` use isn't sensitive.
    static func textAlwaysSafe(_ type: ActionType) -> Bool {
        switch type {
        case .keyCombo, .menuSelect, .switchApp:
            return true
        default:
            return false
        }
    }

    /// Constructed fresh per render call. ISO8601DateFormatter is not
    /// `Sendable` in Swift 6.2; a static-let cache would trip
    /// concurrency-safety diagnostics. The CLI renders ≤30 entries per
    /// invocation so allocation cost is negligible.
    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    // MARK: - Phase G4: confidence report

    /// Pure, testable summary of a real session's receipts. The whole point
    /// of dogfood burn-in is structured evidence instead of vibes — point
    /// this at a day's receipts and read the rates. Categories key off the
    /// executionResult conventions the orchestrator already writes, so the
    /// report can't drift from the code: "error:" (executor threw),
    /// "stalled-" (a detector fired), "superseded" (29b stale-approval),
    /// "yielded" (40a operator drift). approved==false with none of those =
    /// a human/expiry rejection.
    public struct ConfidenceReport: Equatable, Sendable {
        public var total = 0
        public var executedClean = 0     // approved, ran, no error/supersede/yield
        public var errored = 0           // executionResult "error:"
        public var stalled = 0           // "stalled-<detector>"
        public var superseded = 0        // 29b
        public var yielded = 0           // 40a operator drift
        public var rejected = 0          // approved==false, not stalled/yielded/expired-tagged
        public var tierCounts: [String: Int] = [:]      // auto/preview/confirm
        public var typeCounts: [String: Int] = [:]      // click/typeText/...
        public var problems: [String] = []              // human-readable failure lines
    }

    public static func confidenceReport(_ entries: [ActionLogEntry]) -> ConfidenceReport {
        var r = ConfidenceReport()
        r.total = entries.count
        for e in entries {
            r.tierCounts[e.tier, default: 0] += 1
            r.typeCounts[e.action.type.rawValue, default: 0] += 1
            let res = e.executionResult
            if res.hasPrefix("error:") {
                r.errored += 1
                r.problems.append("error  \(e.action.type.rawValue): \(res)")
            } else if res.hasPrefix("stalled-") {
                r.stalled += 1
                r.problems.append("stall  \(e.action.type.rawValue): \(res)")
            } else if res.hasPrefix("superseded") {
                r.superseded += 1
            } else if res.hasPrefix("yielded") {
                r.yielded += 1
            } else if !e.approved {
                r.rejected += 1
            } else {
                r.executedClean += 1
            }
        }
        return r
    }

    public static func renderConfidenceReport(_ r: ConfidenceReport, scope: String) -> String {
        func pct(_ n: Int) -> String {
            guard r.total > 0 else { return "  0%" }
            return String(format: "%3d%%", Int((Double(n) / Double(r.total) * 100).rounded()))
        }
        func line(_ label: String, _ n: Int) -> String {
            "  \(label.padded(to: 22))\(String(n).padded(to: 5))\(pct(n))"
        }
        var out = "Confidence report — \(scope)\n"
        out += "  \(String(repeating: "─", count: 32))\n"
        out += line("actions total", r.total) + "\n"
        out += line("executed clean", r.executedClean) + "\n"
        out += line("errored", r.errored) + "\n"
        out += line("stalled", r.stalled) + "\n"
        out += line("superseded (stale)", r.superseded) + "\n"
        out += line("yielded (you took over)", r.yielded) + "\n"
        out += line("rejected/expired", r.rejected) + "\n"
        let tiers = r.tierCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: "  ")
        out += "  tiers: \(tiers.isEmpty ? "—" : tiers)\n"
        let types = r.typeCounts.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: "  ")
        out += "  types: \(types.isEmpty ? "—" : types)\n"
        if r.problems.isEmpty {
            out += "  no errored or stalled actions.\n"
        } else {
            out += "  problems (\(r.problems.count)):\n"
            for p in r.problems.prefix(40) { out += "    • \(p)\n" }
            if r.problems.count > 40 { out += "    … and \(r.problems.count - 40) more\n" }
        }
        return out
    }
}

private extension String {
    /// Right-pad to `width` with spaces. If longer AND `truncate` is
    /// true, cut at `width - 1` and append `…`. Used by the snapshot
    /// table renderer to align columns at fixed widths.
    func padded(to width: Int, truncate: Bool = false) -> String {
        if count >= width {
            if truncate && count > width {
                return String(prefix(width - 1)) + "…"
            }
            return self
        }
        return self + String(repeating: " ", count: width - count)
    }
}
