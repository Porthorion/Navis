# Navis Design, UX, and Motion Audit

**Status:** Core audit implementations approved across desktop and Android;
remaining work is targeted validation and maintenance
**Updated:** 2026-08-17
**Scope:** Desktop (Linux, Windows, macOS) and mobile (Android, iOS) Flutter
clients. This is an implementation and visual-system audit, not a redesign.

> The 2026-09-30 follow-up audit, which covers typography, component themes,
> action hierarchy and remaining desktop/mobile defects, is in
> [audits/ux-ui-audit-2026-09-30.md](audits/ux-ui-audit-2026-09-30.md).

## Executive summary

Navis has a strong foundation: clear feature ownership, adaptive shells,
content-led music browsing, shared cover-art loading, and a purposeful desktop
player. The greatest opportunity is not more visual decoration. It is making
the existing product behave as one coherent system: predictable navigation,
stable artwork, consistent hierarchy, and motion that conveys intent rather
than competing for attention.

The first release-sized improvement was the album-open transition. Its prior
inconsistency came from a matching artwork Hero flight, route fade/slide,
image loading, and destination-specific artwork composition changing at once.
That made a one-frame blank, shape jump, or duplicate transition plausible.

**Implementation status (2026-08-14):** the first focused fix is complete and
approved on a physical Android device. Desktop and compact-wide album detail
retain their repaired shared-artwork Hero. Phone album detail instead renders
the normal artwork, gradient, title, and tracks as one stationary surface and
fades it in or out over 180 ms; it deliberately has no destination artwork
Hero, so neither open nor close can start a second moving-art flight.
It transfers the tapped source tag through album navigation, reuses that tag at
the desktop/compact destination, preserves the source 600 px cache key and
source radius in a single shared flight, and suppresses the competing
album-route fade and slide when a Hero is present.
The Hero is now the only animation allowed to affect the landing artwork;
otherwise the route-wide opacity handoff causes the reported brightness flicker.
Explicit
source coverage includes Home, Library views, Search, and Artist. The Genre
detail implementation that was covered at the time was removed by product
decision on 2026-09-30.
Source-card title, artist, badge, and gradient chrome—including the large Home
Random/desktop showcase variants—now remain hidden until the Hero return has
settled, then fade in as a separate short transition. The handoff is driven by
the Hero flight completion itself rather than route timing, so it cannot run
while the artwork is still moving.
The remaining settle flicker was caused by a separate image contract: the
flight used the requested 600 px decoded artwork while desktop/compact detail
headers could land on a layout-sized decode and a cached-image fade. All Hero
participants now share the requested decode size and use no image fade, so the
overlay hands off to the same opaque image variant.
The shared Hero, mobile-detail, and route-transition widget coverage pass. The
motion-system slice now honors the platform reduced-motion preference for
album/detail routes, the artwork-return metadata handoff, notices, expandable
player, queue, Like feedback, fullscreen artwork, and the Now Playing metadata
pager and compact-wide Queue, Mix, and Settings panels; normal-motion timing
uses the same shared policy. The
mobile bottom bar now keeps its clean four-icon layout but names the selected
destination, improving Library and Settings discoverability without altering
desktop navigation. Compact landscape rails retain their icon-only resting
layout, but now expose named, selected semantic buttons and a short hover
label for pointer users. Status notices now announce their concise message as
dismissible live regions. Errors remain visible until a person dismisses or
swipes them, and routine confirmations cannot overwrite an unresolved error.
Settings group headings and desktop-specific descriptions
now use the same localization contract as the rest of the app. The motion
policy now also removes the notice-surface fade and slide when the platform
requests reduced motion, and switches the expandable player surface without
travel. The queue now opens and dismisses without travel under the same
preference, and the Like control changes state without its decorative scale
feedback. Fullscreen artwork viewers also skip their route fade under reduced
motion. The
current Linux clone diagnostic can verify a settled detail frame but cannot
yet drive a mounted source card through the Hero flight; it therefore is not
used as proof of the animation itself. Live Linux and physical Android/iOS
motion capture remain required before a release is certified.

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

The current environment provides isolated Linux and Android-emulator visual
evidence. The emulator validates the rendered mobile layout and interactions,
but it is not a substitute for a physical Android accessibility pass or an iOS
device pass. No unredacted user screenshots or library data are retained by
this document.

Priorities use **P0** (visible defect/regression), **P1** (high-frequency or
high-confidence usability/accessibility improvement), and **P2** (important
polish or validation gap). Impact describes user benefit; effort is relative
implementation and QA cost.

## Findings

