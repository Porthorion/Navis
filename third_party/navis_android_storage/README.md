# Navis Android storage bridge

This private tracked Flutter plugin registers `permanent_download_playback` on
all Android Flutter engines, including audio_service's service-owned engine.
Its sole operation is a read-only existence query against an already granted
`content://` document. It uses application context and requires no Activity,
new permission, directory selection, writable probe, or eager engine startup.
Android SAF grants and the provider remain authoritative. The activity-owned
folder-management channel retains selection/import/write operations. Flutter
registers this plugin through normal generated registration; do not edit the
generated registrant or replace the canonical AudioService.

The external MediaBrowser fixture regression verifies downloaded playback after
force-stop without MainActivity. Dart channel tests verify null/error semantics.
