# Sol Registry — Identity, Signing & Trust

## Overview

Sol's trust model has two layers that work together:

- **Content addressing** — the hash in a URI guarantees the script content has
  not changed since it was published. Anyone can verify this locally with no
  network access.
- **Signatures** — the Ed25519 signature attached to every published module
  guarantees the content was intentionally published by the holder of a
  specific private key, whose public key is registered under a known username.

Together these mean: when you write `use "jasenqin.1000.myscript#abc..."` you
are asserting both "I want exactly this content" and "I trust that
jasenqin.1000 published it." Neither guarantee alone is sufficient — content
addressing without identity doesn't tell you who you're trusting, and identity
without content addressing allows silent updates.

---

## Registration — `sol register`

Before uploading anything, a user must register once with the registry. This
establishes their namespace and generates their signing keys.

### Interactive flow

```
$ sol register

Sol Registry — New User Registration
Registry: https://sol-registry.org

Name:     Jasen Qin
Email:    jasen@example.com

Checking availability...
Username assigned: jasenqin.1000

Generating Ed25519 key pair...
Keys written to ~/.sol/key.json

Registration complete.
Your namespace: jasenqin.1000
Public key:     ed25519:8f3a2c...

You can now upload scripts with: sol upload <script.sol>
```

### What happens on the server

1. The registry receives `{name, email}`, generates a unique username of the
   form `handle.NNNN` where `handle` is derived from the name and `NNNN` is a
   disambiguating number assigned by the server (auto-incrementing per handle
   collision). This guarantees global uniqueness without requiring users to
   invent a username.
2. The server stores `{username, name, email, public_key, registered_at}` and
   creates the user's namespace. No two users share a username.
3. The server returns the assigned username. The client generates the key pair
   locally, sends the public key to the server to associate with the account,
   and stores the private key locally.

**The private key never leaves the user's machine.** The server only ever sees
and stores the public key.

### `~/.sol/key.json`

```json
{
  "version": 1,
  "username": "jasenqin.1000",
  "public_key": "ed25519:8f3a2c7b4d...",
  "private_key": "ed25519:PRIVATE:1a2b3c4d...",
  "registry": "https://sol-registry.org",
  "registered_at": "2026-05-06T10:00:00Z"
}
```

This file should have permissions `600`. Sol warns loudly if it is readable by
other users. The private key is stored unencrypted by default; a future
`--passphrase` option can wrap it with symmetric encryption at rest.

---

## Signing — how it works

Sol uses **Ed25519** for signatures. Ed25519 is fast, produces compact 64-byte
signatures, has no parameters to misconfigure, and is widely supported.

### What is signed

The signed payload is:

```
payload = qualified_name + ":" + script_contents
```

This is the same string that is hashed for the content address, so the
signature covers both the name and the content atomically. Signing a different
name with the same content, or the same name with different content, produces
an invalid signature.

### Signature encoding

Signatures are encoded as lowercase hex and stored alongside the script in the
registry. The full module record on the server looks like:

```json
{
  "uri":       "jasenqin.1000.myscript#85c32e7...",
  "author":    "jasenqin.1000",
  "hash":      "85c32e7438f4f012091945fdfd6ee0dccbef884d1c5e5b3a59e312b1",
  "signature": "a1b2c3d4e5f6...",
  "uploaded_at": "2026-05-06T10:00:00Z"
}
```

The script source itself is stored separately and served on GET requests. The
signature is served alongside it in a metadata endpoint.

---

## Upload flow — `sol upload <script.sol>`

```
$ sol upload myscript.sol

Signing as jasenqin.1000...
Payload:   jasenqin.1000.myscript:<contents>
Hash:      85c32e7438f4f012091945fdfd6ee0dccbef884d1c5e5b3a59e312b1
Signature: a1b2c3d4e5...

Uploading to https://sol-registry.org...
Uploaded: jasenqin.1000.myscript#85c32e7438f4f012091945fdfd6ee0dccbef884d1c5e5b3a59e312b1
```

### Steps

1. Read `~/.sol/key.json` — fail clearly if not registered
2. Compute `payload = "jasenqin.1000.myscript" + ":" + file_contents`
3. Compute `hash = sha256(payload)` — this becomes the URI hash
4. Compute `signature = ed25519_sign(private_key, payload)`
5. POST to registry:
   ```
   POST /modules
   Authorization: Bearer <registry_auth_token>
   Body: {
     "qualified_name": "jasenqin.1000.myscript",
     "source":         "<script contents>",
     "hash":           "85c32e7...",
     "signature":      "a1b2c3..."
   }
   ```
6. Server verifies:
   - The auth token matches the uploading user
   - The `qualified_name` is in the user's namespace (prefix matches username)
   - `sha256(qualified_name + ":" + source) == hash`
   - `ed25519_verify(user_public_key, payload, signature) == true`
   - The hash does not already exist (immutability)
7. On success, server stores the module and returns the canonical URI
8. Client writes to `~/.sol/lib/jasenqin.1000.myscript#85c32e7....sol`
   and caches the signature in `~/.sol/lib/jasenqin.1000.myscript#85c32e7....sig`

### Namespace enforcement

