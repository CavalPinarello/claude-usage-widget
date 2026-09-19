# External reviews

Senior-model code reviews run over OpenRouter on the Mac health feature (2026-09-19, GPT-6 Astra, two passes).

Pass 1 returned three blockers (ownership-free fingerprint, identity lost before SIGKILL, ppid 1 taken as abandonment) and was cut off by its output limit. All three were applied.

Pass 2 returned seventeen findings and the verdict "ship diagnostics only until ownership and liveness are proven". Twelve were applied (validity of every metric, worker-only ownership, path-before-argv, helper-only Chrome children, strict argv parser, O_APPEND audit log, confirmed outcomes, honest Last-action row, coalesced scheduling with a 20 s promotion age, lifecycle, health-before-Keychain startup, kernel pressure mask).

Deliberately NOT taken: auto-reap default off (the owner of the leaked processes is a third-party plugin that cannot be fixed from here; the user asked for proactive intervention after repeated hard reboots; the `claude-hygiene hourly` bash tool applies the same 2-hour rule), a job registry / supervisor architecture, and test injection of the process layer. The reviewer's dissent stands on record here.
