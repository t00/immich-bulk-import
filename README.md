# Immich bulk import

Bulk-import a directory tree of photos into [Immich](https://immich.app), using
subdirectory names as album names. Wraps the official Immich CLI in a pinned
Docker image, and adds mTLS client-certificate support, which the CLI has no
flag for.

- One `docker run` per invocation — the album loop happens inside the container.
- No credentials in the image. The API key and client cert are supplied at runtime.
- Runs on hosts without bash (Alpine, minimal NAS/LXC). Everything host-side is POSIX `sh`.
- Read-only mounts, so a stray `--delete` can never touch your originals.

## Requirements

- Docker
- An Immich API key (Immich web UI → user settings → API Keys)
- `/bin/sh`. Bash is *not* required.

## Layout

Keep all of these in one directory:

| File | Runs where | Purpose |
| --- | --- | --- |
| `.env` | host | all configuration (copy from `.env.example`) |
| `build.sh` | host | one `docker build` |
| `run.sh` | host | one `docker run` |
| `Dockerfile` | — | pins the CLI version |
| `import-immich.sh` | **image** | the album loop and all modes |
| `mtls.mjs` | **image** | injects the client cert into Node's `fetch` |
| `verify.mjs` | **image** | turns `--json-output` into a missing-file report |
| `certs/` | host | your client certificate (never enters the image) |

The three files marked **image** are baked in at build time. Changing any of
them requires `./build.sh`. Changing `.env` does not — it is read at runtime.

## Setup

```sh
cp .env.example .env
chmod 600 .env
$EDITOR .env
./build.sh
./run.sh --check          # should print your server version
```

`--check` verifies the URL, API key, and (if configured) the mTLS handshake.
Get that passing before importing anything.

## Usage

The **last argument is always the photo directory**. Relative paths and `~`
both work and resolve against your current directory.

```sh
./run.sh --check                     # test connectivity, no directory needed
./run.sh --verify /srv/photos        # which files are NOT on the server yet
./run.sh /srv/photos                 # DRY RUN of the import
./run.sh --go /srv/photos            # actually import
./run.sh --flat --go /srv/photos     # alternative album naming, see below
./run.sh --go -- --ignore '**/Raw/**' /srv/photos
```

Anything after `--` is passed straight to `immich upload`.

Dry run is the default; `--go` commits. The dry run prints the album names it
derived from your folder structure, which is the last chance to catch a wrong
directory before anything uploads.

### Album naming

Given:

```
/srv/photos/
├── Italy2019/
│   ├── a.jpg
│   └── day3/b.jpg
└── Wedding/c.jpg
```

| Mode | `a.jpg` | `b.jpg` | `c.jpg` |
| --- | --- | --- | --- |
| default (`--top`) | Italy2019 | **Italy2019** | Wedding |
| `--flat` | Italy2019 | **day3** | Wedding |

`--flat` uses each file's immediate parent directory, which is the Immich CLI's
own `--album` behaviour. Default mode runs one pass per top-level folder with an
explicit album name so nested files still land in the top-level album.

Loose files sitting directly in the photo directory get no album in default
mode. They are reported as skipped rather than silently dropped — use `--flat`
if you want them.

If one album fails, the run logs it and continues, then reports a count and
exits non-zero. One unreadable folder does not abandon a large import.

### Verifying

```sh
./run.sh --verify /srv/photos
```

```
checked 5 local file(s)
  on server : 3
  MISSING   : 2

  2006-12-24 Boze Narodzenie u Wujka/S6000207.JPG
  Wedding/IMG_0042.JPG
```

Exit status is 0 when everything is present, 1 when something is missing, so
`./run.sh --verify /srv/photos && echo clean` works in a script.

This is a **checksum** comparison, not a filename match — the CLI hashes every
local file and queries the server's bulk-upload-check API. A renamed or moved
file still counts as present; a locally edited one correctly shows as missing.
The pass is read-only: it omits `--album`/`--album-name`, without which the
CLI's album-update step returns immediately.

Two limits: it confirms the *asset* exists, not that it is in the right album;
and it must never be combined with `--skip-hash`, which short-circuits the check
and reports every file as new.

## Configuration

| Variable | Required | Notes |
| --- | --- | --- |
| `IMMICH_INSTANCE_URL` | yes | should end in `/api` |
| `IMMICH_API_KEY` | yes | from the Immich web UI |
| `IMMICH_CLI_VERSION` | yes | **must match your server version** — see below |
| `IMMICH_UPLOAD_CONCURRENCY` | no | defaults to 6; the CLI's own default is 1 |
| `IMMICH_CERT_DIR` | no | host directory, mounted read-only at `/certs` |
| `IMMICH_CLIENT_PFX` | no | PKCS#12 filename *inside* `/certs` |
| `IMMICH_CLIENT_PASSPHRASE` | no | for an encrypted key or `.pfx` |
| `IMMICH_CA_CERT` | no | only for a private CA; replaces the default root store |
| `IMMICH_IMAGE` | no | image tag, defaults to `immich-cli` |
| `IMMICH_ENV_FILE` | no | override the `.env` location |

`run.sh` and `build.sh` look for `.env` in this order:

```
$IMMICH_ENV_FILE  >  <directory containing the scripts>/.env  >  ~/.config/immich/.env
```

The current directory is deliberately *not* searched: unrelated projects
commonly have a `.env`, and this file gets sourced.

### `.env` format rules

`.env` is both sourced by `sh` and passed to `docker --env-file`, so it must
satisfy both parsers:

- `KEY=value` only — no `export`, no command substitution
- **No inline comments.** `docker --env-file` takes the rest of the line as the
  value, so `URL=https://x/api  # note` sends the comment as part of the URL.
- **No quotes** on anything read inside the container (`IMMICH_API_KEY`,
  `IMMICH_INSTANCE_URL`, `IMMICH_CLIENT_PASSPHRASE`) — docker does not strip them.
- `IMMICH_CERT_DIR` is host-side only, so quote it if the path contains spaces.
  Unquoted, `sh` would try to run the second word as a command.

### Version pinning

**`IMMICH_CLI_VERSION` must match your Immich server version.** The CLI ships
from the same repository and release tag as the server, so npm's `latest` is
frequently ahead of your server.

Check your server version with `./run.sh --check` or the web UI's About page.
If npm has no CLI release for your exact patch version, use the highest one
below it:

```sh
curl -s https://registry.npmjs.org/@immich/cli | jq -r '.versions|keys[]'
```

When you upgrade the Immich server, bump this and rebuild. The two move
together.

## mTLS

If your Immich sits behind a reverse proxy requiring client certificates, put
them in a directory and point `IMMICH_CERT_DIR` at it.

**PEM** — files must be named `client.crt` and `client.key` (plus optional
`ca.crt` for a private CA):

```
IMMICH_CERT_DIR=./certs
```

**PKCS#12** — give the bare filename; it resolves inside `/certs`:

```
IMMICH_CERT_DIR=./certs
IMMICH_CLIENT_PFX=client.p12
IMMICH_CLIENT_PASSPHRASE=secret
```

Never give a host path for `IMMICH_CLIENT_PFX` or `IMMICH_CLIENT_CERT` — those
are read inside the container, where only `/certs` exists.

The certificate is validated before any upload starts: the cert/key pair is
checked for a match, and an expired certificate is rejected outright rather than
surfacing later as an opaque TLS error. A certificate expiring within 7 days
produces a warning.

### How it works

The Immich CLI calls bare global `fetch()` with no agent or dispatcher hook, so
there is no CLI flag for client certificates. `mtls.mjs` is preloaded via
`NODE_OPTIONS="--import"` and sets undici's global dispatcher, which is the same
slot Node's built-in `fetch` reads from.

`NODE_EXTRA_CA_CERTS` **cannot** do this. It only adds trusted CAs for verifying
the *server*; it never presents a client certificate.

If `/certs` is not mounted, `mtls.mjs` is a silent no-op, so the same image works
against a plain non-mTLS server.

## Troubleshooting

**`env: can't execute 'bash': No such file or directory`**
Your host has no bash. All scripts here are `#!/bin/sh`; if you see this, you
have an older copy of `run.sh` or `build.sh`.

**`400 No required SSL certificate was sent` (nginx)**
No client certificate reached the server. Usually `IMMICH_CLIENT_PFX` or
`IMMICH_CLIENT_CERT` points at a host path instead of a filename inside
`/certs`. Current versions catch this and report which files *are* present:

```
mTLS: /certs is mounted but no client certificate was loaded.
      files present: client.p12, ca.crt
```

**`deviceAssetId must be a string` / `deviceId should not be empty` (HTTP 400)**
CLI newer than the server. CLI 3.x dropped those fields from the upload form;
2.x servers still require them. Set `IMMICH_CLI_VERSION` to your server version
and rebuild.

**`mac verify failure`**
Wrong `IMMICH_CLIENT_PASSPHRASE`. It is PKCS#12's integrity check failing,
despite mentioning nothing about passwords.

**`self-signed certificate in certificate chain`**
Your server's certificate is signed by a private CA. Put it in the cert
directory and set `IMMICH_CA_CERT=ca.crt`.

**Everything reported as new, nothing uploaded**
Check you have not enabled `--skip-hash`.

## Notes

- **Imports are resumable.** Files are hashed before upload and Immich dedupes
  server-side, so rerunning an identical command after a failure skips whatever
  already arrived.
- **Concurrency** defaults to 6 here because the CLI's own default is 1, which
  is very slow for bulk imports. Lower it if your server struggles.
- **Watch server RAM on a first large import.** Thumbnail generation and machine
  learning jobs queue behind the upload and keep working long after the CLI exits.
- `-it` is only passed when a terminal is present, so this works under cron and CI.