| ID | Priority | Finding | Evidence | Recommendation | Impact / effort |
| --- | --- | --- | --- | --- | --- |
| H1 | P0 | **Implemented 2026-08-13.** Album entry surfaces now pass the exact selected Hero tag through `NavService`, and album detail retains it instead of deriving a generic destination tag. | `navigation_service.dart`; `album_detail_screen.dart`; Home, Library, Search, Artist, and Genre entry surfaces; album-detail widget test | Keep all new album entry points on this explicit tag-transfer path. | Very high / medium |
| H2 | P0 | **Implemented 2026-08-13.** Hero tags use the album entity ID whenever available, so albums that share cover art are distinct; source context keeps independent on-screen presentations separate. | `buildCoverArtHeroTag`; Hero tag unit test | Preserve the entity-ID contract and add an explicit duplicate-same-route case whenever a surface intentionally renders the same album more than once. | Very high / medium |
| H3 | P0 | **Implemented 2026-08-13.** Album routes suppress their competing fade-and-slide when an opening Hero tag is present; the shared Hero now owns the artwork flight while the no-Hero path keeps a calm route fallback. | `app_router.dart`; `album_detail_screen.dart`; route-motion tests | Preserve the single-owner motion rule for future detail routes. | Very high / medium |
| H4 | P0 | **Implemented 2026-08-13.** The Hero shuttle holds the source decoded image contract, including its requested 600 px cache key, without a cached-image fade; destination headers use the same opaque handoff. | `hero_cover_art.dart`; `cover_art_image.dart`; Hero widget tests | Retain the locked source image contract and verify cold/warm cache frames on device before release certification. | Very high / medium |
| H5 | P1 | **Implemented 2026-08-13.** The shared Hero flight interpolates the visible source radius into the destination radius, avoiding the prior square-corner handoff. | `hero_cover_art.dart`; Hero widget tests | Keep source shape explicit whenever new artwork treatments are added. | High / low |
| H6 | P1 | **Implemented 2026-08-13.** The fullscreen artwork viewer now keeps its existing preview visibly stable while the full-resolution, zoom-ready image loads, cross-fades once only after that image has decoded, and removes the preview after the handoff. | `cover_art_viewer.dart`; `cover_art_image.dart`; artwork-viewer widget test | Preserve the one-owner preview → full-resolution handoff and requested-size decode; do not stack independently visible artwork loaders. | Medium / low |
| M1 | P1 | **Implemented 2026-08-15–16.** `MotionPolicy` controls navigation, Hero metadata feedback, transient notice surfaces, expandable player sheet, queue overlay, Like feedback, fullscreen artwork viewers, the Now Playing metadata pager, artwork-tinted Now Playing surface, Home carousels, and compact-wide Now Playing panels in response to the platform reduced-motion preference. Home carousels stop auto-advancing and use direct state changes. Now Playing art/lyrics, track metadata, artwork tint, Like feedback, and compact-wide Queue, Mix, and Settings panels settle immediately when reduced motion is enabled; normal surface changes use the shared 180 ms timing. Desktop right-pane panels are static surfaces and do not need a travel transition. | `motion_policy.dart`; `app_router.dart`; `hero_cover_art.dart`; `app_notice.dart`; `expandable_player_sheet.dart`; `app_shell_queue_overlay.dart`; `star_button.dart`; `cover_art_viewer.dart`; `now_playing_actions.dart`; `now_playing_metadata_panel.dart`; `now_playing_screen.dart`; `now_playing_wide_panels.dart`; `home_screen.dart`; adaptive widget and motion-frame golden coverage | Keep future overlays on `MotionPolicy`; verify platform-level Android and iOS preference propagation during release certification. | High / medium |
| M5 | P1 | **Implemented 2026-08-17.** Now Playing transport no longer starts a full-width visual swipe before issuing playback. The handler now publishes one outcome for touch, artwork swipes, keyboard, headset, and media-session controls. Successful mobile skips use a clean 220 ms artwork handoff—previous art drops away, incoming art settles without lateral travel, then metadata follows. Automatic advances use a short neutral focus fade; restart and unavailable edges retain artwork and use a dynamic-color edge pulse rather than a floating icon. Desktop remains intentionally quiet. | `playback_snapshot.dart`; `navis_audio_handler.dart`; `now_playing_screen.dart`; transport widget tests; authenticated clone-only presentation control | Keep mobile as the primary motion surface. Never delay audio transport for a visual effect, and preserve direct reduced-motion changes. | High / medium |
| M2 | P1 | **Implemented 2026-08-13.** Phone and medium-tablet bottom navigation use Material's `onlyShowSelected` behavior: the active destination stays named while the other three preserve compact icon treatment. | `app_shell.dart`; `app_shell_navigation_test.dart` | Preserve the selected-label rule at large text sizes and when player chrome is present. | High / low |
| M3 | P1 | **Implemented 2026-08-13.** Compact landscape rail destinations now retain their large icon hit targets while exposing named, selected semantic buttons and a 400 ms hover label. | `app_shell_navigation_widgets.dart`; compact-rail navigation goldens | Preserve this contract as rails evolve; keep labels localized and do not reintroduce icon-only controls without semantic names. | High / low |
| M4 | P1 | **Implemented 2026-08-15.** Status notices announce concise messages as live regions. Routine info/success notices remain lightweight and time-limited; errors persist until Dismiss or swipe, use a clearly visible Dismiss action, and cannot be replaced by routine success/info feedback. A newer error can supersede the stale recovery state. | `app_notice.dart`; app-notice lifecycle/semantic and recovery golden tests; clone-only presentation-notice capture | Preserve this error-priority policy. Add an in-notice retry only where a failure has a safe, single, local recovery action. | High / low |
| D1 | P1 | **Implemented and approved 2026-08-14–16.** Search, Library, Home, Downloads, Settings, Match Flow, Privacy, About, and Playlist Detail now use desktop-native continuous workspaces instead of detached rounded page cards. Search has a low-contrast command strip; Library relies on persistent sidebar section navigation; Home keeps headings and album rows on the shared canvas while retaining local album cards; Downloads consolidates its Back action, nested-page title, tabs, and contextual search into one strip; Settings uses group labels and preference rows directly on the canvas. Nested Sync Settings, Appearance, Configuration, Playback, Cache, Desktop Window, and Keyboard Shortcuts use constrained workspaces with an explicit return to Settings; Appearance gives its palette and selection controls a coherent reading width, Desktop Window keeps its Mini Player choices in a compact divider-separated group, Keyboard Shortcuts keeps command bindings as a direct reference list, Cache keeps its large storage sliders and destructive reset readable without stretching them across the full window, and Configuration keeps its destructive sign-out action distinct without turning it into a page-wide bar. Match Flow uses the full responsive desktop canvas for its flow list and keeps its primary creation action in the header instead of a mobile-style floating action button. Privacy uses that canvas as two responsive reading columns rather than one overlong text measure. About uses a responsive two-column overview that keeps app usage, links, and updates visible on wide screens. Playlist Detail now uses a full-width tonal header while keeping its tracks inset for scanning. At compact desktop sizes, Album Detail reduces only its hero artwork, keeps the core actions on one line, makes Download tooltip-backed, and compacts Rating/filters so the first tracks remain visible. Artist Top Tracks uses its artist-specific title even when it has no resolved tracks, instead of a generic Playlist label. A labeled rail suppresses duplicate page titles, while an icon-only rail restores compact orientation copy. Weekly playlist detail keeps its Back control but lets the content hero own its title. Sidebar autohide retains a 64 px icon rail rather than making navigation disappear. Tablet and phone retain their existing card-based layouts. | `search_screen.dart`; `library_screen.dart`; `home_screen.dart`; `downloads_screen.dart`; `settings_screen.dart`; `sync_settings_screen.dart`; `appearance_settings_screen.dart`; `server_settings_screen.dart`; `playback_settings_screen.dart`; `cache_settings_screen.dart`; `desktop_window_settings_screen.dart`; `desktop_shortcuts_settings_screen.dart`; `match_flow_screen.dart`; `privacy_screen.dart`; `about_screen.dart`; `playlist_detail_screen.dart`; `album_detail_screen.dart`; `artist_top_tracks_playlist_detail_screen.dart`; `app_shell_desktop_workspace.dart`; desktop adaptive/shell/visual-preview tests | Preserve continuous page framing for future desktop pages. Use container tones for the persistent sidebar, command strip, and player bar; reserve rounded surfaces for local groups rather than page frames. Use a capped reading width only for control-dense settings; collection and workflow pages should use available desktop width. | High / medium |
| D2 | P1 | **Resolved for the current routed client 2026-08-17.** A final production-reference inventory confirms the remaining raw `Card` use is intentional: local collection cards, authentication forms, player subpanels, or compact/mobile fallbacks. Current full-frame desktop routes use either a continuous workspace or one explicit local-grouping primitive; no routed desktop page mixes interchangeable page-frame treatments. | `desktop_primitives.dart`; routed production-reference inventory; `search_screen.dart`; `library_screen.dart`; Settings, Playlist Detail, Home, Match Flow, player, auth, and local-card exception review | Keep this exception taxonomy. New full-frame desktop routes must use a continuous workspace; use cards only for local collections, forms, or player subpanels. | High / low |
| D3 | P1 | **Implemented for the audited Settings, weekly-playlist, Library disabled-page, Home, desktop quick-search, shell-back, and Match Flow recovery surfaces 2026-08-16.** Group headings, Keyboard Shortcuts' command, capture, and built-in-binding copy, Privacy's policy titles and explanatory text, Appearance's dynamic-album-color, language-availability, color-fallback, color-picker, and custom-color semantic labels, Configuration's external-service fields, validation copy, and secret-field tooltips, weekly-detail titles, state copy, metadata, loading/status labels and actions, the Android battery-optimization prompt, Playback's fullscreen-lyrics controls, Match affordances, Match Flow's local constraint notices, Library disabled-page recovery copy, Home's Instant Radio label/tooltip, desktop quick-search's hint, submit tooltip, and filters, and the Android double-back exit prompt now use `AppLocalizations`. | `settings_screen.dart`; `desktop_shortcuts_settings_screen.dart`; `privacy_screen.dart`; `appearance_settings_screen.dart`; `server_settings_screen.dart`; `match_flow_dao.dart`; `match_flow_error_message.dart`; `app_shell_support_widgets.dart`; `playback_adjustment_panel.dart` (formerly `now_playing_speed_sheet.dart`); `navigation_service.dart`; `home_screen.dart`; `library_screen.dart`; `app_shell_quick_search_overlay.dart`; `app_en.arb`; Settings, Privacy, Keyboard Shortcuts, Configuration, Match Flow, weekly-detail, Library recovery, Home, desktop quick-search, and shell-back widget coverage | Continue the inventory through desktop menus, tooltips, and other empty states before adding further locales. | High / low |
| D4 | P2 | **Coverage completed 2026-08-15.** Deterministic active-player goldens cover representative long title/artist truncation at 800×600, standard-width and ultra-wide desktop metadata, and 130% text scale at the compact desktop size. Active and empty Mini Player states are also covered at 560×360 and 720×405; remote-source provenance is now pinned in both 800×600 Desktop View and 560×360 Mini Player fixtures. | `test/src/routing/goldens`; `app_shell_navigation_test.dart` | Keep representative fixtures whenever Desktop View or Mini Player metadata layout changes. | Medium / low |
| D5 | P1 | **Implemented 2026-08-14.** Normal post-update notes no longer block Home: a dismissible discovery card previews the release and opens the full changelog. Its labels are localized and the compact card remains usable at 200% text scale. | `home_screen.dart`; `home_support_widgets.dart`; `app_en.arb`; Home discovery-card widget/golden coverage | Reserve a blocking surface only for critical, action-required releases. Continue applying editorial quality rules to release copy. | High / low |
| U1 | P1 | **Implemented and approved on Android 2026-08-14.** The artwork-led mobile album header is retained by product choice. Album titles reduce from the display size only when that lets the full title fit in two lines; titles that still will not fit keep the established ellipsis. Phone album pages assemble normal art, gradient, title, and tracks, then fade that stationary surface in and out over 180 ms without a source/destination artwork Hero. Desktop and compact-wide layouts retain the repaired shared-artwork Hero. A 2026-08-16 card-contrast review confirmed that the existing two-stop metadata fade remains clearer than a globally stronger scrim, so the original shared-card treatment is retained. | `navigation_service.dart`; `app_router.dart`; `album_detail_screen.dart`; route-motion and mobile-detail widget tests; physical Android review; mobile shared-card before/after review | Preserve the title-fit and fade-only phone-page contract. Do not darken every shared card to solve a cover-specific concern; revisit contrast only with a targeted, evidence-based treatment that retains artwork hierarchy. | High / medium |
| U2 | P1 | **Resolved for audited states 2026-08-17.** The routed client distinguishes offline-with-cache, offline-without-library, filtered-to-empty, successful-empty, recoverable failure, unavailable detail, and missing queue data. Each audited state either preserves usable cached content or provides one direct, local recovery action; raw backend details remain in diagnostics. | `app_shell.dart`; Search, Library, Downloads, Radio, Album, Artist, Weekly, Playback, Sync Settings, Queue, Match Flow, and Android Library Sync notification coverage; isolated presentation captures | Preserve this state matrix for new routes and new asynchronous operations; do not collapse a new state into generic empty/error copy. | High / low |
| U3 | P2 | **Resolved for the current audit scope 2026-08-17.** The high-frequency shared components and constrained screen states now have normal, 130%, or 200% regression coverage where their geometry changes. The final pass adds 200% visual regression coverage for phone Artist Top Tracks and the 800×600 desktop Lyrics header with long track metadata; both remain readable without overflow. Motion state remains covered by the existing component and transition tests. | `album_card_adaptive_test.dart`; `library_screen_test.dart`; `library_detail_screens_test.dart`; `home_screen_test.dart`; `server_settings_screen_test.dart`; `about_screen_test.dart`; `app_shell_navigation_test.dart`; `now_playing_screen_adaptive_test.dart`; `queue_sheet_test.dart`; approved Android review; component goldens | Retain representative breakpoint and text-scale coverage whenever a shared component changes; prefer wrapping/scrolling before clipping. | Medium / low |
| U4 | P2 | **Resolved for the current routed client 2026-08-17.** A final visible-action inventory confirms all live Album, Artist, Playlist, Song, Home, Download, Search, Library, and Artist Top Tracks controls follow the shared direct-action/menu contract. Visible More controls expose localized labels; touch long-press and desktop secondary-click use the same action family; destructive actions remain last. Genre Detail was removed by product decision on 2026-09-30. | routed production-reference and visible-trigger inventory; shared context-menu tests; artist-action, playlist, song-menu, album-menu, downloaded-track-menu, desktop-context-menu, weekly-menu, Library-playlist, picker, and download-quality coverage | Preserve the matrix for future actions. Re-audit only when a new routed entity or owner action is introduced. | Medium / low |
| U5 | P1 | **Implemented and approved on desktop and Android 2026-08-15.** Artist detail now uses the artist name in the app bar, shows the collection count over the artwork where available, and makes Play the one filled action with tonal Shuffle and More support actions. Desktop shortens only its artwork header to reveal the album grid earlier; phone retains its taller immersive artwork header. Cached identity and the top-right More action remain present while artist detail data refreshes. | `artist_detail_screen.dart`; artist-detail widget/golden coverage; isolated Linux and Android emulator visual review | Retain the platform-specific header density, action hierarchy, and stable header contract. Continue to offer the direct action row only once playable local artist tracks are available; More remains usable while tracks hydrate. | High / medium |
| U6 | P1 | **Implemented and approved on Android 2026-08-16.** A queue entry whose local metadata fails to load now keeps technical details in logs, shows localized recovery copy, and exposes a direct Remove action in both the compact Queue sheet and full Queue page. The error title remains concise and consistent with the existing Queue vocabulary. | `queue_sheet.dart`; `queue_screen.dart`; `app_en.arb`; Queue sheet and full Queue behavior tests; approved Android before/after review | Preserve the safe-copy rule for all Queue failure states. Prefer direct, local recovery actions where the queue is mutable; keep the row read-only while a pending logical queue is loading. | Medium / low |
| U7 | P1 | **Implemented and approved on Android 2026-08-16.** The update dialog now keeps network, platform, and generic exception details in logs while showing concise recovery copy. Its existing Retry and Download Manually actions remain visible; signature mismatch and write-access states retain their explicit, decision-relevant treatment. | `update_dialog.dart`; `update_dialog_test.dart`; approved Android before/after review | Preserve this safe-copy rule for update failures. Review failed download and failed apply states on desktop and Android before release certification. | Medium / low |
| D6 | P2 | **Removed 2026-09-30** in the routing and navigation overhaul, after a production-reference audit. Previously confirmed 2026-08-17: `PlaylistsScreen` has no production router, import, or navigation reference. Its mobile-only owner-action sheet is therefore not a current client behavior and must not receive product-polish work ahead of the routed Library playlist surface. | `playlists_screen.dart`; `app_router.dart`; production-reference search | Keep it isolated for now. Remove it only in a separately scoped dead-code cleanup, with an import/reference audit and a clean quality gate. | Low / low |
| D7 | P1 | **Removed by product decision 2026-08-17.** AudioMuse's Settings entry and `/settings/audiomuse` route were reintroduced despite the established disabled-feature policy. At the user's direction, the configuration page, route, dedicated presentation tests, and release-note claim are removed. The pre-existing direct integration remains force-disabled. | `settings_screen.dart`; `app_router.dart`; Phase 11 policy in `PROGRESS.md`; route and Settings coverage | Do not re-expose a force-disabled capability without explicit product approval. | High / low |
| D8 | P2 | **Removed by product decision 2026-09-30.** Genres are not a Navis concept. The unrouted Genre detail screen, genre providers, genre storage (schema 87), genre sync and the Android Auto genre intent handling were removed; see `docs/history/removed-features.md`. (Previously deferred by product decision 2026-08-17.) | `test/src/architecture/no_genre_feature_test.dart`; `library_screen_test.dart` (no Genres tab); Android Auto stale-ID tests | Do not add a genre page, route, Library section, Home shelf, search filter, Android Auto node, sync input or diagnostics field without an explicit product decision. | Medium / medium |
| D9 | P2 | **Wrapper removed 2026-09-30** in the routing and navigation overhaul; `RadioTabContent` remains the live implementation. Previously confirmed 2026-08-17: `RadioTabContent` is the live Library implementation; its standalone `RadioScreen` wrapper has no production router, import, or navigation reference. This duplicate entry shell can drift from the actual Library route and should not receive independent visual work. | `radio_screen.dart`; `library_screen.dart`; `app_router.dart`; production-reference search | Keep `RadioTabContent` as the sole live implementation. Remove or retain the wrapper only through a separately scoped dead-code cleanup. | Low / low |
| D10 | P2 | **Investigation updated 2026-08-17.** Earlier isolated Linux `/library` runs and later `/search` and Home restart captures each contained a partially painted first destination frame after relaunch, with no framework failure in logs. Repeated mounted Albums captures and initial populated Search and Home captures were visually complete. This does not reproduce as a confirmed user-visible navigation or animation flicker; it is currently a presentation-launcher/capture-lifecycle evidence gap. | Isolated `presentation_diagnostics.sh` Library, Search, and Home captures; repeated app-API screenshots; manual clean restart; clean log review | Keep the launcher behavior under observation, but do not introduce a product delay or visual workaround. Reopen as P1 only if it reproduces in a manually observed app window or on a user device. | Medium / low |
| D11 | P1 | **Implemented and approved 2026-08-17.** Desktop Sync Settings presented sync planning, work, performance, and change data as a log-like single column, while failed runs could expose raw server text. The workspace now summarizes the plan, pending work, catalog update, and last run in an adaptive two-to-four-column scan; phones retain the existing stacked sequence. Failures use concise recovery copy and retain technical detail in diagnostics. | `sync_settings_screen.dart`; Sync Settings widget coverage; approved actual Linux before/after capture and clean restart | Keep operational settings summary-first: use adaptive metrics for decision-relevant state, preserve mobile reading order, and never expose backend failure messages as product copy. | High / low |
| U8 | P1 | **Implemented 2026-08-16.** Permanent Android download failures previously placed an internal song ID in the system-notification title. Failure notifications now use one safe, generic recovery title while detailed reasons remain confined to logs. | `download_service.dart`; `download_notifier.dart`; notifier unit coverage | Preserve the safe-copy rule for background notifications; use user-facing names only when they are known, localized, and safe to expose. | Medium / low |
| U9 | P1 | **Implemented 2026-08-16.** The central Now Playing Play/Pause button exposed its localized tooltip on desktop but not on phone. All platforms now provide the same long-press and assistive label without changing the transport layout. | `now_playing_transport_controls.dart`; Now Playing adaptive coverage | Keep all transport controls equivalently labeled across touch and pointer layouts. | Medium / low |
| U10 | P1 | **Implemented 2026-08-16.** Fullscreen local and remote artwork viewers had close-only controls without a long-press or assistive label. Both now use the platform Close label without changing the immersive viewer composition. | `cover_art_viewer.dart`; artwork-viewer widget coverage | Keep all full-screen exit controls explicitly labeled, even where tap-to-dismiss also exists. | Medium / low |
| U11 | P1 | **Implemented 2026-08-16.** The compact Queue sheet's close control was the only header action without an explicit label. It now has the platform Close label, matching its Save and Clear actions without changing the sheet's compact layout. | `queue_sheet.dart`; Queue sheet widget coverage | Keep every sheet exit action explicitly labeled for mouse, keyboard, and touch exploration. | Medium / low |
| U12 | P1 | **Implemented 2026-08-16.** The sign-in password visibility toggle had no stateful label, which made its purpose unclear on hover, long press, and assistive technology. It now announces localized Show password and Hide password labels without changing the credential form layout. | `login_screen.dart`; Login widget coverage | Label all stateful icon controls with the action their next press will take. | Medium / low |
| U13 | P1 | **Implemented 2026-08-17.** The shared Add to Playlist picker had an unlabeled close-only control in its desktop dialog and phone sheet. It now exposes the platform Close label without changing either form factor's composition. | `add_to_playlist_sheet.dart`; picker widget coverage | Keep shared picker exits explicitly labeled across dialog and sheet presentations. | Medium / low |
| U14 | P1 | **Implemented 2026-08-17.** Artist Top Tracks offered a visible overflow trigger but no pointer, touch, or assistive label. Its song menu now uses the platform Show menu label, matching the routed Library and Search song-menu affordances. | `artist_top_tracks_section.dart`; top-tracks widget coverage | Keep the shared More/Show menu label on every visible overflow trigger. | Medium / low |
| U15 | P1 | **Implemented 2026-08-17.** Home's weekly-playlist song action opened the same desktop context menu as secondary click, but its visible More trigger had no hover, touch, or assistive label. It now uses the platform Show menu label without changing menu placement or composition. | `home_screen.dart`; Home weekly menu widget coverage; isolated Linux Home capture and clean restart | Keep the shared More/Show menu label on every visible overflow trigger. | Medium / low |
| U18 | P1 | **Implemented 2026-08-17.** Liked-song overflow controls lacked the platform Show menu label, and desktop calculated their menu position from the page rather than the invoking control. Each compact and desktop trigger now has the shared label; desktop anchors the existing menu at the pressed button, matching secondary-click. | `library_screen.dart`; Library widget coverage | Keep every compact and desktop overflow trigger both labeled and anchored to its own control. | Medium / low |
| U19 | P1 | **Implemented 2026-08-17.** Match Flow's remove-song action had an assistive label but no desktop hover or mobile long-press label. It now exposes the same clear Remove label across interaction modes. | `match_flow_screen.dart`; Match Flow widget coverage | Apply explicit action labels to icon-only editing controls. | Low / low |
| U20 | P1 | **Implemented 2026-08-17.** Search's query-clear icon had no pointer, touch, or assistive label after a query was entered. It now exposes the shared Clear label without changing the search-field layout. | `search_screen.dart`; Search focus widget coverage | Keep every conditional text-field action labeled when it appears. | Medium / low |
| U21 | P1 | **Implemented 2026-08-17.** Home's desktop recommendation rows exposed Like and More icons without labels, and the artwork-led Weekly detail Back action had no explicit label. Those controls now use the shared Like/Liked, More, and platform Back labels without changing composition. | `home_screen.dart`; Home widget coverage | Keep Home icon-only actions consistent with the shared pointer, touch, and assistive-label contract. | Medium / low |
| U22 | P1 | **Implemented 2026-08-17.** The shared `ErrorState` could clip long recovery copy and its Retry action on a short phone with large system text, while `EmptyState` already allowed scrolling. Error states now preserve their normal composition and scroll when needed, keeping recovery reachable. | `error_state.dart`; 200% short-phone widget coverage and existing recovery goldens | Keep shared state surfaces resilient to large text and small viewports; actions must remain reachable without reducing system text. | High / low |
| U23 | P2 | **Implemented 2026-08-17.** The Library artist view toggle used the non-actionable tooltip “Artists” in both grid and list states. It now describes the view its next press will select, without changing the compact control or its layout. | `library_screen.dart`; Library widget coverage for both current view modes | Keep mode-switching icon controls action-oriented: label the state a press will produce, not the category it affects. | Medium / low |
| U24 | P2 | **Implemented 2026-08-17.** Weekly-playlist recommendation rows still embedded English Matching, Ambiguous match, unavailable, and Search copy, bypassing the localization contract used by the surrounding page. Those states now use `AppLocalizations` without altering their visual hierarchy. | `home_support_widgets.dart`; weekly-detail desktop state coverage | Keep row-level pending and recovery copy localized, including hover/long-press labels. | Medium / low |
| U25 | P1 | **Implemented 2026-08-17.** Library's keyboard-filter banner and filtered-empty states embedded English copy, and its compact clear icon had no hover label; Playback's Experimental group likewise bypassed the localization contract. All now use `AppLocalizations` while retaining the approved layout. | `library_screen.dart`; `library_support_widgets.dart`; `playback_settings_screen.dart`; Library and Playback widget coverage; isolated Linux filtered-empty capture | Keep all state-specific copy and icon-only exits localized and explicitly named. | High / low |
| U26 | P2 | **Implemented and approved 2026-08-17.** Artist Top Tracks now follows Playlist Detail's hierarchy instead of looking like a distinct utility page: desktop uses a larger animated multi-album artwork, an artwork-led tonal header, strong playlist title, artist-and-track-count metadata, one filled Play action with tonal supporting actions, and a gentle fade into its inset song list. Phone adopts the same information/action hierarchy while retaining its established compact layout. | `artist_top_tracks_playlist_detail_screen.dart`; desktop and phone adaptive widget coverage; isolated Linux desktop captures and clean restart | Keep Artist Top Tracks aligned with playlist/album detail hierarchy while preserving the animated virtual artwork as its contextual differentiator. | Medium / low |
| U27 | P2 | **Implemented and approved 2026-08-17.** Desktop's expanded Lyrics surface identified itself only as “Lyrics,” leaving the track context in the persistent player bar. Its header now keeps a quiet, truncating title-and-artist context alongside the Lyrics label, without introducing a card or duplicating transport controls. | `app_shell_desktop_lyrics_overlay.dart`; desktop Lyrics semantics and 800×600 golden coverage; isolated Linux capture and clean restart | Retain track context in every desktop lyrics header while keeping it visually subordinate to the lyrics. | Medium / low |

