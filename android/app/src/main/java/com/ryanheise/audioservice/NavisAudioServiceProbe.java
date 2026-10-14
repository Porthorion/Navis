package com.ryanheise.audioservice;

/** Reads the shared audio session without bootstrapping a Flutter engine. */
public final class NavisAudioServiceProbe {
    private NavisAudioServiceProbe() {}

    public static boolean sessionActive() {
        AudioService service = AudioService.instance;
        return service != null && defersSync(service.isPlaying(), service.getProcessingState());
    }
    public static boolean defersSync(boolean playing, AudioProcessingState state) {
        return playing || state == AudioProcessingState.loading || state == AudioProcessingState.buffering;
    }
}
