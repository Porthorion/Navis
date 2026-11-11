#include "NavisPitchAU.h"

#include <TargetConditionals.h>

#if TARGET_OS_IOS || defined(NAVIS_PITCH_AU_HOST_TEST)

#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

struct NavisPitchAU {
    AudioUnit unit;
    int channels, maxFrames, latencyFrames;
    const float *const *input; // the block being rendered, set before AudioUnitRender
    int inputFrames;
    float *pull;               // channels * maxFrames, for a pull that brings no buffers
    AudioBufferList *output;   // channels buffers, allocated in _new
    uint64_t sampleTime;       // monotonic: a seek restarts the audio, never this clock
    _Atomic uint64_t mismatches; // input pulls that did not match the block (zero-filled)
};

// The unit asks for its input once per render, `frames` long. Anything the block
// cannot supply is zero-filled; nothing is ever read past the block.
static OSStatus pullInput(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                          UInt32 bus, UInt32 frames, AudioBufferList *io) {
    (void)flags; (void)time; (void)bus;
    NavisPitchAU *au = ref;
    if (frames > (UInt32)au->maxFrames) {
        atomic_fetch_add_explicit(&au->mismatches, 1, memory_order_relaxed);
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    // One pull per render, as long as the block: anything else is counted.
    if (!au->input || (UInt32)au->inputFrames != frames || io->mNumberBuffers != (UInt32)au->channels) {
        atomic_fetch_add_explicit(&au->mismatches, 1, memory_order_relaxed);
    }
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
        float *dst = io->mBuffers[b].mData;
        if (!dst && b < (UInt32)au->channels) {
            dst = au->pull + (size_t)b * (size_t)au->maxFrames;
            io->mBuffers[b].mData = dst;
        }
        if (!dst) continue;
        UInt32 have = b < (UInt32)au->channels && au->input ? (UInt32)au->inputFrames : 0;
        if (have > frames) have = frames;
        if (have) memcpy(dst, au->input[b], (size_t)have * sizeof(float));
        if (have < frames) memset(dst + have, 0, (size_t)(frames - have) * sizeof(float));
        io->mBuffers[b].mDataByteSize = frames * sizeof(float);
    }
    return noErr;
}

static int auRender(void *user, const float *const *in, float *const *out, int channels, int frames) {
    NavisPitchAU *au = user;
    if (channels != au->channels || frames <= 0 || frames > au->maxFrames) return -1;
    au->input = in;
    au->inputFrames = frames;
    AudioBufferList *list = au->output;
    list->mNumberBuffers = (UInt32)channels;
    for (int c = 0; c < channels; c++) {
        list->mBuffers[c].mNumberChannels = 1;
        list->mBuffers[c].mDataByteSize = (UInt32)frames * sizeof(float);
        list->mBuffers[c].mData = out[c];
    }
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp time;
    memset(&time, 0, sizeof time);
    time.mFlags = kAudioTimeStampSampleTimeValid;
    time.mSampleTime = (Float64)au->sampleTime;
    au->sampleTime += (uint64_t)frames;
    OSStatus status = AudioUnitRender(au->unit, &flags, &time, 0, (UInt32)frames, list);
    au->input = NULL;
    if (status != noErr) return status ? (int)status : -1;
    for (int c = 0; c < channels; c++) { // the unit may hand back its own buffer
        if (list->mBuffers[c].mData != out[c]) memcpy(out[c], list->mBuffers[c].mData, (size_t)frames * sizeof(float));
    }
    return 0;
}

static void auReset(void *user) {
    AudioUnitReset(((NavisPitchAU *)user)->unit, kAudioUnitScope_Global, 0);
}

static void auSetCents(void *user, float cents) {
    AudioUnitSetParameter(((NavisPitchAU *)user)->unit, kNewTimePitchParam_Pitch, kAudioUnitScope_Global, 0, cents, 0);
}

NavisPitchAU *navis_pitch_au_new(double sampleRate, int channels, int maxFrames) {
    if (channels < 1 || channels > NAVIS_PITCH_MAX_CHANNELS || maxFrames < 1 || !(sampleRate > 0)) return NULL;
    NavisPitchAU *au = calloc(1, sizeof *au);
    if (!au) return NULL;
    atomic_init(&au->mismatches, 0);
    au->channels = channels;
    au->maxFrames = maxFrames;
    au->pull = calloc((size_t)channels * (size_t)maxFrames, sizeof(float));
    au->output = calloc(1, offsetof(AudioBufferList, mBuffers) + (size_t)channels * sizeof(AudioBuffer));
    AudioComponentDescription description = {kAudioUnitType_FormatConverter, kAudioUnitSubType_NewTimePitch,
                                             kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!au->pull || !au->output || !component || AudioComponentInstanceNew(component, &au->unit) != noErr) {
        au->unit = NULL;
        navis_pitch_au_free(au);
        return NULL;
    }
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof format);
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerPacket = format.mBytesPerFrame = sizeof(float);
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = (UInt32)channels;
    format.mBitsPerChannel = 32;
    UInt32 slice = (UInt32)maxFrames;
    AURenderCallbackStruct callback = {pullInput, au};
    Float64 latency = 0;
    UInt32 size = sizeof latency;
    OSStatus status = AudioUnitSetProperty(au->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof format);
    status |= AudioUnitSetProperty(au->unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof format);
    status |= AudioUnitSetProperty(au->unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, sizeof slice);
    status |= AudioUnitSetProperty(au->unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof callback);
    status |= AudioUnitInitialize(au->unit);
    status |= AudioUnitSetParameter(au->unit, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, 1.0f, 0);
    status |= AudioUnitGetProperty(au->unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
    if (status != noErr) {
        navis_pitch_au_free(au);
        return NULL;
    }
    au->latencyFrames = (int)lround(latency * sampleRate);
    return au;
}

void navis_pitch_au_free(NavisPitchAU *au) {
    if (!au) return;
    if (au->unit) {
        AudioUnitUninitialize(au->unit);
        AudioComponentInstanceDispose(au->unit);
    }
    free(au->pull);
    free(au->output);
    free(au);
}

uint64_t navis_pitch_au_pull_mismatches(const NavisPitchAU *au) {
    return au ? atomic_load_explicit(&((NavisPitchAU *)au)->mismatches, memory_order_relaxed) : 0;
}

NavisPitchRenderer navis_pitch_au_renderer(NavisPitchAU *au) {
    NavisPitchRenderer renderer = {au, auRender, auReset, auSetCents, au->latencyFrames};
    return renderer;
}

#endif
