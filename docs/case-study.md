# Case Study: macOS Agent v0

> Building a desktop agent for a specific need, and being honest about what it
> can and cannot do.

This is the story of why I built a native macOS agent the way I did, the
engineering decisions that mattered, and an unusually candid account of what is
proven versus unproven. The short version: most desktop-agent demos optimize
for looking capable. I optimized for being trustworthy and for *knowing the
difference*.

---

## 1. The need

Agents that operate a computer are usually built capability-first and
cloud-first: maximize the number of tasks they can complete, ship the screen to
a server, and treat safety as a wrapper. That leaves a real user unserved: the
person who needs the machine to do the clicking but cannot or will not watch it
blindly.

Concretely, that is hands-free and accessibility-driven operation, and
neurodivergent operators who need predictable, non-time-pressured interfaces. For
that user the gating requirement is not "how many tasks can it do." It is "can I
trust it to touch my machine, and can I prove what it did afterward." That is the
need this project is built around.

Design consequences that fall directly out of the need:

- **Local-only.** No backend, no accounts, no network actions of the agent's
  own. Your Anthropic API key and your audit trail stay on your Mac.
- **Safety as a first-class layer**, not a wrapper. Every action is classified
  and gated before it can run.
- **Hands-free control.** Approve, reject, and abort from any app via function
  keys, drivable by macOS Voice Control.
- **An audit trail by construction.** Every action, approved or rejected, writes
  a signed local receipt.

## 2. The product

The agent runs one loop: **observe, think, gate, act, receipt.**

- **Observe** reads the frontmost app's Accessibility tree, falling back to
  ScreenCaptureKit + Vision OCR when the tree is sparse, and produces a single
  tamper-evident perception snapshot. The agent excludes its own windows.
- **Think** sends that snapshot to Claude, which returns exactly one action.
- **Gate** runs a three-layer safety classification (see below) and, for
  anything non-trivial, blocks on an on-screen approval card.
- **Act** posts real `CGEvent` / `AXUIElement` actions.
- **Receipt** appends a JSONL audit entry for the action, whether it ran or not.

Full spec: [`MANIFEST.md`](../MANIFEST.md). Build history: [`PHASES.md`](../PHASES.md).

### The safety model

Three layers, each a hard floor for the one above it:

1. **`SafetyPolicy.classify()`** assigns every action a tier (AUTO / PREVIEW /
   CONFIRM) from action type, target label, app context, and dangerous-text
   patterns. It cannot be overridden by the model, by persisted memory, or by
   user rules.
2. **Autonomy mode** (Manual / Semi / Auto / Watch) can tighten the floor, never
   loosen it for destructive or sensitive actions.
3. **Capability rules** (per-app, per-action allow/ask/deny) can widen, but are
   floor-bound: an allow rule cannot auto-approve a destructive action.

A CONFIRM action can never be auto-approved by any mode. An unanswered gate
parks and heartbeats indefinitely rather than auto-resolving, because for a
hands-free operator a timed auto-reject would kill every run. The adversarial
test catalog ([`RED-TEAM.md`](../RED-TEAM.md)) covers AX and Vision injection,
memory poisoning, identity spoofing, excessive agency, and loop/DoS abuse.

## 3. The decisions that mattered

- **Zero external dependencies.** Pure Swift 6.2 against the platform
  frameworks. Smaller supply-chain surface, and nothing to audit but my own
  code.
- **One serial driver, on purpose.** There is a single mouse and keyboard. I
  rejected concurrent multi-agent designs because two agents would fight one
  cursor. Delegation, when it comes, will be *sequential* handoff, not
  concurrency.
- **Park, do not time out.** Gates park and heartbeat instead of auto-rejecting
  after a fixed interval. This is the one decision a casual reviewer would get
  wrong, and it is the decision the target user most needs.
- **Shell execution deferred.** The agent already drives Terminal under a CONFIRM
  gate; a direct shell-exec primitive was a capability I chose not to add yet.
  Recorded as a decision, not an omission ([`design-fileops-shell.md`](design-fileops-shell.md)).
- **Receipts are cleartext and local.** The audit trail records exactly what the
  agent did, including approved keystrokes. That is a deliberate
  integrity-over-convenience trade, disclosed in-app and in the README.

## 4. The honest audit (the part most demos skip)

After the build I ran a confidence audit on my own work, and the finding is the
most important thing in this repo:

**The project has two confidence numbers, and they are not the same.**

- **Safety and logic design: high.** 643 tests, multiple adversarial code
  reviews, an independent security review, and live verification that the gates
  actually block, reject, and abort on a real machine.
- **Real-world task capability: low and unproven.** Every automated test mocks
  the three things that touch reality: perception, the model, and the executor.
  They prove decision *logic* and *safety policy*. They do not prove the agent
  drives a real app correctly. On real apps it over-navigates and produces
  Accessibility-error receipts. That is a capability gap, not a safety gap:
  every fumble is still gated.

The root cause is that the execution loop is **open**. The agent acts and writes
a receipt that says "clicked," but nothing verifies the click did what it
intended. The replay tool's "executed clean" means "the executor did not throw,"
not "the UI changed as intended." Until that signal exists, there is no
instrument that can tell a *safe* agent apart from a *capable* one.

I would rather ship that sentence than a demo GIF that hides it.

## 5. The roadmap

The forward plan ([`confidence-capability-roadmap-2026-06-16.md`](confidence-capability-roadmap-2026-06-16.md))
turns that finding into ordered work:

- **Phase H** builds the missing instrument first: closed-loop outcome
  verification, so a receipt records whether the action achieved its intended
  post-condition, and the report shows real success rather than "did not
  throw."
- **Phase I** is measured burn-in: run real tasks, read a real success rate.
- **Phase J** is sequential sub-agent delegation (a parent hands a scoped in-app
  job to a focused child, single-driver preserved), which is architecturally
  compatible in a way concurrent multi-agent is not.
- **Phases K and L** add voice task entry and a more immersive chat/voice
  surface, deliberately last, as polish on a proven core.

The roadmap is explicit about what is *fundamentally* hard (concurrent
multi-agent) versus *incrementally* hard (voice, immersion, longer-horizon
autonomy), so effort goes where it actually moves the needle.

## 6. What this demonstrates

If you are evaluating this as work, here is what I think it shows:

- **Product judgment:** identifying a specific underserved user and letting the
  need drive the architecture, rather than chasing a capability leaderboard.
- **Safety engineering:** a layered, floor-based gating model that the model and
  persisted state cannot override, with an adversarial test catalog and an
  audit trail by construction.
- **Intellectual honesty:** the discipline to audit my own project, name the gap
  between safe and capable, and publish that gap instead of hiding it. The
  internal working docs (a verify-before-claim rule, bug-class and
  semantic-change audits) reflect the same posture.

An agent that operates your computer earns trust by being measurable, not by
being impressive. Building the measurement is the interesting part, and it is
where this project goes next.