## Album-open transition: implemented design

Desktop and compact-wide layouts use a short, continuous artwork expansion
from every album card; phone uses a calm, complete-page fade. Neither design
animates the entire destination like a modal.

1. On desktop and compact-wide, transfer the exact source Hero tag through
   `NavService.openAlbumDetail`; preserve the source image cache key and
   radius in the single shared flight.
2. On phone, pass an explicit fade-only route request and omit the destination
   artwork Hero. The full detail composition appears and disappears in 180 ms
   without spatial artwork travel.
3. When a desktop/compact source is unavailable (deep link, disappeared card,
   duplicate card, or restore), use the same 180 ms content fade with static
   artwork; it is an intentional fallback, not an accidental missing Hero.
4. Keep the full-screen artwork viewer as a separate 170 ms fade/scale
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

## Entity-action placement matrix

This is the cross-platform placement contract for high-frequency music
actions. It removes guesswork without forcing every surface to show every
action. A surface should expose its primary task first, then disclose the rest
in the same order on phone and desktop.

| Entity / surface | Direct actions | Secondary actions (`More` / context menu) | Ordering and interaction rules |
| --- | --- | --- | --- |
| **Album** | **Play** (filled), Shuffle, Like, Download status | Open, Add to queue, download quality/remove download | Keep direct order `Play → Shuffle → Like → Download → More`. A card tap opens; long-press/right-click opens the same context menu. Download removal is the last, destructive action. |
| **Artist** | **Play** (filled), Shuffle, Like | Open (when not already on the detail page), Play, Shuffle, Add to queue, Like/Unlike | Artist detail and list/search rows use the shared action menu. Keep compact grids and similar-artist cards visually quiet: long-press opens the touch sheet and desktop right-click opens the anchored menu. Artists do not expose a fake download action. |
| **Playlist** | **Play** (filled), Shuffle, Download status | Rename/edit, Add to queue, remove download, delete playlist | Keep the first three direct actions in album order. Owner-only editing and deletion never compete with Play; destructive playlist deletion is last and requires confirmation. |
| **Song row** | Tap row to Play; visible download/state indicator only where space allows | Play now, Add to queue, Play next, Like, Rating, Go to artist, Go to album, Add to playlist, Download/remove download | The context menu is the canonical long-form order above. It must be identical for long-press and secondary-click; unavailable remote actions remain visibly disabled with an explanation. |
| **Home / recommendation card** | Tap to open; a compact primary play control only when the card is explicitly a play recommendation | Queue, Like, Download, source-specific actions | Do not place destructive actions on artwork. The identical album context menu is the secondary path for local albums. |
| **Now Playing / Mini Player** | Transport controls, Like, Queue, Lyrics | Download, album/artist navigation, playback settings | Playback transport remains separate from entity actions. Never hide Pause/Next behind `More`; secondary entity actions follow the same song order. |

