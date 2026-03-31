# tool/secrets/

This directory contains encrypted release credentials checked into git.

## navis-release.jks.enc

AES-256-CBC encrypted copy of the Android release keystore (`~/navis-release.jks`).

**To restore the keystore:**
```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in tool/secrets/navis-release.jks.enc \
  -out ~/navis-release.jks \
  -pass pass:"<store-password>"
```

The passphrase is the `storePassword` value from `android/key.properties`.
It is also stored as the `NAVIS_KEYSTORE_PASSWORD` secret on this Forgejo repo.

**Keystore details:**
- Alias: `navis-release`
- SHA-256: `12:C6:41:1B:2A:9F:D3:0B:2B:B8:63:01:9D:63:08:5E:5F:36:A1:D2:09:A1:D1:F1:55:9D:70:95:50:E9:B0:C7`
- Created: 2026-03-30

**Why it's safe to commit:** The `.jks` is encrypted with AES-256 + PBKDF2 (600k iterations).
The plaintext keystore must never be committed.
