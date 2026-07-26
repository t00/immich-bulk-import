// Reads `immich upload --dry-run --json-output` and reports which local files
// are not yet on the server.
//
// The CLI hashes every file and asks the server via /assets/bulk-upload-check,
// so this is a real checksum comparison, not a filename match:
//   newFiles   -> server does NOT have it  (missing)
//   duplicates -> server already has it    (uploaded)
const MOUNT = '/import';

let buf = '';
for await (const chunk of process.stdin) buf += chunk;

// Progress lines precede the JSON, which is pretty-printed so its opening
// brace sits alone on a line. Anchoring on that is sturdier than dropping a
// fixed number of leading lines.
const start = buf.search(/^\{$/m);
if (start < 0) {
  console.error('verify: no JSON found in CLI output. Raw output follows:\n');
  console.error(buf.trim());
  process.exit(2);
}

let data;
try {
  data = JSON.parse(buf.slice(start));
} catch (e) {
  console.error(`verify: could not parse CLI output: ${e.message}`);
  process.exit(2);
}

const missing = data.newFiles ?? [];
const present = data.duplicates ?? [];
const total = missing.length + present.length;
const rel = (p) => (p.startsWith(MOUNT + '/') ? p.slice(MOUNT.length + 1) : p);

console.log(`checked ${total} local file(s)`);
console.log(`  on server : ${present.length}`);
console.log(`  MISSING   : ${missing.length}`);

if (missing.length) {
  console.log('');
  for (const f of missing.sort()) console.log(`  ${rel(f)}`);
  console.log('');
  console.log('Re-run the import to upload these.');
}

// Note: this confirms the ASSET exists, not that it is in the right album.
process.exit(missing.length ? 1 : 0);
