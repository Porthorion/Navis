# Offline SPDX notice templates

The Rust notices generator reads these tracked templates only when a registry
crate supplies no licence file. It never downloads text at generation or app
runtime. Existing upstream files and attributions take precedence.

- MIT: standard [SPDX MIT text](https://github.com/spdx/license-list-data/blob/main/text/MIT.txt),
  with `{copyright_holders}` filled from Cargo metadata authors or
  `the <crate> authors`. No copyright year is invented.
- Apache-2.0: full standard text from the locally fetched futures crate's
  `LICENSE-APACHE`, matching the [SPDX Apache-2.0 licence](https://github.com/spdx/license-list-data/blob/main/text/Apache-2.0.txt).
- Unicode-3.0: Unicode License V3 from unicode-ident's `LICENSE-UNICODE`,
  matching the [SPDX Unicode-3.0 text](https://github.com/spdx/license-list-data/blob/main/text/Unicode-3.0.txt).

Sources checked on 2026-10-07. The generator emits every licence in an SPDX
expression and deduplicates identical full texts across crate references.
Unsupported fallback identifiers fail generation instead of producing an
incomplete notice.
