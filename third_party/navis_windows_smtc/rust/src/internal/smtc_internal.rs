use std::sync::Mutex;

use crate::frb_generated::StreamSink;
use anyhow::anyhow;
use windows::{
    core::HSTRING,
    Foundation::{self, EventRegistrationToken, TypedEventHandler},
    Media::{
        AutoRepeatModeChangeRequestedEventArgs, MediaPlaybackAutoRepeatMode, MediaPlaybackType,
        PlaybackPositionChangeRequestedEventArgs, ShuffleEnabledChangeRequestedEventArgs,
        SystemMediaTransportControls, SystemMediaTransportControlsButton,
        SystemMediaTransportControlsButtonPressedEventArgs,
        SystemMediaTransportControlsTimelineProperties,
    },
    Storage::Streams::RandomAccessStreamReference,
};

use super::{
    config::SMTCConfig, metadata::MusicMetadata, playback_status::PlaybackStatus,
    timeline::PlaybackTimeline,
};

pub struct SMTCInternal {
    pub media_player: Box<windows::Media::Playback::MediaPlayer>,
    subscriptions: Mutex<Subscriptions>,
}

#[derive(Default)]
struct Subscriptions {
    button: Option<EventRegistrationToken>,
    position: Option<EventRegistrationToken>,
    shuffle: Option<EventRegistrationToken>,
    repeat: Option<EventRegistrationToken>,
}

fn artwork_uri(thumbnail: &HSTRING) -> Option<Foundation::Uri> {
    let value = thumbnail.to_string_lossy();
    if !(value.starts_with("https://") || value.starts_with("http://")) {
        return None;
    }
    Foundation::Uri::CreateUri(&HSTRING::from(value)).ok()
}

impl SMTCInternal {
    pub fn new(enabled: Option<bool>) -> anyhow::Result<Self> {
        let media_player = Box::new(windows::Media::Playback::MediaPlayer::new()?);
        let smtc = media_player.SystemMediaTransportControls()?;
        media_player.CommandManager()?.SetIsEnabled(false)?;
        smtc.SetIsEnabled(enabled.unwrap_or(true))?;
        Ok(Self {
            media_player,
            subscriptions: Mutex::new(Subscriptions::default()),
        })
    }

    pub fn update_config(&self, config: SMTCConfig) -> anyhow::Result<()> {
        let smtc = self.media_player.SystemMediaTransportControls()?;
        smtc.SetIsPlayEnabled(config.play_enabled)?;
        smtc.SetIsPauseEnabled(config.pause_enabled)?;
        smtc.SetIsNextEnabled(config.next_enabled)?;
        smtc.SetIsPreviousEnabled(config.prev_enabled)?;
        smtc.SetIsFastForwardEnabled(config.fast_forward_enabled)?;
        smtc.SetIsRewindEnabled(config.rewind_enabled)?;
        smtc.SetIsStopEnabled(config.stop_enabled)?;
        Ok(())
    }

    pub fn update_metadata(&self, metadata: MusicMetadata) -> anyhow::Result<()> {
        let smtc = self.media_player.SystemMediaTransportControls()?;
        let updater = smtc.DisplayUpdater()?;
        updater.ClearAll()?;
        updater.SetType(MediaPlaybackType::Music)?;
        let music_properties = updater.MusicProperties()?;

        if let Some(artist) = metadata.h_artist() {
            music_properties.SetArtist(&artist)?;
        }
        if let Some(album) = metadata.h_album() {
            music_properties.SetAlbumTitle(&album)?;
        }
        if let Some(title) = metadata.h_title() {
            music_properties.SetTitle(&title)?;
        }
        if let Some(album_artist) = metadata.h_album_artist() {
            music_properties.SetAlbumArtist(&album_artist)?;
        }
        if let Some(thumbnail) = metadata.h_thumbnail() {
            if let Some(uri) = artwork_uri(&thumbnail) {
                if let Ok(reference) = RandomAccessStreamReference::CreateFromUri(&uri) {
                    updater.SetThumbnail(&reference)?;
                }
            }
        }
        updater.Update()?;
        Ok(())
    }

