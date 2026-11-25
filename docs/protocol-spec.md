# Synaptics WBDI (06cb:009a "Metallica MIS") protocol spec, for a libfprint driver

Source of truth studied: `reference/python-validity/validitysensor/*.py` (MIT licensed,
uunicorn/python-validity). This document distills that implementation into a spec a C
author can implement from directly, mapped onto libfprint's async driver API
(`libfprint/libfprint/fpi-device.h`, `fpi-print.h`). It targets USB ID **06cb:009a**
specifically (Lenovo ThinkPad X280 built-in "Metallica MIS" touch sensor); the same
protocol family also covers 138a:0090, 138a:0097, 138a:009d with per-model constant
tables.

Do **not** transliterate the Python line-by-line. Every section below gives the actual
wire format so you can write idiomatic C. The only things that must be carried over
byte-for-byte are opaque vendor data (hardcoded blobs, calibration/microcode tables) —
called out explicitly in §7.

---

## 0. Top-level sequence (cold plug → ready to enroll/verify)

This is `init.py:open_common()`. Each step is a section below.

1. Open USB device, claim interface, set configuration (§1).
2. `init_flash`: query flash partition table (opcode `0x3e`). **If partitions already
   exist (normal case — this sensor ships pre-paired from the OEM Windows image),
   skip to step 3.** Only if the flash reports zero partitions does a from-scratch
   "factory format + pairing" flow run (generate an EC keypair, hardcoded partition
   layout, hardcoded partition-table signature, ask the sensor for its firmware
   ECDH pubkey, derive+write the paired private key). **This from-scratch path is not
   implemented in python-validity for 06cb:009a at all** (only for 138a:0090) — treat
   pairing as an out-of-scope precondition; assume the sensor is already paired (true
   for any ThinkPad that has ever booted the stock Windows driver, Lenovo Vantage, or
   python-validity itself). See §6.4 for what "already paired" means concretely.
3. `usb.send_init()`: raw (pre-TLS) bring-up commands — RomInfo get, opcode `0x19`,
   get-fw-info, then replay the `init_hardcoded` blob (or `init_hardcoded_clean_slate`
   if fwext isn't loaded yet). See §2.
4. Read TLS pairing material from flash partition 1 (`read_flash(1, 0, 0x1000)`,
   itself sent as a *plain* (pre-TLS) command since partition 1 has access level 7 =
   readable without a TLS session) and parse it into cert / ECDH-signed-pubkey /
   encrypted-private-key blocks. See §3.1.
5. Run the TLS 1.2-like handshake (client hello → parse server hello/cert-req/hello-done
   → client cert + ECDHE key exchange + cert-verify + change-cipher-spec + finished →
   parse server finished). See §3.2–§3.4.
6. `upload_fwext()`: check whether firmware-extension partition 2 already has firmware
   (`get_fw_info(2)`); if so, done. Otherwise upload the `xpfwext` file (**not shipped
   by python-validity — user must extract it from the genuine Lenovo Windows driver
   package**, see §7.4) and reboot. On a machine that already ran python-validity or
   the Windows driver, this is a no-op read that returns immediately.
7. `sensor.open()`: identify the sensor ASIC (opcode `0x75`), look up per-model timing
   tables, run/verify calibration (opcode `0x02` capture in `CALIBRATE` mode) or load
   cached calibration from sensor flash partition 6. See §6.
8. `init_db()`: ensure the `"StgWindsor"` user-storage record exists in the on-sensor
   database (see §5).

After this, the device is ready for `enroll()` / `match_finger()` (§4, §5).

---

## 1. USB transport (`usb.py`)

- Standard USB, `set_configuration()` only — no explicit `claim_interface()` call in
  python-validity (libusb does this implicitly via `usb.core`; in libfprint terms this
  is `FP_DEVICE_TYPE_USB` + `g_usb_device_claim_interface`).
- Default per-transfer timeout: 15000 ms for command I/O; interrupt reads use a short
  100 ms poll timeout (used for cooperative cancellation, see below).
- Four endpoints in use, all on interface 0 (typical for these sensors — verify via
  `lsusb -v` against the real device, but python-validity hardcodes these numbers with
  no interface/alt-setting selection logic):
  | Endpoint | Direction | Purpose |
  |---|---|---|
  | `0x01` | OUT | Command write (`dev.write(1, out)`) |
  | `0x81` (`.read(129, …)`, i.e. EP 1 IN) | IN | Command response — same transaction, read after every write |
  | `0x82` (`.read(130, …)`, EP 2 IN) | IN | Bulk data read — used only after a `capture()` to fetch the raw calibration/scan frame data (`usb.read_82()`), up to 1 MiB, 10000 ms timeout |
  | `0x83` (`.read(131, …)`, EP 3 IN) | IN | Interrupt/event read (`usb.wait_int()`), 1024 B, **100 ms timeout, polled in a loop** — a timeout here is not an error, it's how cancellation is implemented (see below) |

- **Command transaction** (`usb.cmd`): write the raw command bytes to EP 1 OUT, then do
  a single blocking read from EP 1 IN (up to 129*1024 bytes... actually the Python call
  is `self.dev.read(129, 100*1024)` — first arg is the endpoint address encoding used
  by pyusb (129 = 0x81), second is max transfer length: 100*1024 = 102400 bytes). One
  write, one read, always paired.
- **Cancellation**: `usb.wait_int()` loops reading EP 3 IN with a 100 ms timeout;
  on `ETIMEDOUT` it checks a `cancel` flag and raises if set, otherwise loops again.
  In libfprint terms: implement this as a repeating short-timeout interrupt transfer
  inside your capture/enroll/identify state machine, checking
  `fpi_device_action_is_cancelled()` (or reacting to the cancel vtable callback that
  sets a flag) on each timeout instead of a real error.
- **Response status**: virtually every command response's first 2 bytes are a
  little-endian `uint16` status/error code. `0x0000` = success. `assert_status()` in
  Python just raises if nonzero — treat any nonzero value as a hard error unless a
  specific opcode's spec below says otherwise (e.g. `0x04b3` = "not found", used as a
  soft "no such record" signal by the DB layer; `0x0491` = "nothing to commit", used
  as a soft-ignore by `call_cleanups()`).

---

## 2. Pre-TLS bring-up commands (`usb.send_init`)

All sent as plain (unencrypted) command transactions over EP1, in order:

1. `01` — `RomInfo.get()`. Response (after the 2-byte status) is 0x10 bytes:
   `<LLBBxBxxxB` = `timestamp:u32le, build:u32le, major:u8, minor:u8, pad:u8,
   product:u8, pad:u8 pad:u8 pad:u8, u1:u8`.
2. `19` — undocumented, response ignored (status-checked only).
3. `43 02` — `get_fw_info(partition=2)`: query firmware-extension module table. If the
   response is exactly `b0 04` (2 bytes, no status-check performed, this is the
   "not-loaded" sentinel) treat firmware as absent. Otherwise: after the 2-byte status,
   layout is `major:u16le minor:u16le modcount:u16le buildtime:u32le`, followed by
   `modcount` × 12-byte module records `type:u16le subtype:u16le major:u16le
   minor:u16le size:u32le`.
4. Replay `init_hardcoded` (fixed 581-byte opaque blob, §7.1) as a raw command and
   check status. If step 3's status word was nonzero (fwext not loaded), *also* replay
   `init_hardcoded_clean_slate` (741 bytes, §7.1).

