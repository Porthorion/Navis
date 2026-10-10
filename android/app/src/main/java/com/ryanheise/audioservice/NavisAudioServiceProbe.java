package com.ryanheise.audioservice;

/** Reads the shared audio session without bootstrapping a Flutter engine. */
public final class NavisAudioServiceProbe {
    private NavisAudioServiceProbe() {}

    public static boolean sessionActive() {
        AudioService service = AudioService.instance;
        return service != null && service.getProcessingState() != AudioProcessingState.idle;
    }
}
