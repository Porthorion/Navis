# Polestar 4: native automotive investigation and discussion record

Date: 2026-09-28  
Status: deferred investigation; no implementation plan or automotive release decision

## Purpose and scope decision

This document preserves the Polestar findings, user reports, product discussion,
and unresolved questions before continuing the separate responsive-layout
discussion. It is an investigation record, not a statement of supported AAOS
behavior, a delivery commitment, or an implementation plan.

The user requested that the Polestar work be set aside and documented. The
ordinary Android and desktop layout work can proceed independently. Improving
the normal APK's large-screen layout might improve its parked appearance on a
car, but does not establish native automotive compatibility or fix driving
restrictions.

No application changes, car deployment, or publication were authorized or
performed as part of this investigation. The user explicitly requested
brainstorming before a final plan.

## Reported incident

The following details were supplied by the user about a friend's vehicle; they
have not been independently reproduced.

| Item | Reported information | Confidence or limitation |
|---|---|---|
| Vehicle | Polestar 4 | User-reported |
| Model year | Most likely 2023/2024 | Estimate; exact model year unconfirmed |
| Region | Middle East | Exact country and market configuration unknown |
| Vehicle software | Latest available when checked recently | Exact version and observation date unknown |
| Navis version | 1.3.1 | User-reported; that release was not separately audited |
| Installation | Normal APK available from the Git repository, installed directly on the car | Not Android Auto phone projection; transfer/installer details unknown |
| Parked presentation | Sizing became unsuitable on the car display | No car screenshot or viewport measurements supplied |
| Driving behavior | Navis's interface became inaccessible | Exact restriction message and active component unknown |
| Audio | Continued after the interface was blocked | Supports separation between playback and UI availability |
| User impact | Could not choose other songs/playlists or add/remove queue items through the app | Steering-wheel/system-control behavior was not separately established |

The eight supplied screenshots show desktop windows at smaller and larger
sizes. They demonstrate ordinary Navis layout problems, but are not evidence
of the Polestar's actual screen layout, density, or restriction message.

## Two distinct problems

1. **Layout and sizing:** the ordinary Flutter interface does not consistently
   use large windows well. The desktop review found fixed column ceilings,
   limited preview counts, and rows that stretch without adding information.
   These findings belong to the separate responsive-layout work and do not
   establish the exact cause of the car's sizing symptoms.
2. **Access while driving:** the sideloaded interface becomes unavailable while
   playback continues. This requires automotive integration analysis, not just
   responsive Flutter layout changes.

### Likely explanation for driving lockout

