/*
 * Shared git wire protocol code (smart HTTP, protocol v2) for the POC scripts.
 *
 * Quick reminder of the moving parts:
 *   - pkt-line:  git's framing. 4 hex digits of length, then the payload.
 *   - commands:  POST <repo>/git-upload-pack with "command=ls-refs" or "command=fetch".
 *   - packfile:  what "fetch" returns. A list of compressed git objects
 *                (commits, trees = directory listings, blobs = file contents).
 */

import { inflateSync } from 'node:zlib';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { Agent as HttpsAgent, request as httpsRequest } from 'node:https';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { openSshSession, parseSshUrl } from './ssh_transport.mjs';

export const DEFAULT_REPO = 'https://github.com/elastic/detection-rules';

// Only these folders hold rules in elastic/detection-rules.
const RULE_DIRS = ['rules/', 'rules_building_block/'];

// Network counters. Scripts read these to print totals.
export const stats = { requests: 0, bytesDownloaded: 0 };

export const kb = (bytes) => `${(bytes / 1024).toFixed(1)} KB`;
export const mb = (bytes) => `${(bytes / 1024 / 1024).toFixed(1)} MB`;

// ---------------------------------------------------------------------------
// pkt-line framing
// ---------------------------------------------------------------------------
//   0000 = flush (end of message), 0001 = delim (section break), 0002 = response end

const FLUSH = Buffer.from('0000');
const DELIM = Buffer.from('0001');

const pktLine = (text) => {
  const payload = Buffer.from(text, 'utf8');
  const length = (payload.length + 4).toString(16).padStart(4, '0');
  return Buffer.concat([Buffer.from(length), payload]);
};

function* readPktLines(buffer) {
  let pos = 0;
  while (pos < buffer.length) {
    const length = parseInt(buffer.subarray(pos, pos + 4).toString(), 16);
    if (Number.isNaN(length)) throw new Error(`Bad pkt-line at byte ${pos}`);
    if (length === 0) { yield { kind: 'flush' }; pos += 4; continue; }
    if (length === 1) { yield { kind: 'delim' }; pos += 4; continue; }
    if (length === 2) { yield { kind: 'end' }; pos += 4; continue; }
    yield { kind: 'data', payload: buffer.subarray(pos + 4, pos + length) };
    pos += length;
  }
}

// ---------------------------------------------------------------------------
// HTTP transport
// ---------------------------------------------------------------------------

const GIT_HEADERS = {
  'Git-Protocol': 'version=2', // opt in to protocol v2
  'User-Agent': 'git/rule-delivery-poc',
};

/** Command line options every script accepts for HTTPS and SSH. Spread into parseArgs options. */
export const TRANSPORT_OPTIONS = {
  ca: { type: 'string' }, // HTTPS: PEM file to trust instead of Node's built-in CAs
  cert: { type: 'string' }, // HTTPS: PEM client certificate (mutual TLS)
  key: { type: 'string' }, // HTTPS: PEM private key for --cert
  'ssh-key': { type: 'string' }, // SSH: unencrypted ed25519 private key (default ~/.ssh/id_ed25519)
  'known-hosts': { type: 'string' }, // SSH: known_hosts file (default ~/.ssh/known_hosts)
  'accept-new-host': { type: 'boolean' }, // SSH: trust and record an unknown host key
  insecure: { type: 'boolean' }, // skip server certificate / host key verification
};

let httpsAgent = new HttpsAgent({ keepAlive: true });
let sshOptions = {
  keyFile: join(homedir(), '.ssh', 'id_ed25519'),
  knownHostsFile: join(homedir(), '.ssh', 'known_hosts'),
  acceptNewHost: false,
  insecure: false,
};
const sshSessions = new Map(); // repo url -> open session

/** Apply the transport options. Call once, before the first request. */
export const configureTransport = (options = {}) => {
  const { ca, cert, key, insecure } = options;
  httpsAgent = new HttpsAgent({
    keepAlive: true,
    ca: ca ? readFileSync(ca) : undefined,
    cert: cert ? readFileSync(cert) : undefined,
    key: key ? readFileSync(key) : undefined,
    rejectUnauthorized: !insecure,
  });
  sshOptions = {
    keyFile: options['ssh-key'] ?? sshOptions.keyFile,
    knownHostsFile: options['known-hosts'] ?? sshOptions.knownHostsFile,
    acceptNewHost: Boolean(options['accept-new-host']),
    insecure: Boolean(insecure),
  };
};