A user can only upload scripts whose `qualified_name` starts with their own
username. `jasenqin.1000` can upload `jasenqin.1000.anything` but cannot
upload `jasenqin.1001.something` or `sol.std`. The server enforces this via
the auth token → username mapping.

---

## Download and verification flow — `use`

When `use "jasenqin.1000.myscript#85c32e7..."` triggers a download:

### Step 1 — Check local cache

Look for both:
- `~/.sol/lib/jasenqin.1000.myscript#85c32e7....sol`   (source)
- `~/.sol/lib/jasenqin.1000.myscript#85c32e7....sig`   (signature)

If both exist:
- Verify `sha256(qualified_name + ":" + source) == hash`
- Verify `ed25519_verify(cached_public_key, payload, signature)`
- If both pass → load, proceed
- If either fails → delete both files, warn, fall through to download

### Step 2 — Fetch from registry

```
GET /modules/jasenqin.1000.myscript/85c32e7...
→ {
    "source":     "<script contents>",
    "signature":  "a1b2c3...",
    "author":     "jasenqin.1000"
  }

GET /users/jasenqin.1000/pubkey
→ { "public_key": "ed25519:8f3a2c..." }
```

The public key is fetched once per author and cached in
`~/.sol/keys/<username>.pub`. Subsequent downloads by the same author reuse
the cached public key. The public key is itself verified by checking it matches
the hash stored in the registry's user record — the server is trusted for key
lookup, but the signature verification is done locally.

### Step 3 — Verify

```
payload  = "jasenqin.1000.myscript" + ":" + downloaded_source
computed = sha256(payload)
```

Check 1 — content address:
```
computed == "85c32e7..."
```

Check 2 — signature:
```
ed25519_verify(author_public_key, payload, downloaded_signature) == true
```

If either check fails, Sol refuses to load the module and prints a clear error:

```
[sol] error: signature verification failed for jasenqin.1000.myscript#85c32e7...
             This could indicate a compromised registry or a corrupted download.
             The script has NOT been executed.
```

If both pass, write source and signature to cache, load as `SModule`.

---

## Key caching layout

```
~/.sol/
  key.json                          # your own private + public key
  keys/
    jasenqin.1000.pub               # cached public keys for authors you've used
    sol.official.pub
    bob.2341.pub
  lib/
    jasenqin.1000.myscript#85c3....sol   # cached source
    jasenqin.1000.myscript#85c3....sig   # cached signature
```

Public keys are cached per-author, not per-module — once you've verified a
module from `jasenqin.1000`, subsequent modules from the same author reuse the
cached key without a network round-trip.

---

## Trust levels at a glance

When a Sol script is loaded, every `use` dependency falls into one of these
states, visible via `sol check`:

```
✓ verified      hash matches + signature valid + author key known
~ key-cached    hash matches + signature valid + key from local cache (not re-fetched)
? unverified    hash matches but no signature available (pre-signing era scripts)
✗ failed        hash mismatch or signature invalid — script NOT loaded
! missing       not in cache and not reachable from registry
```

`sol check` reports the trust level for every dependency without executing
anything, making it easy to audit a script's full dependency tree before
running it in a sensitive environment.

---

## Registry server API additions

```
POST /users/register
     Body: {name, email}
     → 201 {username, public_key_upload_url}

PUT  /users/<username>/pubkey
     Body: {public_key}
     Auth: Bearer <token>
     → 200

GET  /users/<username>/pubkey
     → 200 {public_key, registered_at}

POST /modules
     Body: {qualified_name, source, hash, signature}
     Auth: Bearer <token>
     → 201 {uri}
     → 400 hash mismatch
     → 400 signature invalid
     → 403 namespace violation
     → 409 already exists

GET  /modules/<qualified_name>/<hash>
     → 200 {source, signature, author, uploaded_at}
     → 404
```

---

## Implementation notes

### Key generation (`Sol/Registry.hs` — new file)

```haskell
import Crypto.Sign.Ed25519 (createKeypair, sign, verify, PublicKey, SecretKey)

generateKeypair :: IO (PublicKey, SecretKey)
generateKeypair = createKeypair

signPayload :: SecretKey -> String -> ByteString
signPayload sk payload = sign sk (encodeUtf8 payload)

verifyPayload :: PublicKey -> String -> ByteString -> Bool
verifyPayload pk payload sig = verify pk (encodeUtf8 payload) sig
```

The `ed25519` package (`cryptonite` or `ed25519` on Hackage) provides these
primitives. This is the only new dependency the registry feature requires.

### Key storage

Keys are stored as hex-encoded strings in JSON. On load they are decoded to
raw `ByteString` before use. The `key.json` file is created with `chmod 600`
immediately after writing.

### `sol register` CLI command

Implemented as a new subcommand in `Sol/CLI.hs` (or `Main.hs`). It is
interactive and writes `~/.sol/key.json` on completion. It does not modify
any script evaluation behaviour — registration is purely a CLI-level concern.

### Error messages

All trust failures print to stderr and cause a non-zero exit code. The script
is never partially executed — `use` resolution for all dependencies completes
(or fails) before `evalProg` is called on the top-level script. This means
you either get full trust verification upfront or the script does not run at
all.