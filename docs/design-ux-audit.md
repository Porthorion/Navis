# Navis Design, UX, and Motion Audit

**Status:** First priority implemented; remaining items proposed
**Updated:** 2026-08-13
**Scope:** Desktop (Linux, Windows, macOS) and mobile (Android, iOS) Flutter
clients. This is an implementation and visual-system audit, not a redesign.

## Executive summary

Navis has a strong foundation: clear feature ownership, adaptive shells,
content-led music browsing, shared cover-art loading, and a purposeful desktop
player. The greatest opportunity is not more visual decoration. It is making
the existing product behave as one coherent system: predictable navigation,
stable artwork, consistent hierarchy, and motion that conveys intent rather
than competing for attention.

The first release-sized improvement should fix the album-open transition. It
is currently only reliable from the primary Albums grid. Other entry points
build different Hero tags, so their motion falls back to the page transition.
Where a Hero does match, the Hero flight, route fade/slide, image loading, and
destination-specific artwork composition can all change at once. That explains
the reported inconsistency and makes a one-frame blank or shape jump plausible.

**Implementation status (2026-08-13):** the first focused fix is complete.
It transfers the tapped source tag through album navigation, reuses that tag at
the destination, preserves the source 600 px cache key and source radius in a
single shared flight, removes the mobile-specific blank-capable shuttle, and
suppresses the competing album-route slide when a Hero is present. Explicit
source coverage now includes Home, Library views, Search, Artist, and Genre.
The Linux isolated-clone route and clean-restart captures are inspected; the
shared Hero and mobile-detail widget coverage pass. Physical Android/iOS
motion capture remains part of the upcoming screenshot review before a release
is certified.

Priority order:

1. Stabilise album artwork navigation and add frame-level coverage.
2. Establish one motion, surface, and accessibility contract shared by desktop
   and mobile.
3. Improve scanability and hierarchy in the desktop workspace, then improve
   mobile navigation and detail-page readability.
4. Add visual regression coverage for representative real-data states and
   adaptive boundaries.

## Evidence and limits

The audit covered the application shell; Home; Library and artist, album,
genre, radio, and playlist detail; Search; player, queue, lyrics, and mini
player; Downloads; Settings; authentication; Match Flow; shared artwork;
theme; and desktop primitives. I inspected the existing Linux app-owned
presentation captures for standard desktop, compact desktop, Desktop View,
and Mini Player, as well as the current widget and golden coverage.

The current environment provides Linux visual evidence only. Mobile findings
are verified from the adaptive implementation and widget tests, but still need
an Android and iOS device pass before a mobile visual change is accepted. No
unredacted user screenshots or library data are retained by this document.

Priorities use **P0** (visible defect/regression), **P1** (high-frequency or
high-confidence usability/accessibility improvement), and **P2** (important
polish or validation gap). Impact describes user benefit; effort is relative
implementation and QA cost.

## Findings

