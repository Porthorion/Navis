# Decision: Require a complete catalog before leaving first setup

- Date: 2026-09-20
- Status: superseded
- Supersedes: none
- Superseded by: [Automatic exit for isolated album detail failures](2026-09-20-fullscreen-sync-partial-readiness.md)

## Context

A first sync can safely promote part of a catalog while album hydration or
artist verification remains incomplete. The live audit observed four album
responses that remained incomplete across retries. A promoted generation is
useful recovery data, but it is not evidence that first setup finished.

## Decision

Keep first setup on the full-screen required library rebuild route until a
successful run has no pending hydration, verification, or candidate work and
durable complete-catalog evidence exists. Incomplete and failed runs remain on
that screen with retry, network/connection guidance, and sign-out. Do not admit
browsing of a partial first library. After completion, continue to onboarding
or Home as appropriate.

## Reasoning and alternatives

The user explicitly chose the intended full-screen setup experience over
admitting a partial library with warnings. This makes the readiness boundary
clear and avoids presenting incomplete album data as a finished initial setup.
The alternative, partial browsing with background retries, was considered but
not adopted.

## Consequences

Intermittent failures can be retried without discarding a safely promoted
candidate. A server that persistently returns incomplete required album data
can keep setup blocked until the response is corrected; retry and sign-out
remain available. The route and screen controller must use the same completion
evidence, including after process restart. This decision does not change the
readiness policy for an already completed profile's later incremental syncs.