/** Close any open SSH sessions. HTTPS needs nothing. Call when the script is done. */
export const closeTransport = async () => {
  await Promise.all([...sshSessions.values()].map((session) => session.close()));
  sshSessions.clear();
};

const sshTargetOf = (repoUrl) => (/^https?:\/\//.test(repoUrl) ? null : parseSshUrl(repoUrl));

const getSshSession = async (repoUrl, target) => {
  const existing = sshSessions.get(repoUrl);
  if (existing) return existing;
  const session = await openSshSession({ target, ...sshOptions });
  stats.requests += 1;
  stats.bytesDownloaded += session.advertisement.length;
  sshSessions.set(repoUrl, session);
  return session;
};

const sendRequest = (url, { method = 'GET', headers, body } = {}) =>
  new Promise((resolve, reject) => {
    const isHttps = url.startsWith('https:');
    const send = isHttps ? httpsRequest : httpRequest;
    const request = send(url, { method, headers, agent: isHttps ? httpsAgent : undefined }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('error', reject);
      response.on('end', () =>
        resolve({ status: response.statusCode, statusText: response.statusMessage, body: Buffer.concat(chunks) })
      );
    });
    request.on('error', reject);
    request.end(body);
  });

const download = ({ status, statusText, body }) => {
  if (status < 200 || status >= 300) {
    throw new Error(`HTTP ${status} ${statusText}: ${body.toString()}`);
  }
  stats.requests += 1;
  stats.bytesDownloaded += body.length;
  return body;
};

/** Handshake: returns the server's capability lines. Throws unless it speaks v2 with "filter". */
export const getCapabilities = async (repoUrl) => {
  const sshTarget = sshTargetOf(repoUrl);
  const advertisement = sshTarget
    ? (await getSshSession(repoUrl, sshTarget)).advertisement
    : download(await sendRequest(`${repoUrl}/info/refs?service=git-upload-pack`, { headers: GIT_HEADERS }));
  const lines = [...readPktLines(advertisement)]
    .filter((line) => line.kind === 'data')
    .map((line) => line.payload.toString().trim());

  if (!lines.includes('version 2')) {
    const hint = sshTarget ? ' (over SSH the server must accept the GIT_PROTOCOL variable, e.g. sshd AcceptEnv)' : '';
    throw new Error(`Server does not speak protocol v2${hint}. Got: ${lines.join(' | ').slice(0, 200)}`);
  }
  const capabilities = lines.filter((line) => !line.startsWith('#') && line !== 'version 2');
  if (!capabilities.some((c) => c.startsWith('fetch=') && c.includes('filter'))) {
    throw new Error('Server does not support "filter", so we cannot skip file contents');
  }
  return capabilities;
};

/** Send one v2 command: "command=<name>", delim, one arg per line, flush. */
const runCommand = async (repoUrl, command, args) => {
  const body = Buffer.concat([
    pktLine(`command=${command}\n`),
    DELIM,
    ...args.map((arg) => pktLine(`${arg}\n`)),
    FLUSH,
  ]);

  const sshTarget = sshTargetOf(repoUrl);
  if (sshTarget) {
    const response = await (await getSshSession(repoUrl, sshTarget)).exchange(body);
    stats.requests += 1;
    stats.bytesDownloaded += response.length;
    return response;
  }
  const response = await sendRequest(`${repoUrl}/git-upload-pack`, {
    method: 'POST',
    headers: {
      ...GIT_HEADERS,
      'Content-Type': 'application/x-git-upload-pack-request',
      Accept: 'application/x-git-upload-pack-result',
    },
    body,
  });
  return download(response);
};

// ---------------------------------------------------------------------------
// Resolving a branch name to a commit SHA
// ---------------------------------------------------------------------------