| ID | Priority | Finding | Evidence | Recommendation | Impact / effort |
| --- | --- | --- | --- | --- | --- |
| H1 | P0 | Album Hero tags are not shared by every album entry surface. Album detail uses the `album` context, but Home, year, and liked surfaces use different contexts. Those taps cannot pair with the destination Hero. | `hero_cover_art.dart`; `album_detail_screen.dart`; `home_screen.dart`; `library_screen.dart` | Pass the selected source's Hero identity into album navigation and use that exact identity on the destination. Do not derive it again from a generic destination context. | Very high / medium |
| H2 | P0 | Some source tags fall back to cover-art ID rather than album ID. Multiple visible albums sharing one cover can therefore have duplicate Hero tags; other source tags include route-specific text that cannot match the detail screen. | `buildCoverArtHeroTag`; year and liked album cards | Introduce an `AlbumHeroSpec` with `albumId`, a unique source key, source bounds/shape contract, and a graceful no-Hero fallback. Ensure only the tapped source is enabled when the same album appears twice on one route. | Very high / medium |
| H3 | P0 | The album route applies a 280 ms fade-and-slide while the Hero itself animates. Flutter gives the destination Hero's shuttle precedence: mobile therefore replaces the shared shuttle with a full-bleed image/gradient/title stack, while desktop uses another `HeroCoverArt` shuttle. These simultaneous, platform-specific transitions make the perceived start/end state vary by platform and entry point. | `app_router.dart`; desktop and mobile branches in `album_detail_screen.dart`; Flutter `heroes.dart` | Use one album-detail transition recipe. When a Hero is available, make it the primary motion; defer non-art content fade until the artwork is established. Use a simple no-Hero fade for fallback navigation. | Very high / medium |
| H4 | P0 | The desktop source card requests 600 px art, but the destination `HeroCoverArt` is configured with `size: 300`; because its shuttle wins, it requests/locks the 300 px cache key during flight. That is a cold cache miss by design and may show a placeholder. On mobile, the destination uses 600 px but can render an empty `SizedBox` when `showLoadingPlaceholder` is false. Both paths build a fresh image widget rather than holding a guaranteed decoded image. | `cover_art_cache_manager.dart`; `hero_cover_art.dart`; desktop and mobile album headers; `cover_art_image.dart` | Keep the source's stable image cache key through the entire flight (600 px can still be laid out at 260 logical px). Precache it before push, pass a stable `ImageProvider`/decoded image into the shuttle, and use `gaplessPlayback`. Never use a transparent destination as the only visual during a Hero flight; retain the source image until the destination has painted. | Very high / medium |
| H5 | P1 | The source card is clipped by its ancestor `Card`, but the Hero shuttle itself is not given the card's radius. The flight can start square before it reaches the mobile full-bleed square destination, creating a corner pop. | `album_card.dart`; `hero_cover_art.dart`; `album_detail_screen.dart` | Put the source radius in `AlbumHeroSpec` and animate a `ClipRRect`/shape tween inside one shared flight widget. The artwork should begin at the exact visible source shape. | High / low |
| H6 | P1 | The fullscreen artwork viewer stacks two independently loading `CoverArtImage` widgets at different sizes. It can double-fetch/decode and makes its image readiness nondeterministic. | `cover_art_viewer.dart` | Use one low-resolution image until the high-resolution image has decoded, then cross-fade exactly once; keep the viewer transition separate from album-detail navigation. | Medium / low |
| M1 | P1 | Motion timings and curves are scattered across routes, sheets, player overlays, Home, Settings, and artwork. `DesktopTokens` defines only part of the system. There is no app-wide reduced-motion path. | `app_router.dart`; `desktop_tokens.dart`; shared widgets and feature presentations | Add semantic motion tokens (instant, feedback, navigation, surface) and a `MotionPolicy` that respects platform animation disabling and a Navis appearance preference. Apply it first to route, Hero, player-sheet, queue, and carousel motion. | High / medium |
| M2 | P1 | Mobile bottom-navigation labels are always hidden. The interface relies on four icons even for infrequent destinations such as Library and Settings. | `app_shell.dart` | Show the selected destination label, or use an onboarding/discoverability mode that does. Keep labels visible at large text sizes and test phone landscape with the player present. | High / low |
| M3 | P1 | Compact landscape rail navigation uses raw `GestureDetector` + icon widgets without an explicit semantic label or tooltip. This weakens keyboard/screen-reader discoverability compared with the desktop rail tiles. | `app_shell_navigation_widgets.dart` | Use `Semantics(button: true, label: ...)` and tooltip-capable button primitives for compact rail destinations; preserve the current large hit targets. | High / low |
| M4 | P1 | Status notices are visually polished but are not declared as a live region. Time-limited feedback can be missed by assistive technologies and by users focused elsewhere. | `app_notice.dart` | Announce notices with a concise live-region semantic label, reserve error notices until dismissed or provide a clear action, and avoid replacing a critical notice with a routine success message. | High / low |
| D1 | P1 | Desktop is visually content-rich, but dark surfaces, cards, and the black workspace sit close together in value. In dense album and track views, this makes section boundaries and secondary metadata harder to scan than necessary. | Linux app-owned desktop captures; `navis_theme.dart`; `desktop_primitives.dart` | Define an explicit desktop elevation/surface ladder, verify contrast for text and interactive states, and use fewer but more meaningful panels. Keep the player visually anchored without making every Home section equally card-like. | High / medium |
| D2 | P1 | The desktop component vocabulary is only partially centralised. `DesktopPanel`, `DesktopCard`, raw `Card`, and custom containers are used for similar jobs, so spacing, radius, hover, and border behavior can drift. | `desktop_primitives.dart` and feature screens | Make desktop primitives the default for workspace panels, list rows, section headers, and album cards. Document permitted exceptions for immersive artwork and full-bleed player views. | High / medium |
| D3 | P1 | Settings group headings and several desktop-facing strings are hard-coded English while most visible copy is localized. This creates an immediately visible quality inconsistency in non-English builds. | `settings_screen.dart` | Move all settings group and desktop-description strings into `AppLocalizations`; audit desktop menus, tooltips, and empty states at the same time. | High / low |
| D4 | P2 | Desktop View and Mini Player have strong size-specific goldens, but those goldens are primarily loading/empty states. They do not assert hierarchy, truncation, or contrast with representative long metadata and active art. | `test/src/routing/goldens`; desktop layout tests | Add component goldens with deterministic representative metadata at 800x600, compact, standard, and ultra-wide layouts; include long title, remote indicator, disabled actions, and 130% text scale. | Medium / medium |
| D5 | P1 | The post-update changelog is a blocking dialog over Home, and its labels/version copy are partly hard-coded. Current entries also contain informal placeholder-style copy, which is shown in a first-run product surface. | `changelog_dialog.dart`; `changelog_entry_tile.dart`; `changelog_data.dart`; Linux app-owned Home capture | Reserve a blocking update dialog for critical action-required releases. For normal releases, use a dismissible, accessible in-app notice/card that opens the full changelog. Localize all labels and set editorial quality rules for release copy. | High / low |
| U1 | P1 | Mobile album detail puts white display text over arbitrary full-bleed cover art, relying on a fixed gradient and text shadow. It can become unreadable on pale artwork, and title presence changes between expanded and collapsed states. | mobile album header in `album_detail_screen.dart` | Base the scrim on measured artwork luminance or use a consistently opaque lower metadata surface. Keep title, artist, and primary actions in a stable location during collapse. | High / medium |
| U2 | P1 | Loading and empty/error states share good basic components, but they are generic and do not consistently express what content is unavailable, whether cached content remains usable, or the next best action. | `empty_state.dart`; `error_state.dart`; feature usage | Define state patterns for offline, empty library, filtered-to-empty, recoverable failure, and permission/authentication failure. Each should have one clear primary action and preserve usable cached content behind a non-blocking message. | High / medium |
| U3 | P2 | Responsive tests cover important breakpoints, but text-scaling coverage is sparse and animation state is not visually tested. Dense rows, fixed desktop controls, and mobile detail headers therefore lack a regression contract for large text. | adaptive/widget tests; existing goldens | Add 100%, 130%, and 200% text-scale checks per shared primitive; prefer wrapping/scrolling before clipping. Add visual assertions at phone compact, tablet medium, tablet expanded, compact desktop, standard desktop, and ultra-wide. | Medium / medium |
| U4 | P2 | High-frequency actions are visually spread across headers, overflow menus, bottom sheets, and player surfaces. The product needs a written action-placement policy so Play, Shuffle, Download, Like, Queue, and More appear in a predictable order at every entity level. | album, artist, playlist, Home, player, and context-menu implementations | Create an entity-action matrix, then harmonise icon order, labels, destructive-action placement, and long-press/secondary-click behavior. | Medium / medium |

