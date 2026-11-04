/// The libmpv properties for Navis's stream certificate checking: nothing when
/// [verify] is off, otherwise `tls-verify` plus `tls-ca-file` when [caFile] is
/// set (libmpv builds that cannot read the system store need it).
Map<String, String> tlsProperties({required bool verify, String? caFile}) =>
    verify
        ? {'tls-verify': 'yes', if (caFile != null) 'tls-ca-file': caFile}
        : const {};
