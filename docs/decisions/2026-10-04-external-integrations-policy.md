# Decision: External integrations are governed by one user-controlled policy

- Date: 2026-10-04
- Status: accepted
- Supersedes: none
- Superseded by: none

## Context

Navis grew several optional connections to services other than the user's
Subsonic server: Last.fm (Same Vibes mixes, radio, top songs), ListenBrainz
(scrobbling, feedback, weekly playlists), LRCLIB lyrics, the update feed, the
AutoEQ catalogue, radio station metadata, artwork the server links to, and now
Deezer (issue #46). Each had, at most, its own ad hoc switch (`useLrclib`,
`updateCheckEnabled`, `listenBrainzScrobblingEnabled`,
`legacyInstantMixEnabled`), so there was no single answer to "does Navis talk to
anything besides my server?" and no way to turn off one feature of a service.

## Decision

- A single policy decides every external request. The user controls a master
  "Online services" switch (off means Navis only talks to the server), one
  switch per service and one per feature. Everything is on by default.
- A feature whose service lacks a verified credential (Last.fm key,
  ListenBrainz token) is shown but cannot be switched, with a reason.
- Where a Subsonic alternative exists, a disabled feature falls back to it.
  Artist Top Songs has none, so its section is hidden and "This Is <Artist>"
  becomes a shuffle of the artist's library songs.
- The Instant Mix mode is the Last.fm "Same Vibes mixes" switch (on is Same
  Vibes, off is Server Mix). The separate Playback settings switch is removed.
- The four existing switches keep their columns. `legacyInstantMixEnabled`
  stays inverted. Only features without a column are stored in a new JSON set,
  next to a master column and a "notice dismissed" flag (schema 91).
- The policy is a pure value object, derived from scalar settings, and fails
  closed while settings load. Enforcement at each call site follows in later
  changes; this change adds the model, storage, provider and runtime control.

## Reasoning and alternatives

- Reusing the existing columns avoids a data migration and keeps every reader
  and diagnostics script (`tool/perf_diagnostics.py`,
  `tool/artist_playback_diagnostics.py` and others) working unchanged. The
  alternative of migrating all switches into one JSON set was rejected: it
  rewrites user data and breaks those readers for no user-visible gain.
- Keeping the new columns out of the full-row `saveSettings` follows the
  existing rule for fields owned by a dedicated writer (playback adjustments,
  download preferences): a stale screen snapshot must not overwrite them.
- Failing closed while settings load costs a brief empty state at startup but
  guarantees no request leaves before the user's choice is known.
- Verification is a property of the service, not a user switch, so a missing key
  or token reads as "not verified" rather than "off" and clears itself when the
  credential appears.
- The Home notice flag defaults to unseen for new installs too. Finishing
  setup marks it seen, because setup's Integrations step has just shown the
  same choices; skipping setup leaves it pending, so the note appears once.
  The default for the ListenBrainz scrobbling column is decided by the UI work
  that follows; unknown here.

## Consequences

- Any new external call must name an `IntegrationFeature` and consult
  `IntegrationPolicy` (provider, or `integrationPolicyFromSettings` for code that
  reads fresh settings).
- Integration settings have targeted writers in `AppSettingsDao`:
  `setIntegrationEnabled`, `setExternalIntegrationsEnabled`,
  `updateIntegrationPolicy`, `updateLegacyInstantMixEnabled`,
  `updateListenBrainzScrobblingState`, `updateLastFmApiKey` and
  `updateIntegrationsNoticeDismissed`. `saveSettings` still writes the legacy
  feature columns, while `resetDefaults` resets the policy through these
  writers.
  Settings › Integrations changes them at any time, and setup's Integrations
  step writes the master and service switches once, on Finish; Playback and
  About no longer hold copies of their switches.
- `updateProvider` honours a manual "Check now" while automatic checks are off.
- Clone diagnostics can read and change the policy through
  `GET/POST /v1/presentation/integrations`.

### Compliance follow-up — 2026-10-07

Radio playback checks the master switch before changing transport or queue state. Stations on the configured server host remain available; host comparisons ignore case.

### Compliance follow-up — 2026-10-07

ListenBrainz disconnect changes the connection only after secure token deletion succeeds and shows a retry notice on failure. Every server sign-out attempts token deletion and resets its connection, logging failures without blocking sign-out.

### Compliance follow-up — 2026-10-07

Credential redaction also covers Last.fm `api_key`, including encoded query parameters, and refuses those URLs as media-session inputs.