## Album-open transition: target design

The target is a short, continuous artwork expansion that works from every
album card and has an equally calm fallback when no source card is available.
It should not animate the entire destination as though it were a modal.

1. On tap, capture an `AlbumHeroSpec` from the exact card: album ID, unique
   source tag, source rectangle/shape, image provider key, and whether the
   source is still mounted. Transfer it through `NavService.openAlbumDetail`.
2. Prewarm the same 600 px image used by the source before route push. If it
   cannot be read from memory/cache promptly, use the source rendering as the
   flight payload rather than a new placeholder-capable image widget.
3. Use one `AlbumArtFlight` for desktop and mobile. It owns clipping, image
   readiness, and the 220 ms forward / 180 ms reverse motion. It begins at the
   visible card radius and reaches the destination shape without a hard swap.
4. On mobile, the full-bleed art may grow into the flexible header, but title,
   metadata, and actions fade in after 20–30% of the flight. On desktop, art
   grows into the 260 px header art while title and controls fade/translate a
   few pixels independently. Neither version should run a second competing
   page slide over the art.
5. When no matching source exists (deep link, Home card disappeared, duplicate
   card, restore), use a 180 ms content fade with a prewarmed static image.
   This must be an intentional fallback, not an accidental missing Hero.
6. Keep the full-screen artwork viewer as a separate 170 ms fade/scale
   interaction; it should start only after the detail page is stable.

### Acceptance criteria

- Every album entry surface either supplies the selected source tag or uses
  the documented fallback; no duplicate Hero tag can exist in a route.
- No frame shows a transparent, placeholder, wrong-size, or wrong-radius
  artwork during push or pop on a cold cache and warm cache.
