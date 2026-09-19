# Review by openai/gpt-6-astra

_tokens in 21695 / out 7000 · 133s_

**The default-on reaper is not safe.** It identifies a command-line output format as ownership, treats adoption by launchd as proof of leakage, and loses process identity before escalating to SIGKILL.

Line references below count from the supplied files. This is a static review; notification delivery, runtime cost, and appearance behavior require testing on macOS.

## BLOCKER

### 1. `Sources/Health.swift:208–247` — “Summarizer” means any Claude process using streaming JSON

**Wrong:** `--output-format stream-json` is a public execution mode, not a claude-mem fingerprint. Legitimate SDK clients, automation, and long-running agents use it. There is no worker identity, job ownership, heartbeat, terminal check, or evidence of abandonment.

The executable test is also weak:

```swift
return a0.hasSuffix("/claude") || ...
```

Any executable invoked with an `argv[0]` ending in `/claude` passes, regardless of its resolved executable. Argument matching also scans operands indiscriminately: a prompt containing a flag-shaped argument can be mistaken for an option.

**Real-machine impact:** A legitimate streaming job is terminated after 30 minutes. “Interactive sessions never killed” is a claim made by this classifier, not an independently enforced invariant.

**Fix:** Disable automatic killing of externally discovered Claude processes. Establish ownership at launch: a worker/job registry containing exact process identity, worker identity, purpose, and a liveness/lease mechanism. Only abandoned, positively identified jobs should become automatic targets.

For advisory discovery, validate the actual executable and parse the CLI grammar, including `--` and option operands. A terminal check and ancestry verification are additional exclusions, not sufficient proof of ownership.

### 2. `Sources/Health.swift:303–309, 530–554` — PID-reuse protection disappears before SIGKILL

**Wrong:**

- `stillSame` compares only whole start-time seconds.
- The escalation list stores bare PIDs.
- After two seconds, the only checks are existence and effective UID.
- A process can also `exec` another executable without changing its PID or start time.
- Initial sampling can combine BSD identity from one process incarnation with path/arguments from another.

**Real-machine impact:** A successfully terminated process can have its PID recycled. The escalation then kills the replacement process belonging to the same user. The two-second delay makes this a materially larger window than an ordinary immediate check/signal race.

**Fix:**

- Store raw `pbi_start_tvsec` **and** `pbi_start_tvusec`, not a `Date` converted back to seconds.
- Retain full target identities through escalation.
- Verify identity before and after collecting a candidate’s path/arguments.
- Before each signal, recheck identity, executable, credentials, and eligibility.
- Explicitly exclude this process and protected worker identities.

At minimum:

```swift
struct ProcessIdentity: Equatable {
    let pid: pid_t
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

// Preserve identities, not [pid_t].
var termSent: [VerifiedTarget] = []
```

These checks **reduce** the race; they do not eliminate it. A `proc_pidinfo` check followed by `kill(pid, ...)` is not atomic. The public APIs used here provide no PID-bound signal handle. If “never kill a replacement process” is a requirement, this externally discovered PID-based reaper cannot satisfy it. Use an owned supervisor/cooperative cancellation architecture instead.

### 3. `Sources/Health.swift:185–195, 216–219, 541–548` — Chrome ownership and child eligibility are invented

**Wrong:** `ppid == 1` does not establish that a browser is abandoned.