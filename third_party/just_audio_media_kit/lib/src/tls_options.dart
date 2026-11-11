/// The libmpv properties for Navis's stream certificate checking: nothing when
/// [verify] is off, otherwise `tls-verify` (Navis's libmpv builds read the
/// system certificate store themselves).
Map<String, String> tlsProperties({required bool verify}) =>
    verify ? const {'tls-verify': 'yes'} : const {};