These two blobs are **not TLS records** despite superficially looking similar (they
begin with byte `06`, an opcode meaning "load into RAM" or similar, based on being sent
via plain `usb.cmd`, not `tls.cmd`) — they are fixed, per-model, byte-exact vendor
payloads that must be replayed verbatim. Nothing about them is computed at runtime.

---

## 3. TLS-like secure channel (`tls.py`)

This is a real TLS 1.2 handshake variant — not just a replayed static handshake — using
mutual ECDSA/ECDH authentication, layered inside the sensor's own record framing
(mostly identical to real TLS record framing, with one custom twist: **HMAC-based
record authentication instead of AEAD**, and non-standard record fragmentation before
the handshake is secure). You need real crypto: **ECDSA-P256 sign/verify, ECDH-P256,
AES-256-CBC, HMAC-SHA256, PBKDF-style HMAC-based PRF** — this matches the `openssl`
optional dependency pattern libfprint already uses for `uru4000` (`libfprint/meson.build`
declares `openssl_dep = dependency('openssl', version: '>= 3.0', ...)` as an opt-in
per-driver helper — do the same for this driver rather than pulling in a new crypto lib).

### 3.1 Pairing material (read from sensor flash partition 1, "cert store")

`read_flash(1, 0, 0x1000)` returns a 4096-byte blob, parsed by `parse_tls_flash`
as a sequence of blocks:

```
block := id:u16le size:u16le sha256_digest:32B body:size B
```//
Stop at `id == 0xffff`. Relevant block IDs:

| id | meaning | handling |
|---|---|---|
| 0 | reserved/empty | must be all-zero, else error |
| 1, 2 | reserved 0x100-byte empty blocks | must be all-zero |
| 3 | **device TLS certificate** (`tls_cert`) | stored verbatim, sent back to the sensor during the handshake as the client "certificate" (§3.3) — despite the name this is *not* validated as an X.509 cert by the host; it's opaque bytes the sensor recognizes as belonging to itself |
| 4 | **encrypted client private key** | see below |
| 5 | copy of a hardcoded "CA-ish" blob (`crt_hardcoded`, §7.2) | only relevant if you ever rewrite partition 1 (pairing) — not needed for the normal already-paired path |
| 6 | **sensor's ECDH pubkey + firmware signature** (`ecdh_blob`) | see below |

Each block's SHA-256 must match its stored digest — verify this and abort with a clear
error if it doesn't (indicates corrupt/unpaired flash).

**Block 6 (`handle_ecdh`)** — layout: first 0x90 bytes are the "key" portion, rest is a
signature:
- `x = key[0x08:0x28]`, `y = key[0x4c:0x6c]`, each 32 bytes, **stored little-endian
  reversed** (i.e. reverse the 32 bytes, then interpret big-endian, to get the actual
  P-256 coordinate) — construct an EC point on P-256 from `(x, y)` and validate it's on
  the curve (reject otherwise).
- After the key: `sig_len:u32le`, then `sig_len` bytes of ECDSA signature, then padding
  that must be all-zero.
- **Verify** this ECDSA signature over the raw 0x90-byte `key` blob using SHA-256, with
  the **fixed Synaptics firmware public key** (P-256):
  ```
  x = 0xf727653b4e16ce0665a6894d7f3a30d7d0a0be310d1292a743671fdf69f6a8d3
  y = 0xa85538f8b6bec50d6eef8bd5f4d07a886243c58b2393948df761a84721a6ca94
  ```
  (These are 33-hex-digit values in the Python source, i.e. 264 bits — top nibble is
  from an accidental leading zero-byte in the original hex dump; treat as standard
  256-bit P-256 coordinates and mask/truncate to 32 bytes — confirm against a real
  capture before shipping, this is the one constant in this doc worth independently
  re-deriving from the sensor rather than trusting transcription.) If this check
  fails, abort — it means the flash content isn't genuine Synaptics-signed data.
- On success, this pubkey (`ecdh_q`) is the server/sensor's ephemeral-looking (but
  actually fixed-per-pairing) ECDH public key used in `make_keys()` (§3.4).

**Block 4 (`handle_priv`)** — the client's own EC private key, encrypted:
- `prefix := body[0]`, must be `2`.
- `body[1:]` = `ciphertext (variable) || hmac:32B`. Verify
  `HMAC-SHA256(psk_validation_key, ciphertext) == hmac`; **on mismatch, the error
  message to surface is literally "paired with a different computer"** — this check is
  host-identity-bound, see below.
- `ciphertext = iv:16B || aes_ct`. Decrypt with `AES-256-CBC(key=psk_encryption_key,
  iv)`, then strip standard PKCS7 padding.
- Plaintext layout: `x:32B || y:32B || d:32B`, each **little-endian-reversed** like
  above. `d` is the actual EC private scalar; `x, y` are informational only — construct
  the private key from `d` on curve P-256 (`priv_key = derive_private_key(d, P256)`).

**Host-pairing keys** (`set_hwkey`, computed at driver startup, not stored anywhere):
```
hw_key = ascii(dmi product_name) || 0x00 || ascii(dmi product_serial) || 0x00
psk_encryption_key = PRF(password_hardcoded, "GWK" || hw_key, 32)
psk_validation_key = PRF(psk_encryption_key, "GWK_SIGN" || gwk_sign_hardcoded, 32)
```
Read `product_name` from `/sys/class/dmi/id/product_name` and `product_serial` from
`/sys/class/dmi/id/product_serial` (both already root-readable sysfs files, same
source python-validity uses). `password_hardcoded` and `gwk_sign_hardcoded` are the two
fixed 33-byte constants in §7.2. `PRF` is the TLS 1.2 P_SHA256 pseudorandom function
(§3.5). **This is why a paired sensor is tied to one specific laptop**: if you clone
these flash bytes to different hardware (different DMI serial), block 4's HMAC check
fails. On the ThinkPad X280 itself this is transparent — you're reading its own DMI.

### 3.2 Record framing

Two framing layers:

**Outer record** (used for everything sent over `usb.cmd`/read back), 5-byte header +
payload, big-endian-ish per TLS convention:
```
type:u8  major:u8(=3)  minor:u8(=3)  length:u16be  payload[length]
```
Record types: `0x16` handshake, `0x14` change-cipher-spec, `0x17` application data.
Multiple records may be concatenated in one USB transaction; parse in a loop until the
buffer (padded with zero bytes if it runs short — the Python pads short reads with
`\0` rather than treating it as an error, so be lenient) is consumed.

**Handshake sub-message** (inside a type-0x16 record, itself possibly one or more
concatenated sub-messages once cipher spec is live):
```
msg_type:u8  length:u24be  body[length]
```
Message types: `0x01` ClientHello, `0x02` ServerHello, `0x0b` Certificate,
`0x0d` CertificateRequest, `0x0e` ServerHelloDone, `0x0f` CertificateVerify,
`0x10` ClientKeyExchange, `0x14` Finished.