    pub fn clear_metadata(&self) -> anyhow::Result<()> {
        let updater = self
            .media_player
            .SystemMediaTransportControls()?
            .DisplayUpdater()?;
        updater.ClearAll()?;
        updater.Update()?;
        Ok(())
    }

    pub fn update_timeline(&self, timeline: PlaybackTimeline) -> anyhow::Result<()> {
        let smtc = self.media_player.SystemMediaTransportControls()?;
        let timeline_properties: anyhow::Result<SystemMediaTransportControlsTimelineProperties> =
            timeline.into();
        smtc.UpdateTimelineProperties(&timeline_properties?)?;
        Ok(())
    }

    pub fn update_playback_status(&self, status: PlaybackStatus) -> anyhow::Result<()> {
        self.media_player
            .SystemMediaTransportControls()?
            .SetPlaybackStatus(status.into())?;
        Ok(())
    }

    pub fn update_shuffle(&self, shuffle: bool) -> anyhow::Result<()> {
        self.media_player
            .SystemMediaTransportControls()?
            .SetShuffleEnabled(shuffle)?;
        Ok(())
    }

    pub fn update_repeat_mode(&self, repeat_mode: String) -> anyhow::Result<()> {
        let smtc = self.media_player.SystemMediaTransportControls()?;
        match repeat_mode.as_str() {
            "track" => smtc.SetAutoRepeatMode(MediaPlaybackAutoRepeatMode::Track)?,
            "list" => smtc.SetAutoRepeatMode(MediaPlaybackAutoRepeatMode::List)?,
            _ => smtc.SetAutoRepeatMode(MediaPlaybackAutoRepeatMode::None)?,
        }
        Ok(())
    }

    pub fn enable_smtc(&self) -> anyhow::Result<()> {
        self.media_player
            .SystemMediaTransportControls()?
            .SetIsEnabled(true)?;
        Ok(())
    }

    pub fn disable_smtc(&self) -> anyhow::Result<()> {
        self.media_player
            .SystemMediaTransportControls()?
            .SetIsEnabled(false)?;
        Ok(())
    }

