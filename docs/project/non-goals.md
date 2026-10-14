# Not planned for now

These are things Navis doesn't plan to do **at the moment**. None of them is
impossible, and any could be reconsidered later, especially if many people ask
for it. Right now the priority is making Navis as mature and reliable as
possible.

Read this before opening a feature request or writing code in these areas. A
pull request for one of them is likely to be declined, even if it works well.
If you think the situation has changed, open an issue or a discussion first and
explain what's different.

## Servers other than Subsonic and OpenSubsonic

Navis works with Navidrome and other servers that support the Subsonic or
OpenSubsonic API. Jellyfin, Plex and other servers aren't planned for now. That
doesn't mean they're ruled out: the current goal is to make Navis as mature and
issue-free as possible on the servers it already supports before taking on more.

## Genre pages

There are no genre pages, genre browsing or genre-based features. Even a
carefully tagged library (with tools like MusicBrainz Picard or beets) rarely
produces genre data good enough for a useful genres page. This could be
revisited if it's widely requested. An architecture test currently keeps genre
features out of the app code.

## Sleep timer

A sleep timer is mostly an audiobook feature, and Navis is a music player. It
could be added if enough people ask for it.

## Ads, paid tiers, analytics and telemetry

Navis is free and always will be. There are no ads, paid tiers or in-app
purchases, and Navis doesn't collect analytics or telemetry. Donations are
optional and never unlock features.

## Google Play Services

Navis doesn't depend on Google Play Services, including Google's proprietary
Cast SDK. Casting is planned with an open protocol instead (see
[issue #2](https://github.com/Porthorion/Navis/issues/2)).

## Listen Together

Listen Together was developed separately and didn't work as expected,
especially with songs from remote sources, so it's retired for now. See
[removed features](../history/removed-features.md).
