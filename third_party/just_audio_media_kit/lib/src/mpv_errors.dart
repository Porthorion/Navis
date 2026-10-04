/// Whether [error], an error line media_kit forwarded from libmpv, is a
/// decoder error libmpv recovers from by skipping the damaged data (as after
/// a seek that lands mid-frame), rather than a failure of the source.
bool isRecoverableMpvDecodeError(String error) =>
    error.startsWith('Error decoding audio') ||
    error.startsWith('Error while decoding frame');