    fn subscriptions(&self) -> anyhow::Result<std::sync::MutexGuard<'_, Subscriptions>> {
        self.subscriptions
            .lock()
            .map_err(|_| anyhow!("SMTC event subscription state is unavailable"))
    }

    pub fn button_press_event(&self, sink: StreamSink<String>) -> anyhow::Result<()> {
        let handler = TypedEventHandler::<
            SystemMediaTransportControls,
            SystemMediaTransportControlsButtonPressedEventArgs,
        >::new(move |_, args| {
            let Some(args) = args.as_ref() else {
                return Ok(());
            };
            let Ok(button) = args.Button() else {
                return Ok(());
            };
            let event = match button {
                SystemMediaTransportControlsButton::Play => Some("play"),
                SystemMediaTransportControlsButton::Pause => Some("pause"),
                SystemMediaTransportControlsButton::Next => Some("next"),
                SystemMediaTransportControlsButton::Previous => Some("previous"),
                SystemMediaTransportControlsButton::FastForward => Some("fast_forward"),
                SystemMediaTransportControlsButton::Rewind => Some("rewind"),
                SystemMediaTransportControlsButton::Stop => Some("stop"),
                SystemMediaTransportControlsButton::Record => Some("record"),
                SystemMediaTransportControlsButton::ChannelUp => Some("channel_up"),
                SystemMediaTransportControlsButton::ChannelDown => Some("channel_down"),
                _ => None,
            };
            if let Some(event) = event {
                let _ = sink.add(event.to_string());
            }
            Ok(())
        });
        let token = self
            .media_player
            .SystemMediaTransportControls()?
            .ButtonPressed(&handler)?;
        self.subscriptions()?.button = Some(token);
        Ok(())
    }

    pub fn position_change_request_event(&self, sink: StreamSink<i64>) -> anyhow::Result<()> {
        let handler = TypedEventHandler::<
            SystemMediaTransportControls,
            PlaybackPositionChangeRequestedEventArgs,
        >::new(move |_, args| {
            let Some(args) = args.as_ref() else {
                return Ok(());
            };
            let Ok(position) = args.RequestedPlaybackPosition() else {
                return Ok(());
            };
            let _ = sink.add(position.Duration);
            Ok(())
        });
        let token = self
            .media_player
            .SystemMediaTransportControls()?
            .PlaybackPositionChangeRequested(&handler)?;
        self.subscriptions()?.position = Some(token);
        Ok(())
    }

    pub fn shuffle_request_event(&self, sink: StreamSink<bool>) -> anyhow::Result<()> {
        let handler = TypedEventHandler::<
            SystemMediaTransportControls,
            ShuffleEnabledChangeRequestedEventArgs,
        >::new(move |_, args| {
            let Some(args) = args.as_ref() else {
                return Ok(());
            };
            let Ok(shuffle) = args.RequestedShuffleEnabled() else {
                return Ok(());
            };
            let _ = sink.add(shuffle);
            Ok(())
        });
        let token = self
            .media_player
            .SystemMediaTransportControls()?
            .ShuffleEnabledChangeRequested(&handler)?;
        self.subscriptions()?.shuffle = Some(token);
        Ok(())
    }

    pub fn repeat_mode_request_event(&self, sink: StreamSink<String>) -> anyhow::Result<()> {
        let handler = TypedEventHandler::<
            SystemMediaTransportControls,
            AutoRepeatModeChangeRequestedEventArgs,
        >::new(move |_, args| {
            let Some(args) = args.as_ref() else {
                return Ok(());
            };
            let Ok(repeat_mode) = args.RequestedAutoRepeatMode() else {
                return Ok(());
            };
            let value = match repeat_mode {
                MediaPlaybackAutoRepeatMode::Track => "track",
                MediaPlaybackAutoRepeatMode::List => "list",
                _ => "none",
            };
            let _ = sink.add(value.to_string());
            Ok(())
        });
        let token = self
            .media_player
            .SystemMediaTransportControls()?
            .AutoRepeatModeChangeRequested(&handler)?;
        self.subscriptions()?.repeat = Some(token);
        Ok(())
    }
}

impl Drop for SMTCInternal {
    fn drop(&mut self) {
        let Ok(smtc) = self.media_player.SystemMediaTransportControls() else {
            return;
        };
        let Ok(mut subscriptions) = self.subscriptions.lock() else {
            return;
        };
        if let Some(token) = subscriptions.button.take() {
            let _ = smtc.RemoveButtonPressed(token);
        }
        if let Some(token) = subscriptions.position.take() {
            let _ = smtc.RemovePlaybackPositionChangeRequested(token);
        }
        if let Some(token) = subscriptions.shuffle.take() {
            let _ = smtc.RemoveShuffleEnabledChangeRequested(token);
        }
        if let Some(token) = subscriptions.repeat.take() {
            let _ = smtc.RemoveAutoRepeatModeChangeRequested(token);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{artwork_uri, Subscriptions};
    use windows::core::HSTRING;

    #[test]
    fn invalid_artwork_uri_is_skipped() {
        assert!(artwork_uri(&HSTRING::from("file:///not-safe-for-smtc.jpg")).is_none());
    }

    #[test]
    fn event_subscriptions_start_without_tokens() {
        let subscriptions = Subscriptions::default();
        assert!(subscriptions.button.is_none());
        assert!(subscriptions.position.is_none());
        assert!(subscriptions.shuffle.is_none());
        assert!(subscriptions.repeat.is_none());
    }
}