- Navigation works from Home, all Library album views, liked albums, search,
  artist detail, playlist detail, queue/now playing metadata, and deep links.
- Back gestures, desktop mouse Back, route restoration, and a source card
  scrolled out of view finish without exceptions or visual jumps.
- Tests cover source-tag transfer and duplicate handling. Frame captures at
  start, 25%, 50%, 75%, and end are reviewed on Android and Linux; iOS and
  Windows/macOS receive the same targeted validation before release.

## Delivery plan

### Phase 0 — Define the system (1–2 small changes)

- Add the design tokens: spacing, type roles, radii, surface/elevation ladder,
  focus/hover/pressed states, and semantic motion durations.
- Add `MotionPolicy`, including reduced motion, and document the chosen
  behavior: reduced motion retains state change and focus movement but removes
  travel, parallax, auto-advance, and nonessential shimmer.
- Produce an entity-action placement matrix and localization inventory.

**Exit evidence:** token unit tests, contrast audit for all theme modes,
localized-string audit, and component goldens for shared primitives.

### Phase 1 — Fix navigation and artwork (highest priority)

- Implement `AlbumHeroSpec`, selected-source transfer, `AlbumArtFlight`, and
  the explicit no-Hero fallback.
- Remove competing album-route movement when a Hero is active; preserve the
  generic route transition for non-art detail screens.
- Make art loading flight-safe, shape-consistent, and single-owner; simplify
  the fullscreen viewer's two-layer image load.
- Add deterministic Hero tests and app-owned animation-frame diagnostics.

**Exit evidence:** all acceptance criteria above, with cold/warm-cache Android
and Linux evidence, plus iOS and desktop-platform verification where available.

### Phase 2 — Navigation, hierarchy, and accessibility

- Restore mobile selected-nav labels and compact-rail semantics.
- Apply the desktop surface ladder and component primitives to Home, Library,
  Search, Settings, Downloads, and playlists.
- Rework mobile album/artist detail headers so text is always readable and
  primary actions remain stable while scrolling.
- Make notices accessible and define contextual empty/error/offline states.
- Localize all remaining visible strings; make normal release notes a
  non-blocking discovery surface rather than a Home interruption.

**Exit evidence:** accessibility/widget semantics tests, manual keyboard and
pointer pass on Linux, TalkBack and VoiceOver pass, and screenshots at each
adaptive class.

### Phase 3 — Polish the high-frequency playback loop

- Apply motion policy and token timing to player expansion, queue, lyrics,
  carousel, rating/like feedback, and mini-player transitions.
- Prefer immediate control response, then quiet confirmation; avoid stacking
  a snackbar, artwork motion, and sheet movement for one action.
- Verify long metadata, remote indicators, download/cache status, and disabled
  controls in active player layouts.

**Exit evidence:** focused player interaction tests, deterministic component
goldens, and smoothness inspection on a low/mid-tier Android device and a
minimum-size desktop window.

### Phase 4 — Regression guardrails and iteration

- Build a route × adaptive-class × state visual matrix for Home, Library,
  detail, Search, Downloads, Settings, queue, and player.
- Keep full-screen live-data captures for diagnostics only; use component
  goldens for stable contracts. Add visual diffs to review for every shared
  primitive or animation change.
- Run a short usability pass with both touch-first and mouse/keyboard users;
  rank follow-up changes by task completion friction, not visual novelty.

## Design guardrails

- Music and the current task are the hierarchy; artwork can be expressive but
  must not hide metadata or actions.
- One interaction gets one primary motion. Secondary information may fade, not
  race the primary motion.
- A control's location, icon order, feedback, and disabled behavior should be
  the same wherever that entity appears.
- Desktop uses density for scanability, never to conceal focus, state, or
  touch/keyboard target size. Mobile uses progressive disclosure, not icon-only
  ambiguity.
- Loading should preserve geometry and the last meaningful state whenever
  possible. A blank frame is never a loading strategy.

## Validation checklist for each UI change

1. Test phone compact, tablet medium/expanded, compact desktop, standard
   desktop, and ultra-wide where the component is shared.
2. Test light, dark, OLED, and a non-default accent; check normal and 130%
   text scale before adding a large-text exception.
3. Exercise cold cache, warm cache, offline/cached, loading, empty, error,
   disabled, and long-content states as relevant.
4. Capture app-owned screenshots for visible changes and inspect the affected
   region. Use deterministic component goldens for stable geometry/paint
   contracts.
5. Verify keyboard traversal, focus restoration, pointer affordances,
   screen-reader labels/live feedback, and reduced-motion behavior.