export const resolveCommit = async (repoUrl, refOrSha) => {
  if (/^[0-9a-f]{40}$/.test(refOrSha)) return refOrSha;
  if (/^[0-9a-f]{4,39}$/.test(refOrSha)) {
    throw new Error(`"${refOrSha}" looks like a short SHA. Pass the full 40-char SHA.`);
  }
  const refName = `refs/heads/${refOrSha}`;
  const response = await runCommand(repoUrl, 'ls-refs', [`ref-prefix ${refName}`]);
  for (const line of readPktLines(response)) {
    if (line.kind !== 'data') continue;
    const [sha, name] = line.payload.toString().trim().split(' ');
    if (name === refName) return sha;
  }
  throw new Error(`Branch "${refOrSha}" not found`);
};

// ---------------------------------------------------------------------------
// Fetching a packfile
// ---------------------------------------------------------------------------
// The reply has sections ("shallow-info", "packfile", ...). Inside "packfile"
// each pkt-line starts with a sideband byte: 1 = pack data, 2 = progress, 3 = error.

export const fetchPack = async (repoUrl, args) => {
  const response = await runCommand(repoUrl, 'fetch', [...args, 'no-progress', 'done']);

  const chunks = [];
  let inPackSection = false;
  for (const line of readPktLines(response)) {
    if (line.kind !== 'data') continue;
    if (!inPackSection) {
      inPackSection = line.payload.toString() === 'packfile\n';
      continue;
    }
    const band = line.payload[0];
    const data = line.payload.subarray(1);
    if (band === 1) chunks.push(data);
    if (band === 3) throw new Error(`Server error: ${data.toString()}`);
  }
  if (!inPackSection) throw new Error('Server reply had no packfile section');
  return Buffer.concat(chunks);
};

// ---------------------------------------------------------------------------
// Packfile parsing
// ---------------------------------------------------------------------------
// "PACK" | version | object count | objects... | SHA-1 trailer
// Each object: type+size header, [delta base], zlib data. A delta object is
// rebuilt from a base object using copy/insert instructions.

const OBJECT_TYPES = { 1: 'commit', 2: 'tree', 3: 'blob', 4: 'tag' };
const OFS_DELTA = 6; // base is earlier in this pack, found by offset
const REF_DELTA = 7; // base found by object id

/** Object id = SHA-1 of "<type> <size>\0<content>". Also proves we decoded it right. */
const hashObject = (type, data) =>
  createHash('sha1').update(`${type} ${data.length}\0`).update(data).digest('hex');

const applyDelta = (base, delta) => {
  let pos = 0;
  const readVarint = () => {
    let value = 0;
    let shift = 0;
    let byte;
    do {
      byte = delta[pos++];
      value += (byte & 0x7f) * 2 ** shift;
      shift += 7;
    } while (byte & 0x80);
    return value;
  };

  readVarint(); // base size, not needed
  const result = Buffer.alloc(readVarint());
  let out = 0;

  while (pos < delta.length) {
    const op = delta[pos++];
    if (op & 0x80) {
      // COPY from base. Bits 0-3 say which offset bytes follow, bits 4-6 which length bytes.
      let offset = 0;
      let length = 0;
      for (let i = 0; i < 4; i++) if (op & (1 << i)) offset += delta[pos++] * 2 ** (8 * i);
      for (let i = 0; i < 3; i++) if (op & (1 << (4 + i))) length += delta[pos++] * 2 ** (8 * i);
      if (length === 0) length = 0x10000;
      base.copy(result, out, offset, offset + length);
      out += length;
    } else if (op > 0) {
      // INSERT the next `op` bytes from the delta itself.
      delta.copy(result, out, pos, pos + op);
      out += op;
      pos += op;
    } else {
      throw new Error('Invalid delta instruction 0');
    }
  }
  return result;
};

/**
 * Read the header of the object starting at `start`: its type, its unpacked
 * size, where its delta base is (for delta objects), and where its compressed
 * data begins.
 */
