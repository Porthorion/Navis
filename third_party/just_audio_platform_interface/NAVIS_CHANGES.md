# Navis platform-interface extension

Based on just_audio_platform_interface 4.6.0 (MIT). Adds optional initial EQ
configuration, typed filters, player-scoped configuration application, and
observable processing status. Existing backend implementations retain their
default unsupported methods until they explicitly implement EQ.

Navis raises the local Dart lower bound to 3.4 for shared response mathematics
using records and switch expressions. Typed validation/coefficient/headroom
calculations are also used by the Linux mpv chain compiler.

`ProgressiveAudioSourceOptionsMessage.androidUseDefaultLoadErrorHandling`
serializes the radio opt-out from Navis's Android unknown-length VOD retry
policy. It defaults to false; other platform adapters ignore the option.
