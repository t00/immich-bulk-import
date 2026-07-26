// Injects an mTLS client certificate into Node's built-in fetch().
//
// The Immich CLI calls bare global fetch() with no agent/dispatcher hook, so
// there is no CLI flag for this. undici's setGlobalDispatcher writes to
// Symbol.for('undici.globalDispatcher.1') on globalThis, which is the same
// slot Node's internal fetch reads -- so the standalone package can steer the
// built-in. Loaded via NODE_OPTIONS="--import /opt/immich/mtls.mjs".
//
// NOTE: NODE_EXTRA_CA_CERTS cannot do this. It only adds trusted CAs for
// verifying the *server*; it never presents a client certificate.
//
// Driven by file presence: if /certs isn't mounted, this is a no-op and the
// image works normally against a non-mTLS server.
import fs from 'node:fs';

const {
  IMMICH_CLIENT_CERT: certPath,
  IMMICH_CLIENT_KEY: keyPath,
  IMMICH_CLIENT_PFX: pfxPath,
  IMMICH_CLIENT_PASSPHRASE: passphrase,
  IMMICH_CA_CERT: caPath,
} = process.env;

const read = (p) => {
  if (!p) return undefined;
  try {
    return fs.readFileSync(p);
  } catch {
    return undefined; // not mounted -- treated as "not configured"
  }
};

const cert = read(certPath);
const key = read(keyPath);
const pfx = read(pfxPath);
const ca = read(caPath);

if (cert || pfx || ca) {
  // Half-configured is always a mistake; fail loudly rather than at handshake.
  if (cert && !key) {
    console.error(`mTLS: found ${certPath} but could not read key ${keyPath}`);
    process.exit(1);
  }

  const { Agent, setGlobalDispatcher } = await import('undici');
  setGlobalDispatcher(
    new Agent({
      connect: {
        cert,
        key,
        pfx,
        passphrase,
        // Supplying ca REPLACES the default root store for these connections.
        ca,
      },
    }),
  );

  const what = [pfx ? 'pfx' : cert ? 'cert+key' : null, ca ? 'private CA' : null]
    .filter(Boolean)
    .join(', ');
  console.error(`mTLS enabled (${what})`);
}