const readObjectHeader = (pack, start) => {
  let pos = start;

  // First byte: 3 bits of type, 4 bits of size. While the high bit is set,
  // the next byte adds 7 more bits of size.
  let byte = pack[pos++];
  const typeCode = (byte >> 4) & 0x7;
  let size = byte & 0x0f;
  let shift = 4;
  while (byte & 0x80) {
    byte = pack[pos++];
    size += (byte & 0x7f) * 2 ** shift;
    shift += 7;
  }

  let baseOffset;
  let baseId;
  if (typeCode === OFS_DELTA) {
    // Distance back to the base, in git's own varint flavour (each
    // continuation adds 1 before shifting, so each number has one encoding).
    byte = pack[pos++];
    let distance = byte & 0x7f;
    while (byte & 0x80) {
      byte = pack[pos++];
      distance = (distance + 1) * 128 + (byte & 0x7f);
    }
    baseOffset = start - distance;
  } else if (typeCode === REF_DELTA) {
    baseId = pack.subarray(pos, pos + 20).toString('hex');
    pos += 20;
  }
  return { typeCode, size, baseOffset, baseId, dataStart: pos };
};

/** Unpack one object's zlib data. Also returns how many compressed bytes it used. */
const inflateObject = (pack, { dataStart, size }) => {
  // The pack doesn't store compressed lengths, so let zlib find the end of
  // its own stream. Passing the real size as chunkSize makes zlib allocate
  // exactly that; by default every small object would hold on to a 16 KB
  // buffer, which adds up fast in packs with thousands of objects.
  const { buffer, engine } = inflateSync(pack.subarray(dataStart), {
    info: true,
    chunkSize: Math.max(64, size), // 64 is zlib's minimum
  });
  if (buffer.length !== size) throw new Error(`Object at byte ${dataStart}: size mismatch`);
  return { inflated: buffer, compressedLength: engine.bytesWritten };
};

/** Turn unpacked data into { type, data }, applying the delta if it is one. */
const resolveObject = ({ typeCode }, inflated, base) => {
  if (typeCode !== OFS_DELTA && typeCode !== REF_DELTA) {
    return { type: OBJECT_TYPES[typeCode], data: inflated };
  }
  if (!base) throw new Error('Delta base not in pack');
  return { type: base.type, data: applyDelta(base.data, inflated) }; // same type as its base
};

const checkPackHeader = (pack) => {
  if (pack.subarray(0, 4).toString() !== 'PACK') throw new Error('Not a packfile');
  return pack.readUInt32BE(8); // object count
};

/**
 * Decode a whole packfile into a Map of { object id -> { type, data } }.
 * Everything is unpacked and kept. Fine for small packs (one listing, one
 * batch of files); see openPack for big ones.
 */
export const parsePack = (pack) => {
  const count = checkPackHeader(pack);
  const byId = new Map();
  const byOffset = new Map(); // needed to resolve OFS_DELTA bases
  let pos = 12;

  for (let i = 0; i < count; i++) {
    const header = readObjectHeader(pack, pos);
    const { inflated, compressedLength } = inflateObject(pack, header);
    const base = header.baseId ? byId.get(header.baseId) : byOffset.get(header.baseOffset);
    const { type, data } = resolveObject(header, inflated, base);

    const object = { id: hashObject(type, data), type, data };
    byId.set(object.id, object);
    byOffset.set(pos, object);
    pos = header.dataStart + compressedLength;
  }
  return byId;
};

/**
 * Like parsePack, but keeps the pack compressed and unpacks objects on demand,
 * with a small cache. Use it for big packs, e.g. lots of history.
 * Returns { size, has(id), get(id) -> { type, data } | undefined }.
 */