### Shared rules

1. **One primary action.** `Play` is the only filled entity action. `Shuffle`
   is tonal/secondary; supporting actions are icon or overflow actions.
2. **Stable icon sequence.** When direct actions fit, use the matrix order. Do
   not swap Like and Download per breakpoint or entity page.
3. **One menu vocabulary.** Touch long-press and desktop secondary-click open
   equivalent actions, labels, enabled states, and destructive placement.
4. **Destructive actions last.** Remove download and delete actions use error
   color, appear after a divider where a surface has enough actions, and use a
   confirmation when the operation cannot be recovered.
5. **State is not an action.** Downloaded, liked, cached, remote, and playing
   states are always visible before making an action unavailable; tooltips and
   semantics state what will happen on activation.

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

## Prioritized implementation queue

The following order keeps each change small enough to visually review while
improving the highest-frequency journeys first.

1. **Library filtered-empty recovery** — approved and implemented: add one
   `Show all` action wherever Downloaded, Liked, or type-to-filter leaves a
   Library section empty. It clears only the active filters and preserves the
   user's section and scroll context.
2. **State-specific recovery** — implemented for the audited offline, empty,
   failure, unavailable-detail, and large-text recovery states. Keep technical
   detail in diagnostics and add a direct recovery action only when it is safe
   and local.
3. **Desktop workspace convergence** — largely implemented across routed
   collection and Settings pages. Keep `DesktopPanel`/`DesktopCard` limited to
   local groups, list rows, and selected states; audit a new desktop page
   before introducing a page-level surface.
4. **Entity-menu convergence** — implemented for current routed song, album,
   artist, playlist, and downloaded-track surfaces. Future owner actions must
   keep the same desktop pointer menu and touch-sheet ordering, with destructive
   actions last.
5. **Reduced-motion regression guardrails** — implemented for the audited
   motion system. Preserve `MotionPolicy` whenever adding a visible state
   transition, then validate normal and reduced-motion behavior on phone and
   desktop.

Any future visual change from these maintenance items requires its own
before/after review before it is committed.