The leading hypothesis is that the vehicle restricts the ordinary Navis
activity while allowing its audio service to continue. Android Automotive
applies driving-related restrictions to activities; an app producing audio is
not evidence that its complete UI is suitable for use while driving.
[Android driver-distraction guidance](https://source.android.com/docs/automotive/driver_distraction/guidelines).

Continued audio is consistent with this hypothesis. It does not prove which
vehicle policy or component caused the restriction. There is no evidence that
the car classified Navis as a video player, despite the similar visible effect.
The incident should not be described as a reproduced or conclusively diagnosed
defect until vehicle evidence is available.

## Android Auto and Android Automotive OS are separate targets

| Experience | Where Navis runs | Presentation |
|---|---|---|
| Ordinary Android APK | Phone/tablet, or a car permitting sideloading | Navis's normal Flutter activity |
| Android Auto projection | Connected Android phone | Android Auto presents a car media interface |
| Native Android Automotive OS (AAOS) media app | Vehicle itself | Vehicle media interface, or supported Car App Library templates |

The reported installation concerns native vehicle execution. Improving phone
projection alone would not solve that installation's driving lockout.

Google documents two media approaches: a media browser service plus media
session that the host renders, and Car App Library media templates offering
more control over the experience. Templates still require media integration
and are not unrestricted application screens.
[Google media architecture overview](https://developer.android.com/training/cars/media).

The exact Polestar market software and host capabilities remain unverified.
This document does not assert that every Polestar 4 configuration supports the
same projection or native-template features.

## Repository findings at the time of discussion

The investigation reviewed the working checkout based on commit
`646275b8c09a4ca41c446aae4ab32397d0be83dc`, with pre-existing local changes.
It did not check out or reproduce Navis 1.3.1. The sources below establish
current implementation structure, not the precise behavior of the APK used
in the incident.

| Finding | Evidence |
|---|---|
| The APK declares `appCategory="audio"`, a media playback foreground service, and Android Auto projection metadata. | [Main manifest](../../android/app/src/main/AndroidManifest.xml) and [media descriptor](../../android/app/src/main/res/xml/automotive_app_desc.xml) |
| The ordinary Flutter `MainActivity` remains a launcher activity. The automotive hardware feature is optional; that alone does not establish native media integration. | [Main manifest](../../android/app/src/main/AndroidManifest.xml) |
| The inspected build configuration distinguishes Play and sideload distribution, not a dedicated AAOS media target. | [Android build configuration](../../android/app/build.gradle.kts) |
| Navis uses the canonical `com.ryanheise.audioservice.AudioService` media browser service and shared `NavisAudioHandler`. | [Architecture](../architecture.md), [audio handler](../../lib/src/features/player/data/navis_audio_handler.dart) |
| The browse tree has four roots: Liked, Recent, Playlists, and Library. It exposes albums, artists, downloads, and collection-aware media IDs. | [Media tree](../../lib/src/features/auto/data/auto_media_tree_service.dart), [media IDs](../../lib/src/features/auto/data/auto_media_id.dart) |
| Existing capabilities include Resume Queue when available, Instant Mix, Instant Radio, and search with local fallback. | [Media tree](../../lib/src/features/auto/data/auto_media_tree_service.dart), [architecture](../architecture.md) |
| Internet radio stations are not a destination in the inspected car browse tree. Instant Radio is a separate personalized music feature. | [Media tree](../../lib/src/features/auto/data/auto_media_tree_service.dart) |
| The project has service-first startup handling and a cold-start diagnostics workflow; its car runbooks explicitly concern phone projection. | [Architecture](../architecture.md), [DHU testing](../platforms/android-auto-testing.md), [real-car projection testing](../platforms/android-auto-real-car-testing.md) |

The manifest comment describing optional automotive hardware in terms of
"Android Auto" should not be interpreted as proof of AAOS support. The
projection/native distinction in the testing guide is the relevant boundary.

Existing automated tests and diagnostic workflows are useful foundations;
their presence is not evidence that this Polestar incident has been tested or
that an AAOS release is ready.

## User preferences and decisions

| Topic | Recorded position | Status |
|---|---|---|
| Scope separation | Preserve the Polestar discussion in its own document and set it aside from ordinary responsive-layout work. | Agreed |
| Phone projection | Existing Android Auto projection is acceptable, with room to improve organization, design, and supported theming. | User preference |
| Native AAOS styling | Whether the vehicle's standard media styling is acceptable for the first native experience. | Not answered; acceptance of projection must not be treated as acceptance of this choice |
| Primary car access | Resume, Liked, Playlists, Downloads, and search are the desired priorities. | User agreed |
| Navigation effort | Avoid many buttons, deep navigation, and unnecessary fiddling to start desired media. | User requirement |
| Existing organization | The user considers the existing layout a useful balance of available destinations and important content, with room for optimization. | Direction to preserve where practical |
| Internet radio | Include stations in the car experience, possibly under a secondary destination such as "More", rather than crowding the initial screen. | Inclusion desired; exact location undecided |
| Queue management | The loss of song selection, playlist changes, and queue editing is part of the reported impact. | Desired capabilities need prioritization and host feasibility checks |
| Implementation | No changes or final implementation plan yet. | Explicit boundary |

## Options discussed, not final decisions

### Standard native media interface

The recommended starting option was a dedicated AAOS build reusing Navis's
existing library, server, browse, queue, and playback functionality. For the
conventional service-based approach, the vehicle renders media browsing and
playback; sign-in and settings are separate parked workflows. Automotive
packaging and activity declarations differ from the phone APK.
[Google AAOS media requirements](https://developer.android.com/training/cars/media/automotive-os).

This is not a decision to rewrite Navis in Kotlin or to maintain a separate
product codebase. Reuse of Flutter/Dart and plugins is a candidate approach,
subject to validation of service startup, authentication, and vehicle lifecycle
behavior. The user has not yet accepted the native host's styling as the chosen
presentation.

### More customizable automotive templates

Car App Library media templates could allow richer organization and supported
actions. Availability depends on the vehicle's host/software capabilities;
fallback to the conventional media service is a documented option. Support on
the friend's Polestar has not been established.
[Google media templates](https://developer.android.com/training/cars/apps/media).

### Candidate navigation organization

The following was proposed for discussion, not selected as a final layout:

| Destination | Candidate contents |
|---|---|
| Liked | Liked songs/albums and quick listening actions |
| Recent | Resume and recently played content |
| Playlists | Available playlists |
| Library | Downloads prominently placed, followed by Albums, Artists, and Radio |

Search and Now Playing would use host-supported affordances. `Library → Radio`
was suggested as a more descriptive alternative to "More"; the user has not
chosen between them. Internet radio remains distinct from Instant Radio.

Queue display and selecting a queued item are different from adding, removing,
or reordering items. Do not promise complete desktop-equivalent queue editing
while driving without checking supported actions and interaction restrictions.
[Google playback and queue integration](https://developer.android.com/training/cars/media/enable-playback).

### Installation and independent operation

For compatible Google Play-equipped AAOS vehicles, the normal distribution
option discussed was an automotive release with appropriate review and device
targeting. Google supports using the mobile app's package name with a dedicated
AAOS release track; no package identity or publication decision was made.
[Google car distribution guidance](https://developer.android.com/training/cars/distribute).

Polestar documents installing apps through the vehicle app library/store.
Sideloading the ordinary APK does not by itself establish automotive support.
[Polestar 4 app installation](https://www.polestar.com/us/manual/polestar-4/2026/article/d35bed2e599d8460c0a8b09775a2ed4b-9bd65a93599c640ec0a8b09718c9bda4-8664b2fa77a7e089c0a8296870d1a409/).

A car-installed Navis instance needs its own server connectivity, authentication,
storage, and download availability. Phone credentials, downloads, and playback
state should not be assumed to transfer automatically. Vehicle sleep/resume,
network loss, and audio-focus behavior remain areas to assess. Other vehicle
platforms and regional configurations need their own compatibility evidence.

## Open questions and missing evidence

- Exact vehicle model year, country/market, OS/build version, media host, and
  available template support.
- Exact sideload method, restriction message, app entry point, and whether
  Navis appeared as a source in the car's native media interface.
- Which system or steering-wheel controls, if any, remained usable after the
  Flutter UI was blocked.
- Actual car viewport dimensions, scaling, orientation/window allocation, and
  a parked screenshot to diagnose the sizing separately.
- Whether the user accepts standard native AAOS media styling initially.
- Which queue actions are essential: selecting queued tracks, Play Next,
  appending, removing, or reordering; and which the host permits while driving.
- Final placement of internet radio and shortcuts within the navigation.
- Appropriate parked login/setup and server access, including offline behavior.
- Whether a future AAOS artifact shares the mobile package identity and which
  distribution route is available for the target market.

These are inputs for a future automotive discussion, not prerequisites for
continuing the ordinary Android/desktop design work.

## Evidence and validation limits

| Evidence type | Status |
|---|---|
| User incident report | Recorded, including continued audio and Navis 1.3.1 |
| Desktop screenshots | Reviewed for the separate responsive-layout investigation |
| Current repository structure | Read-only inspection; relevant paths linked above |
| Google/Polestar references | Reviewed during the 2026-09-28 discussion; recheck when automotive work resumes |
| Navis 1.3.1 source/artifact comparison | Not performed |
| AAOS emulator build/runtime | Not performed |
| Physical Polestar reproduction or logs | Not available |
| Android Auto DHU or real-car projection tests | Not run in this investigation |
| Automotive release, store approval, or compatibility certification | Not performed or claimed |

The only deliverable at this point is this preserved investigation. There is
no selected automotive implementation, schedule, or completed fix.