export const openPack = (pack, { cacheSize = 256 } = {}) => {
  const count = checkPackHeader(pack);
  const headers = new Map(); // offset -> header
  const offsetById = new Map(); // id -> offset
  const cache = new Map(); // offset -> { type, data }; Map keeps insertion order, oldest first

  const remember = (offset, object) => {
    cache.delete(offset);
    cache.set(offset, object); // move to the "most recent" end
    if (cache.size > cacheSize) cache.delete(cache.keys().next().value);
  };

  const baseOffsetOf = (header) => (header.baseId ? offsetById.get(header.baseId) : header.baseOffset);

  // Unpack the object at `offset`, unpacking its delta base first if needed.
  const load = (offset) => {
    const cached = cache.get(offset);
    if (cached) {
      remember(offset, cached);
      return cached;
    }
    const header = headers.get(offset);
    const { inflated } = inflateObject(pack, header);
    const baseOffset = baseOffsetOf(header);
    const base = baseOffset === undefined ? undefined : load(baseOffset);
    const object = resolveObject(header, inflated, base);
    remember(offset, object);
    return object;
  };

  // First pass: find where every object starts and learn its id. Each object
  // must be unpacked to hash it, but the result isn't kept to save memory.
  let pos = 12;
  for (let i = 0; i < count; i++) {
    const header = readObjectHeader(pack, pos);
    headers.set(pos, header);
    const { inflated, compressedLength } = inflateObject(pack, header);
    const baseOffset = baseOffsetOf(header);
    const base = baseOffset === undefined ? undefined : load(baseOffset);
    const object = resolveObject(header, inflated, base);

    offsetById.set(hashObject(object.type, object.data), pos);
    remember(pos, object);
    pos = header.dataStart + compressedLength;
  }

  return {
    size: count,
    has: (id) => offsetById.has(id),
    get: (id) => {
      const offset = offsetById.get(id);
      return offset === undefined ? undefined : load(offset);
    },
  };
};

// ---------------------------------------------------------------------------
// Listing rule files at a commit (paths and blob ids, no file contents)
// ---------------------------------------------------------------------------

/** Tree entries are "<mode> <name>\0<20-byte id>". Mode "40000" = sub-directory. */
export const parseTree = (data) => {
  const entries = [];
  let pos = 0;
  while (pos < data.length) {
    const space = data.indexOf(0x20, pos);
    const nul = data.indexOf(0x00, space);
    entries.push({
      mode: data.subarray(pos, space).toString(),
      name: data.subarray(space + 1, nul).toString(),
      id: data.subarray(nul + 1, nul + 21).toString('hex'),
    });
    pos = nul + 21;
  }
  return entries;
};

export const isRuleFile = (path) => path.endsWith('.toml') && RULE_DIRS.some((dir) => path.startsWith(dir));

/** Map of { path -> blob id } for every rule file at `commitSha`. One request. */
export const listRuleFiles = async (repoUrl, commitSha) => {
  const pack = await fetchPack(repoUrl, [
    `want ${commitSha}`,
    'deepen 1', // just this commit, no history
    'filter blob:none', // directory listings only, no file contents
  ]);
  const objects = parsePack(pack);

  const commit = objects.get(commitSha);
  if (!commit) throw new Error(`Commit ${commitSha} missing from server reply`);
  const rootTreeId = commit.data.toString().match(/^tree ([0-9a-f]{40})/)[1];

  const files = new Map();
  const walk = (treeId, prefix) => {
    for (const { mode, name, id } of parseTree(objects.get(treeId).data)) {
      const path = prefix + name;
      if (mode === '40000') walk(id, `${path}/`);
      else if (isRuleFile(path)) files.set(path, id);
    }
  };
  walk(rootTreeId, '');

  console.log(`  ${commitSha.slice(0, 12)}: ${files.size} rule files, pack ${kb(pack.length)}`);
  return files;
};

// ---------------------------------------------------------------------------
// Rule helpers
// ---------------------------------------------------------------------------

/**
 * Find `rule_id = "..."` in a rule file's raw bytes. POC shortcut; use a TOML
 * parser for real.
 *
 * Works on the Buffer on purpose. Converting the whole file to a string and
 * running a regex returns a V8 "sliced string": a tiny string that secretly
 * keeps the entire file text alive. Keep that rule_id around (e.g. in a Map)
 * and you keep every file in memory. Here only the one short line is decoded.
 */
export const readRuleId = (data) => {
  let pos = data.indexOf('rule_id');
  while (pos !== -1) {
    const atLineStart = pos === 0 || data[pos - 1] === 0x0a; // 0x0a = "\n"
    if (atLineStart) {
      const lineEnd = data.indexOf(0x0a, pos);
      const line = data.toString('utf8', pos, lineEnd === -1 ? data.length : lineEnd);
      const ruleId = line.match(/^rule_id\s*=\s*"([^"]+)"/)?.[1];
      if (ruleId) return ruleId;
    }
    pos = data.indexOf('rule_id', pos + 1);
  }
  return undefined;
};