**Once `secure_tx`/`secure_rx` go true** (see §3.3), handshake and application-data
record *payloads* are wrapped in an authenticate-then-encrypt envelope before being
placed in the outer record (this replaces standard TLS's AEAD — it's HMAC+CBC):
```
sign(type, plaintext):
    header = type:u8  0x03  0x03  len(plaintext):u16be
    tag = HMAC-SHA256(sign_key, header || plaintext)   # NOTE: tag uses sign_key (TX)
    return plaintext || tag                             # tag appended, NOT prepended

encrypt(signed):
    iv = random 16 bytes
    ct = AES-256-CBC-Encrypt(encryption_key, iv, PKCS7pad(signed))
    return iv || ct

# to send: make_app_data / make_handshake wrap as:
record_payload = encrypt(sign(type, plaintext))
```
Decrypt is the mirror: AES-CBC-decrypt with `decryption_key`, strip PKCS7, split off
the last 32 bytes as the HMAC tag, recompute `HMAC-SHA256(validation_key, header ||
body)` (header rebuilt from the *decrypted* body's length) and compare.

**PKCS7 padding used here is non-standard on the encrypt-once path but standard on
decrypt**: `pad()` in python-validity always appends `N` bytes of value `N-1` where `N
= 16 - (len % 16)` (i.e. **minimum 1 pad byte, values are off-by-one from textbook
PKCS7** — a full-block message still gets a 16-byte pad block of `0x0f` bytes, and the
pad *value* is `padlen - 1`, not `padlen`). `unpad()` mirrors this: strip
`1 + last_byte` bytes. **Implement padding exactly this way, both directions** — a
standard PKCS7 implementation will desync by one on every message.

### 3.3 Handshake sequence

1. **ClientHello** (`make_client_hello`), sent as `44 00 00 00` (a 4-byte
   *outer-outer* prefix python-validity always prepends to the very first two USB
   command payloads of the handshake — treat as opaque, always send it) followed by
   the framed handshake record:
   - version `03 03`
   - client_random: 32 random bytes
   - session_id: 1-byte length prefix + 7 zero bytes (`with_1byte_size(7×0x00)`)
   - cipher_suites: 2-byte count-prefixed list of `u16be`: `0xc005`
     (`TLS_ECDH_ECDSA_WITH_AES_256_CBC_SHA`), `0x003d`
     (`TLS_RSA_WITH_AES_256_CBC_SHA256`), `0x008d` (`TLS_RSA_WITH_AES_256_CBC_SHA256`,
     listed twice in source — send exactly this list, only the first suite is ever
     actually selected)
   - compression: 1-byte-length-prefixed empty list
   - extensions: `truncated_hmac` (ext id `0x0004`, body `00 17`) and
     `ec_point_formats` (ext id `0x000b`, body = 1-byte-length-prefixed `00`
     [uncompressed]); **the extensions block's outer length prefix is
     `len(extensions_bytes) - 2`, an off-by-two quirk in the source you must replicate
     verbatim** (`h += pack('>H', len(exts) - 2) + exts`).
   - Wrap as handshake type `0x01`, feed the *whole framed handshake body* (not
     including the record header) into a running SHA-256 (`handshake_hash`) — every
     handshake message, sent or received, gets folded into this hash in order, used
     later for Finished verification and CertificateVerify signing.
2. Send, then parse the response as a stream of records:
   - ServerHello (type 2): version must be `03 03`; parse `server_random:32B`,
     `session_id` (1-byte length prefixed), `cipher_suite:u16be` (must equal `0xc005`
     or abort), `compression:u8` (must be `0`).
   - CertificateRequest (type 0xd): parse `sig_hash_algo:u16be` (must be `0x0140`),
     `ca_list_len:u16be` (must be `0`).
   - ServerHelloDone (type 0xe): empty body.
   - No ServerCertificate or ServerKeyExchange message is actually sent by the sensor
     in this cipher suite — the "server" identity/key material was already obtained
     out-of-band from flash block 6 in §3.1, which is why `TLS_ECDH_ECDSA` works
     without an in-band cert.
3. **Derive session keys** (`make_keys`): generate a fresh local ephemeral P-256
   keypair; ECDH with the sensor's fixed pubkey from block 6 (`ecdh_q`) to get
   `pre_master_secret`; then:
   ```
   seed = client_random || server_random
   master_secret = PRF(pre_master_secret, "master secret" || seed, 0x30)
   key_block      = PRF(master_secret, "key expansion" || seed, 0x120)
   sign_key       = key_block[0x00:0x20]   # used to MAC data WE send
   validation_key = key_block[0x20:0x40]   # used to verify data sensor sends
   encryption_key = key_block[0x40:0x60]   # used to encrypt data WE send
   decryption_key = key_block[0x60:0x80]   # used to decrypt data sensor sends
   ```
4. **Second flight**, again prefixed with `44 00 00 00`, containing four
   sub-messages concatenated:
   - **Certificate** (type 0x0b): body is a triple-nested length-prefixed wrapping of
     `tls_cert` from flash block 3 — replicate exactly:
     ```
     inner  = 0xac16 || tls_cert
     mid    = (0, len(tls_cert)) as >BH || inner        # note: length field lies — it's len(tls_cert), not len(inner)
     outer  = (0, len(tls_cert)) as >BH || mid           # same "wrong" length again
     ```
     (This really is what the source does — two structurally-identical wrapper layers
     both claiming `len(tls_cert)` even though the wrapped body is longer each time.
     Copy it as-is; the sensor apparently doesn't cross-check these lengths.)
   - **ClientKeyExchange** (type 0x10): `04 || x_local_pub[::-1] || y_local_pub[::-1]`
     — uncompressed EC point, 4-prefix byte, each coordinate 32 bytes
     **little-endian-reversed** (consistent with every other EC coordinate in this
     protocol).
   - **CertificateVerify** (type 0x0f): ECDSA-P256-SHA256 signature, using the paired
     private key from flash block 4, over the **current running `handshake_hash`
     digest** (i.e. sign the SHA-256 digest as a pre-hashed message, not re-hash it —
     `ec.ECDSA(Prehashed(SHA256))` in Python).
   - **ChangeCipherSpec** (record type 0x14, not a handshake sub-message): fixed bytes
     `14 03 03 00 01 01`. Sending this sets local `secure_tx = true` **before**
     building the next message.
   - **Finished** (handshake type 0x14): body = `PRF(master_secret, "client finished"
     || handshake_hash_digest, 12)`. Because `secure_tx` just became true, this
     Finished message itself must be sent through the encrypt+sign wrapper from §3.2
     (it's the first encrypted handshake message).
5. Parse the sensor's response: a ChangeCipherSpec record (sets local `secure_rx =
   true`) followed by an encrypted Finished handshake message (type 0x14) — decrypt it
   using the just-derived keys, verify its body equals `PRF(master_secret, "server
   finished" || handshake_hash_digest, 12)` (hash captured at the point just before
   this message, per normal TLS Finished semantics). Any mismatch = abort, re-pairing
   or corrupted flash is the likely cause.

After this, `secure_tx && secure_rx` are both true and every subsequent command uses
the "app data" path (§3.2's type-0x17 wrapping) instead of plain `usb.cmd`.

### 3.4 Steady-state command call

```
app_cmd(payload):
    send outer record: type=0x17, framed = encrypt(sign(0x17, payload))
    read response, unwrap same way, return decrypted app payload bytes
```
All opcodes in §4/§5/§6 (other than the pre-TLS bring-up in §2 and the flash-partition
bootstrap in §3.1) go through this.

### 3.5 PRF (P_SHA256, TLS 1.2 style)

```
PRF(secret, seed, out_len):
    A0 = seed
    A1 = HMAC-SHA256(secret, A0)
    out = ""
    while len(out) < out_len:
        out += HMAC-SHA256(secret, A_i || seed)
        A_(i+1) = HMAC-SHA256(secret, A_i)
    return out[:out_len]
```
(Standard TLS 1.2 PRF with the hash fixed to SHA-256, no dual MD5/SHA1 combining.)

---

## 4. On-sensor database / identity model (`db.py`, `sid.py`)

**Everything is stored on the sensor's own flash (partition 4, "template database"),
not on the host.** The sensor exposes a small generic object-store protocol; all of
these run over `tls.cmd` (i.e. through §3.4 once secure, but note some, like
`get_user_storage`/`get_user`/`lookup_user`/`get_record_value`/`get_record_children`,
are called via `tls.cmd()` which auto-selects plain-vs-encrypted based on session
state — in your driver, once past step 5 of §0 these are always the encrypted path).

Generic record opcodes (2-byte status prefix on every response, as always):

| op | request | response | purpose |
|---|---|---|---|
| `0x45` | (none) | `unknown1:u32le(=1) unknown0:u32le(=0) total:u32le used:u32le free:u32le records:u16le nroots:u16le roots[nroots]:u16le[]` | `db_info()` — space accounting + root record IDs |
| `0x46` | `dbid:u16le` | `_pad2 dbid:u16le type:u16le storage:u16le size:u16le count:u16le _pad2 children[count]{dbid:u16le,type:u16le}` | get a record's children list |
| `0x47` | `parent:u16le type:u16le storage:u16le len:u16le data[len]` | `newid:u16le` (after status) | create a new record (must precede with `db_write_enable` blob, §7.3, and follow with cleanup opcode `0x1a` in a finally-block — see below) |
| `0x48` | `dbid:u16le` | status only | delete a record |
| `0x49` | `dbid:u16le` | `_pad2 dbid:u16le type:u16le storage:u16le size:u16le _pad2 value[size]` | get a record's raw value |
| `0x4a` | `dbid:u16le` (get-by-id) **or** `0x0000 storage_dbid:u16le datalen:u16le data[datalen]` (lookup-by-identity) | `_pad2 dbid:u16le fingercount:u16le _pad2 identitysize:u16le fingertab[fingercount]{dbid:u16le,subtype:u16le,storage:u16le,valsize:u16le} identity[identitysize]` | get/find a "user" record; status `0x04b3` = not found (treat as a soft miss, not an error) |
| `0x4b` | `dbid:u16le namelen:u16le name[namelen]` (name is C-string incl. NUL, or empty to look up by dbid) | `_pad2 recid:u16le usercount:u16le namesize:u16le _pad2 usertab[usercount]{dbid:u16le,valsize:u16le} name[namesize]` | get/find a "storage" (container) record; status `0x04b3` = not found |
| `0x1a` | (none) | status (`0x0491` = "nothing to commit", treat as success) | commit/cleanup after a write — **always call this in a `finally` after any `0x47`/write-enable/erase sequence**, matching python-validity's `call_cleanups()` |

**Well-known storage**: all user/finger records live under a storage container named
`"StgWindsor\0"` (12 bytes incl. NUL — note the Python appends the NUL itself and skips
it entirely for the zero-length "root" lookup case). Look it up once via opcode `0x4b`
with that name to get its `dbid`, cache it for the session.

**Record types you'll create/read** (the `type` field in `0x47`/`0x46`/`0x49`):
- `5` — a **user** record. `data` = identity blob (below). Created as a child of the
  StgWindsor storage dbid.
- `0xb` — a **finger/template** record (the sensor silently stores it as type `6`
  regardless of the `0xb` you request — this is intentional per a comment in the
  source: *"because of the magical `db_write_enable` in `new_record()` it ends up
  being 0x6"*). `data` = the finger blob from §5.
- `8` — a raw **data** blob record (used by `new_data`, wraps payload as
  `tag=1:u16le len:u16le data`) — not needed for the core enroll/verify path, skip
  unless you need parity with python-validity's lower-level tooling.

**Identity blob** (what a "user" record's value actually is) — python-validity encodes
a Windows SID here because that's what the Windows driver stores, but **there is no
requirement to use SID semantics on Linux** — the sensor just stores/compares opaque
bytes:
```
identity_bytes := type:u32le(=3) len:u32le sid_bytes[len]  padded with 0x00 to at least 0x4c bytes total
sid_bytes := revision:u8 subauth_count:u8 authority:u48be subauth[count]:u32le[]
```
For the libfprint driver, synthesize a fixed-format identity per libfprint enrollment
(e.g. a constant revision/authority with one sub-authority = a stable hash of
`fpi_print_generate_user_id()`'s output, or of the raw username libfprint gives you) —
document this as an internal convention, it does not need to look like a real Windows
SID, it just needs to be a stable, collision-resistant key so `lookup_user` can find
the right sensor-side user record again on a later enroll/verify for the same
libfprint user.

**Write-gating**: every mutating call (`new_record`/opcode `0x47`, `erase_flash`,
`write_flash`) must be preceded by replaying the fixed `db_write_enable` blob (3621
bytes, §7.3) via a plain `tls.cmd` (encrypted once past handshake) and status-checked,
and followed by opcode `0x1a` in a `finally`. Treat `db_write_enable` as a one-shot
"unlock" token consumed by the next write, not a session-wide toggle — replay it before
every single write op, exactly like python-validity's `write_enable()`/`new_record()`
do.

---

## 5. Enroll / match command opcodes (`sensor.py`)

All of these are `tls.app(...)` calls (post-handshake, always encrypted). Every
response has the usual 2-byte status prefix (checked, then stripped, in the tables
below).

### 5.1 Capture (shared by enroll and identify)

Capture is **not** "take a picture" — it's "run the sensor's on-chip DSP program that
turns raw scan lines into either a fresh enrollment fragment or a match decision",
using the per-model microcode described in §6. Opcode `0x02`:
```
request:  0x02  bytes_per_line:u16le  req_lines:u16le  chunks...
```
where `chunks` is the TLV-chunk-encoded (see §6.1) capture program, built fresh for
every capture call from the cached "hardcoded program" plus mode-specific patches
(`CaptureMode.ENROLL` vs `CaptureMode.IDENTIFY` vs `CaptureMode.CALIBRATE` — see §6.2).
`req_lines` is nonzero only for `CALIBRATE` mode (used to size the bulk-endpoint read
that follows); leave it `0` for enroll/identify.

After sending, the actual scan is asynchronous and reported via the **interrupt
endpoint** (§1, EP 0x83), consumed with `wait_int()`:
1. First interrupt: byte 0 must be `0` ("capture armed"). Anything else is an error.
2. Loop reading interrupts until byte 0 is `2` ("finger detected").
3. Loop reading interrupts until byte 0 is `3` ("scan event") **and** `byte[2] & 4` is
   set ("capture complete" flag within the scan-event byte) — other `3` events with
   that bit clear should be ignored and you keep waiting.
4. Read status via opcode `0x51 00 20 00 00` (`get_prg_status2`): response after the
   2-byte status is `len:u32le` then `len` bytes; further parse those bytes as
   `x:u16le y:u16le w1:u16le w2:u16le error:u32le` (finger placement/width telemetry —
   only `error` matters for driver logic: nonzero = scan failed, surface as a retry
   with `FP_DEVICE_RETRY_*`).
5. **Always**, in a `finally`, send `0x04` (capture-stop/cleanup) regardless of outcome
   — this matches python-validity's `finally: tls.app(unhexlify('04'))` in `capture()`.

Two other read-only status opcodes exist and are useful for a spinner/progress UI but
not required for correctness: `0x51 00 00 00 00` (`get_prg_status`, poll until byte 0
is `0` or `7`) and reading raw frame data off EP 0x82 (`read_82`, only relevant during
`CALIBRATE` — see §6.3).

### 5.2 Enroll flow

```
enroll_start        := 0x69 01:u32le                     -- "create_enrollment"
enroll_update_begin := 0x68 key:u32le 0:u32le  → new_key:u32le   -- "enrollment_update_start"
enroll_append       := 0x6b prev_template_bytes           -- "enrollment_update" / append_new_image
enroll_end          := 0x69 00:u32le                       -- "enrollment_update_end"
```
Loop (this is `Sensor.enroll` in the source):
1. Send `enroll_start` once, before the loop.
2. Per attempt: run a capture in `CaptureMode.ENROLL` (§5.1).
3. `enroll_update_begin` with `key` = the value returned by the *previous* iteration
   (start with `0`); **must be write-enabled** (§4) before this call, and cleaned up
   (`0x1a`) in a `finally` regardless of success. Then `wait_int()` once (a bookkeeping
   interrupt, discard its contents).
4. `enroll_append`, sending the **previous accumulated template bytes** (empty on the
   first iteration) as the payload after opcode `0x6b`. **This call happens twice per
   iteration** — python-validity calls `enrollment_update(prev)` once "to generate an
   interrupt" (discarding the immediate reply and consuming one `wait_int()`), then
   calls it *again* with the same `prev` bytes to actually get the parsed reply. Do
   the same: call, wait_int(), call again, and only parse the second response.
5. Parse the response of that second call as a **TLV stream with an odd fixed-header
   quirk**: after the 2-byte status and a `total_len:u16le`, repeatedly read
   `tag:u16le len:u16le` then a body — **but the body for tag values you care about
   starts `0x38` bytes ("magic_len", hardcoded) into what's actually a `magic_len+len`
   sized chunk**, i.e.:
   ```
   while remaining:
       tag, len = read u16le, u16le
       chunk = next (0x38 + len) bytes
       if tag == 0: template = chunk                      # keep the FULL chunk (header+body) as the new accumulated template
       elif tag == 1: header = chunk[0x38:]                # only the body past the magic header
       elif tag == 3: tid = chunk[0x38:]                   # match id / template-complete marker
       # else: ignore unknown tag
   ```
6. Report progress via `header` (pass whatever bytes you got to
   `fpi_device_enroll_progress`, it's opaque UI-facing telemetry, not something you
   need to interpret). If `tid` is present/non-empty, enrollment converged — break
   the loop. Otherwise loop back to step 2, carrying `template` forward as the next
   iteration's `prev`.
7. On any exception mid-loop other than cancellation: report it via the progress
   callback (as an error) and loop again (retry) — do **not** abort the whole
   enrollment on a single bad capture, mirroring python-validity's `except Exception:
   update_cb(None, e)` (no `continue`/`break`, it just falls through to the
   `finally: enrollment_update_end()` and loops).
8. After the loop breaks (successful `tid`), call `enroll_end` **twice** ("done twice
   for some reason" — verbatim comment in the source; just replicate it, it's
   presumably harmless idempotent cleanup, not worth root-causing).
9. Build the **finger blob** to persist (this becomes your `FpPrint`'s opaque device
   data):
   ```
   finger_blob := subtype:u16le  3:u16le  len(tinfo):u16le  0x20:u16le  tinfo  0x20-bytes-of-zero
   tinfo       := (1:u16le len(template):u16le template) || (2:u16le len(tid):u16le tid)
   ```
   `subtype` here is finger-placement (which finger was enrolled — python-validity has
   a `finger_names` table in `fingerprint_constants.py` mapping small integers to
   names like "Left Thumb"; for a libfprint driver you can just pick a fixed constant,
   e.g. `1`, since libfprint doesn't need Windows' finger-placement taxonomy — nothing
   downstream depends on the value being meaningful, only that it's stable for
   `get_finger_blobs`-style lookups if you ever implement those).
10. Create the sensor-side record: look up (or create) the user record for the
    identity (§4's `0x4a`/`0x47` on type `5`), then create a finger record (`0x47`
    type `0xb`) as its child with `finger_blob` as the data (§4's write-gating
    applies). The returned `recid` (finger record dbid) plus the storage dbid and
    identity bytes are what you should serialize into the `FpPrint`'s driver data —
    see §8.

### 5.3 Match / identify flow

```
match_start := 0x5e 02 ff  stg_id:u16le(=0) usr_id:u16le(=0) 1:u16le 0:u16le 0:u16le  -- "match any storage, any user"
match_read  := 0x60 00 00 00 00
match_stop  := 0x62 00 00 00 00   -- always sent in a finally, mirrors capture's opcode 0x04
```
1. Run a capture in `CaptureMode.IDENTIFY` (§5.1) — retry on failure with a 1-second
   backoff (python-validity's `identify()` loop: catch, report error via callback,
   `sleep(1)`, retry; only `CancelledException`/`USBError` propagate immediately).
2. Send `match_start`. Wait on the interrupt endpoint for a `3` event (any other value
   is "finger not recognized" — surface as a no-match / retry condition, not a hard
   error).
3. Send `match_read`. Response, after 2-byte status and a `total_len:u16le`, is a
   dict-style TLV stream (`tag:u16le len:u16le body[len]`, no `0x38` quirk this time —
   that quirk was specific to §5.2's enrollment response) with at least tags `1`
   (`usrid:u32le`), `3` (`subtype:u16le`), `4` (`hash` — opaque, used only for
   host-side bookkeeping/logging in python-validity, safe to ignore or surface as
   debug info).
4. Always send `match_stop` in a `finally`, ignore its result (best-effort cleanup).
5. `usrid` from step 3 is a **sensor-side record dbid**, not your host identity —
   resolve it back to a libfprint `FpPrint` by comparing against the dbids you
   recorded when you created/enrolled prints (§5.2 step 10), or by calling `0x4a`
   with that dbid to fetch the identity bytes and matching them against what you
   stored per-`FpPrint`. This is the sensor doing 1:N matching entirely on-chip —
   the host never sees template data or does any comparison math itself.

---

## 6. Sensor identification, capture-program microcode, and calibration

This is the part of the protocol that is genuinely **hardware calibration data**, not
cryptography or a documented command set — extracted by the original python-validity
author from Synaptics' Windows driver DLL by disassembly/dumping, not derived from any
public spec. Treat this whole section as "replay this data, don't try to derive it."

### 6.1 Chunk / TLV container format

Used both for the on-wire capture-program payload (opcode `0x02`, §5.1) and for the
cached `hardcoded_prog` table entries:
```
chunk := type:u16le size:u16le payload[size]
```
A capture program is just a flat sequence of these chunks concatenated
(`split_chunks`/`merge_chunks` in `timeslot.py`). Chunk `type` values of interest (full
table of ~70 is in `timeslot.py:codes`, only the ones the driver actively touches):

| type | name | driver relevance |
|---|---|---|
| `0x2f` ("2D") | frame geometry | contains a `u32le` = lines-per-frame numerator; read once at sensor-open time to compute `lines_per_frame = value * repeat_multiplier` |
| `0x34` ("Timeslot Table 2D") | the actual microcode program (§6.2's bytecode) | rewritten per capture (patched) before every send |
| `0x17` ("Reply Configuration") | empty-bodied marker, always appended | append with empty payload for every mode |
| `0x4e` / `0x26` ("WTF" / "Finger Detect") | fixed opaque per-mode blobs (given verbatim in `sensor.py`, differ between the two known "line update" device families, see §6.2) | append verbatim, chosen by mode: `0x4e` chunk for IDENTIFY, `0x26` chunk for ENROLL |
| `0x2e` ("Image Reconstruction") | fixed opaque per-mode blob (one byte differs between IDENTIFY/ENROLL variants) | append verbatim per mode |
| `0x44` ("Line Update InterLeave") | `u32le` = 1 | only for "type 1" devices (§6.2), appended after the mode-specific chunks |
| `0x30` ("Line Update") | calibration/register-write payload, built at runtime from calibration state, §6.2 | |
| `0x43` ("Line Update Transform") | companion payload to `0x30` for "type 1" devices only | |

### 6.2 Timeslot-table bytecode (the "microcode")

A tiny fixed-width instruction encoding, decoded/patched by
`patch_timeslot_table`/`patch_timeslot_again`/`find_nth_insn`/`find_nth_regwrite`.
Full opcode table (bit patterns tested top-to-bottom, first match wins):

| byte pattern | opcode name | length | operands |
|---|---|---|---|
| `0x00` | NOP | 1 | — |
| `0x01` | End of Table | 1 | — |
| `0x02` | Return | 1 | — |
| `0x03` | Clear SO | 1 | — |
| `0x04` | End of Data | 1 | — |
| `0x05 xx` | Macro | 2 | `xx` |
| `0x06 xx` | Enable Rx | 2 | `xx` |
| `0x07 xx` | Idle Rx | 2 | `xx==0 ? 0x100 : xx` |
| `0x08/0x09 xx` (byte0 & 0xfe == 0x08) | Enable SO | 2 | `((byte0&1)<<8)|xx` |
| `0x0a/0x0b xx` (byte0 & 0xfe == 0x0a) | Disable SO | 2 | `((byte0&1)<<8)|xx` |
| `0x0c..0x0f` (byte0 & 0xfc == 0x0c) | Interrupt | 1 | `byte0 & 3` |
| `0x10..0x17 xx yy` (byte0 & 0xf8 == 0x10) | **Call** | 3 | `rx_inc=byte0&7, addr=xx<<2, repeat=(yy==0?0x100:yy)` |
| `0x20..0x3f xx` (byte0 & 0xe0 == 0x20) | Features | 1 | `byte0 & 0x1f` |
| `0x40..0x7f xx yy` (byte0 & 0xc0 == 0x40) | **Register Write** | 3 | `addr = (byte0&0x3f)*4 + 0x80002000, value = xx \| (yy<<8)` |
| `0x80..0xbf` (byte0 & 0xc0 == 0x80) | Sample | 1 | `(byte0>>3)&7, byte0&7` |
| `0xc0..0xff xx` (byte0 & 0xc0 == 0xc0) | Sample Repeat | 2 | `(byte0>>3)&7, byte0&7, xx==0?0x100:xx` |

`patch_timeslot_table(bytes, inc_address, mult)` walks this bytecode and, for every
**Call** instruction whose `repeat` field is `> 1`, multiplies `repeat` by `mult` and
(if `inc_address`) increments `addr`'s low byte by one; it stops at the first byte that
isn't NOP/Interrupt/one of the patched forms (i.e. it only patches a specific known
prefix pattern, then bails as soon as something else appears).

`patch_timeslot_again(bytes)` (only called for non-CALIBRATE modes): finds the *last*
Call instruction's destination address, jumps there, then finds the *last* Register
Write to address `0x8000203c` from that point forward, and overwrites that
instruction's low value byte with
`factory_calibration_values[key_calibration_line]` (a per-sensor-type constant offset,
§6.3).

**Two "line update" device families**, selected purely by `device_info.type` (a
constant baked into the per-device lookup table, §6.4) being a member of the hardcoded
`line_update_type1_devices` list (`{0xB5, 0x885, 0xB3, 0x143B, 0x1055, 0xE1, 0x8B1,
0xEA, 0xE4, 0xED, 0x1825, 0x1FF5, 0x199}`) or not:
- **Type 1** (`line_update_type_1`): more complex `Line` construction with bit-packed
  calibration data (`bitpack()` — a variable-bit-width delta encoder, see below),
  writes both a `0x30` and `0x43` chunk, uses the `0x4e`/`0x2e` fixed blobs shown
  verbatim in §5.1's table for IDENTIFY and `0x26`/`0x2e` for ENROLL, targets register
  `0x8000203c`.
- **Type 2** (`line_update_type_2`): simpler, three fixed `Line`s (calibration blob,
  factory calib *data*, factory calib *values*), writes only a `0x30` chunk, same
  `0x4e`/`0x26`/`0x2e` blob selection but with slightly different embedded geometry
  bytes (compare the hex blobs in `sensor.py` — type 2's blobs encode `0x60,0x01`/
  `0x40,0x01` width/height where type 1's encode `0x87,0x00`/`0x67,0x00`, i.e. these
  are genuinely different per-hardware-geometry constants, not copy-paste noise),
  targets registers `0x800020fc` then `0x8000203c`.

  **Determine which family the 06cb:009a sensor on this laptop actually needs by
  reading its real `device_info.type` at runtime** (opcode `0x75`, §6.4) and checking
  list membership — don't hardcode a family in the C driver, replicate the same
  runtime branch.

`bitpack(bytes)`: given a byte array, compute `min`/`max`, encode each byte as a
fixed-width `u = ceil(log2(max-min+1))`-bit value `(byte - min)`, pack all `len(bytes)`
such values little-endian-bit-order into a byte buffer. Returns `(u, min,
packed_bytes)`. This is a simple variable-bit-width delta codec — implement directly,
it's about 15 lines of C.

### 6.3 Calibration

Run once per cold sensor (result cached to sensor flash partition 6, "calibration
data" per the partition table in §7... actually per `init_flash.py`'s layout comment —
partition id 6). `Sensor.calibrate()`:
1. If a cached clean-slate blob already exists on partition 6 and its stored SHA-256
   over the image matches (`check_clean_slate`), skip straight to done — **this will
   be the common case on a laptop that's already been calibrated once**, whether by
   python-validity or the factory Windows driver.
2. Otherwise, run `calibration_iterations` (a per-sensor-type constant, currently only
   two device "types" are known/handled: `0x199` → 3 iterations, `0xdb` → 0 iterations;
   **any other `device_info.type` value is currently unsupported by python-validity and
   raises — confirm which of these two this exact X280 sensor reports before assuming
   either path**, §6.4) capture passes in `CaptureMode.CALIBRATE`, each followed by a
   bulk read off EP 0x82 (`usb.read_82()`) and an averaging/accumulation step
   (`average()`/`process_calibration_results()` — line-wise averaging across
   interleaved calibration frames, then per-line signed-delta accumulation across
   iterations; not required reading to *implement* correctly since you're replaying
   the same math, just budget for porting ~60 lines of arithmetic faithfully).
3. Do one more capture to get a "clean slate" reference frame, wrap it with a length
   prefix, a trailing zero-u16, then a `len + sha256 + 32-zero-bytes + payload` header,
   and persist it to flash partition 6 with a leading `magic:u16le = 0x5002` (see
   `Sensor.calibrate`/`persist_clean_slate`/`check_clean_slate` for the exact byte
   layout — small enough to port directly from source, no independent extraction
   needed).

Given calibration is idempotent and cached on-device, a reasonable v1 driver scope is:
**implement the "already calibrated, load cached data" path fully, and treat the
from-scratch calibration path as a stretch goal** — on this specific laptop, if
python-validity (or Windows) has ever calibrated the sensor, your new driver inherits
that cached state for free via partition 6.

### 6.4 Per-model lookup tables (`hw_tables.py`, `generated_tables.py`,
`table_types.py`, `firmware_tables.py`)

These four files (488 + 775 + 102 + 33 lines) are **pure data**: a `dev_info_lookup(major,
minor)` table mapping the ROM-reported major/minor version (from opcode `0x75`,
`identify_sensor()`) to a device name + `type` constant (the `0x199`/`0xdb`/etc. values
referenced throughout §6.2–6.3); a `SensorTypeInfo` table keyed by that `type`, giving
`bytes_per_line`, `repeat_multiplier`, `lines_per_calibration_data`, `line_width`, and a
fixed `calibration_blob`; a `SensorCaptureProg.get(rom_info, type, 0x18, 0x19)` lookup
returning the actual fixed `hardcoded_prog` byte string (the seed capture-program
chunks from §6.1, before per-capture patching) for a given ROM build; and a flash-IC
JEDEC-ID lookup table used only during from-scratch pairing (out of scope per §0 step
2).

**Do not hand-transcribe these.** They're mechanical lookup tables, not protocol logic.
Write a one-off Python script that imports python-validity's modules and dumps the
specific rows your actual sensor resolves to (call `identify_sensor()` and
`SensorTypeInfo.get_by_type()` against the real hardware, or just run python-validity
once against this laptop and log what it resolves `device_info.type`/`rom_info`/
`hardcoded_prog`/`calibration_blob` to) into a small generated C header with the
concrete bytes for **this one sensor model**, rather than porting the whole
multi-device lookup-table system. You only need the row(s) that 06cb:009a's ROM
actually reports, not the other three device families' data.

---

## 7. Fixed vendor blobs (verbatim data, not logic)

All present in `reference/python-validity/validitysensor/blobs_9a.py` /
`tls.py`. Sizes below are from direct inspection of `blobs_9a.py`.

### 7.1 Bring-up blobs (§2), `blobs_9a.py`
- `init_hardcoded` — 581 bytes, replayed as the last step of `usb.send_init()`.
- `init_hardcoded_clean_slate` — 741 bytes, replayed only if step 3 of §2 reported
  fwext-not-loaded.
- `reset_blob` — 12037 bytes, used by `factory_reset()`/from-scratch pairing (§0 step
  2's out-of-scope path) — not needed for the normal already-paired flow, but keep it
  around if you ever implement a "wipe and re-pair" maintenance command.

### 7.2 TLS-related constants, `tls.py` top
- `password_hardcoded` — 33 bytes (hex `717cd7...ec2033`), root secret for deriving
  `psk_encryption_key`/`psk_validation_key`/`hs_key` (§3.1).
- `gwk_sign_hardcoded` — 33 bytes, second input to `psk_validation_key` derivation.
- `crt_hardcoded` — a fixed ~620-byte structure only relevant to the from-scratch
  pairing/rewrite path (written back as flash block 5); not needed for the read-only
  already-paired flow this driver targets.
- The **fixed Synaptics firmware ECDSA verification pubkey** given inline in §3.1
  (used to verify flash block 6).

### 7.3 Database write-gate, `blobs_9a.py`
- `db_write_enable` — 3621 bytes, replayed before every mutating DB/flash op (§4).

### 7.4 Firmware extension binary — NOT included in python-validity

`upload_fwext()` needs a file named **`6_07f_lenovo_mis_qm.xpfwext`** for this device
(`firmware_tables.py:FIRMWARE_NAMES[DEV_9a]`), which python-validity does **not**
redistribute. It's extracted at install time from Lenovo's own Windows driver
installer:
```
driver:   https://download.lenovo.com/pccbbs/mobiles/nz3gf07w.exe
referral: (same URL)
sha512:   a4a4e6058b1ea8ab721953d2cfd775a1e7bc589863d160e5ebbb90344858f147d695103677a8df0b2de0c95345df108bda97196245b067f45630038fb7c807cd
```
The `.exe` is a self-extracting Lenovo driver package; the `.xpfwext` file is inside
it. **On this X280, this step is almost certainly already done** — if the sensor has
ever successfully initialized under python-validity or stock Windows, the firmware is
already persisted on sensor flash partition 2 and `get_fw_info(2)` will report it
present, so `upload_fwext` is a no-op read. Implement the upload path only as a
fallback for a genuinely blank sensor, and when you do, source the `.xpfwext` the same
way python-validity does — fetch the *user's own* copy of Lenovo's public driver
package and extract from it, don't bundle/redistribute the extracted firmware in the
driver's source tree or git history.

---

## 8. Mapping onto libfprint's driver API

Reference implementations studied: `libfprint/libfprint/drivers/elanmoc/elanmoc.c` and
`egismoc/`. Both are match-on-chip, device-storage-backed drivers structurally very
close to what this device needs — model this driver the same way rather than as an
`FpImageDevice` (there is no image to hand back to libfprint; matching is entirely
sensor-side).

### 8.1 Feature flags / class setup
```c
dev_class->type = FP_DEVICE_TYPE_USB;
dev_class->id_table = id_table;            // { .vid = 0x06cb, .pid = 0x009a }, ...
dev_class->scan_type = FP_SCAN_TYPE_PRESS;
dev_class->nr_enroll_stages = N;           // however many capture iterations enroll typically needs; not fixed by the protocol (§5.2 loops until the sensor signals `tid` present) — pick a representative number (python-validity's Windows-driver-derived flow typically converges in ~8-16 touches for these sensors; tune from real testing) and still handle early/late convergence by driving fpi_device_enroll_progress with the actual completed-stage count, letting libfprint core clamp
dev_class->open = ...; close = ...; enroll = ...; identify = ...; delete = ...; list = ...; clear_storage = ...;
fpi_device_class_auto_initialize_features (dev_class);
// then fpi_device_update_features to turn on:
//   FP_DEVICE_FEATURE_STORAGE | FP_DEVICE_FEATURE_STORAGE_LIST |
//   FP_DEVICE_FEATURE_STORAGE_DELETE | FP_DEVICE_FEATURE_STORAGE_CLEAR |
//   FP_DEVICE_FEATURE_IDENTIFY | FP_DEVICE_FEATURE_VERIFY
// (verify falls back to identify automatically per fpi-device.h's doc comment on @verify)
```

### 8.2 `open` callback
Drive the full §0 sequence as an `FpiSsm` state machine (see `elanmoc_open` for the
idiom): USB claim → §2 bring-up → §3.1 flash read + §3.2-3.4 handshake → §0 step 6
firmware check (skip upload path initially, just verify `get_fw_info(2)` succeeds) →
§6.4 device identify + §6.3 calibration-cache check → §4 `StgWindsor` storage lookup
(create if absent, mirroring `init_db()`). Call `fpi_device_open_complete()` at the
end. Store the derived session keys, cached storage dbid, and device-type-derived
constants (§6.2/§6.4) in your `FpiDeviceSynaWbdi` instance struct (parallel to
`FpiDeviceElanmoc` in `elanmoc.h`).

### 8.3 `enroll` callback
Implement §5.2's loop as an `FpiSsm`. Get the enroll template/user id via
`fpi_device_get_enroll_data(device, &print)` at the start (libfprint gives you a
pre-populated `FpPrint` with the requested finger/username metadata — synthesize your
identity bytes, §4, from it here). Call `fpi_device_enroll_progress(device,
completed_stages, print, error)` once per capture iteration (§5.2 step 6). On success:
```c
fpi_print_set_type (print, FPI_PRINT_RAW);
fpi_print_set_device_stored (print, TRUE);
```
then serialize {storage dbid, finger record dbid, identity bytes} into the print's
opaque driver data (libfprint's `FpiPrintType` `RAW` variant stores a `GVariant`
byte-blob you control the format of — see how `elanmoc` packs its own record id into
that blob for the exact accessor pattern) and call `fpi_device_enroll_complete(device,
print, NULL)`. On unrecoverable error, `fpi_device_enroll_complete(device, NULL,
error)`.

### 8.4 `verify` / `identify` callback
Implement §5.3. `fpi_device_get_verify_data`/`fpi_device_get_identify_data` give you
the print(s) to compare against (their opaque blob has the finger dbid you stored in
§8.3). Run one capture+match cycle; when the sensor returns a `usrid`/finger dbid,
compare it against the candidate print(s)' stored dbid — for `verify`, report match via
`fpi_device_verify_report(device, FPI_MATCH_SUCCESS or FPI_MATCH_FAIL, print, NULL)`
then `fpi_device_verify_complete`; for `identify`, find the matching entry in the
`prints` array libfprint gave you and report via `fpi_device_identify_report(device,
matched_print_or_NULL, print, NULL)` then `fpi_device_identify_complete`. A capture
that legitimately fails to recognize any registered finger is `FPI_MATCH_FAIL`, not an
error — reserve `GError` for actual protocol/transport failures.

### 8.5 `list` / `delete` / `clear_storage`
`list`: enumerate the `StgWindsor` storage's children (§4's `0x46`/`0x4a`), reconstruct
an `FpPrint` per finger record from what you stored on enroll (or, if you didn't cache
enough, from the record's own raw value, §4's `0x49` — the finger blob format in §5.2
step 9 is self-describing enough to recover `subtype`, though not a human identity
without also fetching the parent user record). `delete`: opcode `0x48` (§4) on the
finger dbid from the given `FpPrint`'s blob, wrapped in the write-gate (§4). Both
straightforward direct opcode calls, no capture/interrupt handling needed —
model as simple two-step `FpiSsm`s like `elan_delete_run_state`.
`clear_storage`: iterate and delete, or — if acceptable — replay `reset_blob` (§7.1)
and re-run pairing bootstrap; recommend the iterate-and-delete approach for a first
version since it avoids the from-scratch-pairing code path entirely.

### 8.6 Cancellation
Map `dev_class->cancel` to setting a flag your capture/enroll/interrupt-polling loop
checks between each short-timeout interrupt read (§1), mirroring
`usb.CancelledException`. Use `fpi_device_action_is_cancelled(device)` directly instead
of a hand-rolled flag if the `FpiSsm` structure makes that convenient — same effect.

---

## Summary of answers to the five scoping questions

**(a) Match-on-chip or host-side matching?** Genuinely match-on-chip: the sensor's own
firmware does minutiae extraction (during the enroll `0x6b` append loop) and 1:N
comparison (`0x5e`/`0x60` match opcodes) entirely on-device. The host never sees or
computes template data — it only runs a raw-line "capture" step (driven by replayed
per-model microcode + calibration tables) to feed the chip's DSP, then asks it for a
verdict. Map this to libfprint as a `FP_DEVICE_FEATURE_STORAGE`-backed match-on-chip
driver (§8), same family as `elanmoc`/`egismoc`, not an `FpImageDevice`.

**(b) Is firmware upload required for 06cb:009a?** Only on a genuinely blank/unflashed
sensor. On this X280 — which has presumably already run either the stock Windows
driver or python-validity — firmware (partition 2) and TLS pairing data (partition 1)
are already persisted on the sensor's own flash, so a first version of this driver can
treat both as read-only preconditions and skip implementing the upload/pairing
write-paths entirely (§0 steps 2 and 6 both short-circuit to a no-op read in the common
case). The firmware blob itself, if ever needed, is not redistributable — it's
extracted by the user from Lenovo's own driver download (§7.4).

**(c) Fixed replay or real crypto?** Real crypto: a TLS-1.2-shaped mutual-auth
handshake with actual ECDSA-P256 signing/verification, ECDH-P256 key agreement, and a
TLS 1.2 PRF — layered with HMAC-SHA256 message authentication (not AEAD) and AES-256-
CBC encryption with a non-standard PKCS7 pad-value convention (§3.2). Use OpenSSL
(≥3.0) for these primitives, matching the existing opt-in pattern the `uru4000` driver
already uses in `libfprint/meson.build`. Only the *pre-TLS bring-up blobs* (§2, §7.1)
and the *capture-program microcode/calibration tables* (§6) are fixed replayed data —
the secure channel itself is genuinely negotiated per session using the sensor's
factory-paired keypair.

**(d) Spec doc location:** `docs/protocol-spec.md`
(this file).

**(e) Red flags for a clean upstream-able reimplementation:**
1. **§2's bring-up blobs and §6's capture microcode/calibration tables are literal
   vendor data**, not derivable protocol logic — no way to "cleanly reimplement" them,
   only to carry them as opaque constants (same category as a firmware blob). They
   originate from python-validity's disassembly of Synaptics' Windows driver DLL.
   python-validity ships them under its own MIT license as their compiled/extracted
   work product; whether upstream libfprint (which otherwise avoids embedding
   vendor-extracted binary constants directly in driver `.c` files, preferring
   documented protocols like the existing BMKT `synaptics` driver, itself
   Synaptics-authored) will accept a driver built around them is a project/legal
   question for the libfprint maintainers, not a code-correctness one — worth raising
   explicitly in the PR description rather than letting it surprise reviewers.
   Suggest treating these tables the way Linux treats redistributable firmware blobs
   (a separate clearly-labeled data file/header, provenance noted in a comment linking
   back to python-validity) rather than hiding them inline in protocol logic.
2. **The one fact in this whole spec worth independently re-verifying against a live
   capture before shipping**, rather than trusting the transcription here or in the
   Python source: the fixed Synaptics firmware ECDSA pubkey coordinates in §3.1 (they
   carry an odd extra hex nibble in the original source, most likely an artifact of
   how the constant was dumped — confirm the actual 256-bit values by running
   python-validity against this exact sensor with tracing on and diffing, rather than
   copying the possibly-off-by-a-nibble constant blind).
3. **`db_write_enable` (§7.3) is functionally a "disable the object-store's normal
   write protection" token** — it's necessary and it's what python-validity does, but
   call out in the PR that this driver only ever uses it for the narrow, intended
   enroll/delete recordkeeping operations in §4/§5, not as a general unlock — reviewers
   concerned about "security issue" framing will want to see that the write-gate is
   used exactly the same way the vendor's own Windows driver uses it, for the same
   narrow set of operations, with no expansion of capability.
4. No DRM/anti-circumvention concerns beyond the above: nothing here defeats a
   copy-protection or access-control mechanism protecting copyrighted *content* — the
   TLS layer authenticates *host-to-sensor pairing* (so a stolen/cloned sensor doesn't
   work on another machine), which this driver replicates faithfully rather than
   bypassing (it still requires the sensor's genuine factory-paired keys from flash,
   §3.1 — it does not forge or strip that binding).
