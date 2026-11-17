#!/usr/bin/env node
/*
 * POC: simulates the update of a rule library. Finds the latest release tag in a
 * detection-rules-library repo, downloads every rule at that tag over git's
 * wire protocol (no git binary, no clone), and writes them to an Elasticsearch
 * index in batches, shaped like `security-rule` saved objects.
 *
 * Usage:
 *   node git_update_rule_library.mjs [--repo <url>] [--branch main] [--prerelease]
 *     [--batch 100] [--index security-rule-library] [--clean none|all] [--force]
 *     [--ca <pem>] [--cert <pem>] [--key <pem>] [--ssh-key <file>] [--known-hosts <file>]
 *     [--accept-new-host] [--insecure]
 *
 * Elasticsearch: ES_URL (default http://localhost:${ES_DEV_PORT:-9200}), ES_AUTH (default elastic:changeme).
 *
 * Steps:
 *   1. Latest release: list refs/tags/<branch>/v* and pick the highest version
 *      (betas only with --prerelease).
 *   2. Stop if the index's _meta already records that commit, unless --force.
 *   3. List the rule files at that commit (directory listings only). Rule files
 *      are .json files in a folder under rules/; the package files at the root
 *      of rules/ are skipped.
 *   4. For each batch: fetch the blobs in one request, parse each file, and
 *      index the { id, type, attributes } documents with one _bulk request.
 *      _id is security-rule:<rule_id>_<version>, as for the saved object.
 *   5. Record the tag and commit in the index's _meta and check the counts.
 *
 * Requires Node 22+.
 */

import { parseArgs } from 'node:util';
import {
  TRANSPORT_OPTIONS,
  closeTransport,
  configureTransport,
  fetchPack,
  getCapabilities,
  kb,
  listRefs,
  listRuleFiles,
  mb,
  parsePack,
  stats,
} from './git_protocol.mjs';

const DEFAULT_REPO = 'https://github.com/sdesalas/detection-rules-library';
const ES_URL = process.env.ES_URL ?? `http://localhost:${process.env.ES_DEV_PORT ?? 9200}`;
const ES_AUTH = process.env.ES_AUTH ?? 'elastic:changeme';
const HEAP_TARGET = 25 * 1024 * 1024;

// Same as the security-rule saved object mappings (prebuilt_rule_assets_type.ts), under `attributes`.
const keyword = { type: 'keyword', ignore_above: 1024 };
const ATTRIBUTE_MAPPINGS = {
  rule_id: { type: 'keyword' },
  version: { type: 'long' },
  name: { type: 'text', fields: { keyword: { type: 'keyword', normalizer: 'lowercase' } } },
  tags: { type: 'keyword' },
  severity: { type: 'keyword' },
  risk_score: { type: 'float' },
  deprecated: { type: 'boolean' },
  description: { type: 'text' },
  type: keyword,
  index: keyword,
  threat: {
    properties: {
      framework: keyword,
      tactic: { properties: { id: keyword, name: keyword } },
      technique: {
        properties: {
          id: keyword,
          name: keyword,
          subtechnique: { properties: { id: keyword, name: keyword } },
        },
      },
    },
  },
  related_integrations: { properties: { package: keyword, integration: keyword, version: keyword } },
};

const INDEX_MAPPINGS = {
  dynamic: false,
  properties: {
    id: { type: 'keyword' },
    type: { type: 'keyword' },
    attributes: { properties: ATTRIBUTE_MAPPINGS },
  },
};

// ---------------------------------------------------------------------------
// Memory tracking (sampled every 10ms, plus explicit readings after each batch)
// ---------------------------------------------------------------------------

const peak = { heapUsed: 0, arrayBuffers: 0, rss: 0 };

const readMemory = () => {
  const reading = process.memoryUsage();
  for (const key of Object.keys(peak)) peak[key] = Math.max(peak[key], reading[key]);
  return reading;
};

const formatMemory = ({ heapUsed, arrayBuffers, rss }) =>
  `heap ${mb(heapUsed).padStart(8)}  buffers ${mb(arrayBuffers).padStart(8)}  rss ${mb(rss).padStart(9)}`;

const sampler = setInterval(readMemory, 10);
sampler.unref();

// ---------------------------------------------------------------------------
// Elasticsearch
// ---------------------------------------------------------------------------

const esStats = { requests: 0, bytesSent: 0, ms: 0 };

const es = async (method, path, body, { allow404 = false } = {}) => {
  const payload = body === undefined ? undefined : typeof body === 'string' ? body : JSON.stringify(body);
  const startedAt = performance.now();
  const response = await fetch(`${ES_URL}${path}`, {
    method,
    headers: {
      Authorization: `Basic ${Buffer.from(ES_AUTH).toString('base64')}`,
      'Content-Type': path.includes('_bulk') ? 'application/x-ndjson' : 'application/json',
    },
    body: payload,
  });
  const text = await response.text();
  esStats.requests += 1;
  esStats.bytesSent += payload ? Buffer.byteLength(payload) : 0;
  esStats.ms += performance.now() - startedAt;
  if (allow404 && response.status === 404) return null;
  if (!response.ok) throw new Error(`Elasticsearch ${method} ${path}: HTTP ${response.status} ${text.slice(0, 500)}`);
  return text ? JSON.parse(text) : {};
};

/** Creates the index if missing. Returns the library _meta it holds, if any. */
const ensureIndex = async (index) => {
  const mapping = await es('GET', `/${index}/_mapping`, undefined, { allow404: true });
  if (mapping) return mapping[index]?.mappings?._meta?.library;
  await es('PUT', `/${index}`, { mappings: INDEX_MAPPINGS });
  console.log(`Created index ${index}`);
  return undefined;
};

const indexBatch = async (index, docs) => {
  const lines = [];
  for (const doc of docs) {
    lines.push(JSON.stringify({ index: { _index: index, _id: `security-rule:${doc.id}` } }));
    lines.push(JSON.stringify(doc));
  }
  const result = await es('POST', '/_bulk', `${lines.join('\n')}\n`);
  if (!result.errors) return 0;
  const failed = result.items.filter((item) => item.index?.error);
  for (const item of failed.slice(0, 5)) {
    console.warn(`  ! ${item.index._id}: ${item.index.error.type} ${item.index.error.reason}`);
  }
  return failed.length;
};

// ---------------------------------------------------------------------------
// Versions
// ---------------------------------------------------------------------------

const parseVersion = (text) => {
  const match = text.match(/^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/);
  if (!match) return null;
  return { text, parts: match.slice(1, 4).map(Number), prerelease: match[4]?.split('.') ?? [] };
};

const compareIdentifiers = (a, b) => {
  const bothNumbers = /^\d+$/.test(a) && /^\d+$/.test(b);
  if (bothNumbers) return Number(a) - Number(b);
  return a < b ? -1 : a > b ? 1 : 0;
};

/** Semver order: 9.6.1-beta.1 < 9.6.1 < 9.6.2-beta.0. */
const compareVersions = (a, b) => {
  for (let i = 0; i < 3; i++) if (a.parts[i] !== b.parts[i]) return a.parts[i] - b.parts[i];
  if (!a.prerelease.length || !b.prerelease.length) return b.prerelease.length - a.prerelease.length;
  for (let i = 0; i < Math.max(a.prerelease.length, b.prerelease.length); i++) {
    if (a.prerelease[i] === undefined) return -1;
    if (b.prerelease[i] === undefined) return 1;
    const order = compareIdentifiers(a.prerelease[i], b.prerelease[i]);
    if (order) return order;
  }
  return 0;
};

const findLatestTag = async (repoUrl, branch, allowPrerelease) => {
  const prefix = `refs/tags/${branch}/v`;
  const tags = (await listRefs(repoUrl, [prefix]))
    .map(({ name, sha }) => ({ name: name.slice('refs/tags/'.length), sha, version: parseVersion(name.slice(prefix.length)) }))
    .filter(({ version }) => version && (allowPrerelease || !version.prerelease.length))
    .sort((a, b) => compareVersions(b.version, a.version));
  if (!tags.length) throw new Error(`No release tags under ${prefix}`);
  return { ...tags[0], tagCount: tags.length };
};

// ---------------------------------------------------------------------------
// Rule files
// ---------------------------------------------------------------------------

// A file in a folder under rules/; the package files sit at the root of rules/.
const isLibraryFile = (path) => path.startsWith('rules/') && path.indexOf('/', 'rules/'.length) !== -1;

const parseRule = (path, data) => {
  const doc = JSON.parse(data.toString('utf8'));
  const { id, type, attributes } = doc;
  const ruleId = attributes?.rule_id;
  const version = attributes?.version;
  if (type !== 'security-rule' || !ruleId || !Number.isInteger(version)) {
    throw new Error(`${path}: not a security-rule document with rule_id and version`);
  }
  if (id !== `${ruleId}_${version}`) throw new Error(`${path}: id ${id} does not match ${ruleId}_${version}`);
  return { id, type, attributes };
};

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

const seconds = (ms) => `${(ms / 1000).toFixed(2)}s`;
const millis = (ms) => `${Math.round(ms)}ms`.padStart(6);

const main = async () => {
  const { values } = parseArgs({
    options: {
      repo: { type: 'string', default: DEFAULT_REPO },
      branch: { type: 'string', default: 'main' },
      prerelease: { type: 'boolean', default: false },
      batch: { type: 'string', default: '100' },
      index: { type: 'string', default: 'security-rule-library' },
      clean: { type: 'string', default: 'none' },
      force: { type: 'boolean', default: false },
      ...TRANSPORT_OPTIONS,
    },
  });
  const batchSize = Number(values.batch);
  if (!Number.isInteger(batchSize) || batchSize < 1) throw new Error('--batch must be a positive integer');
  if (!['none', 'all'].includes(values.clean)) throw new Error('--clean must be none or all');
  configureTransport(values);
  const repoUrl = values.repo.replace(/\/$/, '');
  const { index } = values;
  const timings = {};
  const startedAt = performance.now();
  console.log(`Start: ${formatMemory(readMemory())}`);
  console.log(`Repo: ${repoUrl}\nElasticsearch: ${ES_URL}, index ${index}`);

  // 1. Latest release
  await getCapabilities(repoUrl);
  const latest = await findLatestTag(repoUrl, values.branch, values.prerelease);
  timings.resolve = performance.now() - startedAt;
  console.log(`Latest: ${latest.name} (${latest.sha}), highest of ${latest.tagCount} tags`);

  // 2. Already up to date?
  const installed = await ensureIndex(index);
  console.log(`Index holds: ${installed ? `${installed.tag} (${installed.commit})` : 'nothing recorded'}`);
  if (installed?.commit === latest.sha && !values.force) {
    timings.total = performance.now() - startedAt;
    console.log(`
Already up to date. Nothing downloaded.
  Git requests:      ${stats.requests}, ${kb(stats.bytesDownloaded)} downloaded
  ES requests:       ${esStats.requests}
  Time:              ${seconds(timings.total)} (resolve ${seconds(timings.resolve)})`);
    return;
  }

  if (values.clean === 'all') {
    const { deleted } = await es('POST', `/${index}/_delete_by_query?refresh=true&conflicts=proceed`, { query: { match_all: {} } });
    console.log(`Cleaned: deleted ${deleted} documents`);
  }

  // 3. List rule files
  const listStart = performance.now();
  const files = await listRuleFiles(repoUrl, latest.sha, isLibraryFile);
  const all = [...files].map(([path, blobId]) => ({ path, blobId }));
  const ruleFiles = all.filter(({ path }) => path.endsWith('.json'));
  const skipped = all.length - ruleFiles.length;
  timings.list = performance.now() - listStart;
  console.log(`Listed ${ruleFiles.length} .json rule files${skipped ? `, skipped ${skipped} other files` : ''}: ${formatMemory(readMemory())}`);

  // 4. Download, convert and index, batch by batch
  const batches = [];
  for (let i = 0; i < ruleFiles.length; i += batchSize) batches.push(ruleFiles.slice(i, i + batchSize));
  console.log(`\nIndexing ${ruleFiles.length} rules in ${batches.length} batches of up to ${batchSize}...\n`);

  const seenRuleIds = new Map();
  const duplicates = [];
  let indexed = 0;
  let failed = 0;
  timings.git = 0;
  timings.convert = 0;
  timings.es = 0;
  for (const [number, batch] of batches.entries()) {
    const gitStart = performance.now();
    const pack = await fetchPack(repoUrl, batch.map(({ blobId }) => `want ${blobId}`));
    const objects = parsePack(pack);
    const convertStart = performance.now();
    const docs = batch.map(({ path, blobId }) => {
      const blob = objects.get(blobId);
      if (!blob) throw new Error(`Blob ${blobId} (${path}) missing from server reply`);
      const doc = parseRule(path, blob.data);
      const { rule_id: ruleId } = doc.attributes;
      if (seenRuleIds.has(ruleId)) duplicates.push(`${ruleId}: ${seenRuleIds.get(ruleId)} and ${path}`);
      seenRuleIds.set(ruleId, path);
      return doc;
    });
    const memory = readMemory();
    const esStart = performance.now();
    failed += await indexBatch(index, docs);
    indexed += docs.length;
    const esEnd = performance.now();
    timings.git += convertStart - gitStart;
    timings.convert += esStart - convertStart;
    timings.es += esEnd - esStart;

    const label = `batch ${String(number + 1).padStart(String(batches.length).length)}/${batches.length}`;
    console.log(`  ${label}  ${String(docs.length).padStart(4)} rules  pack ${kb(pack.length).padStart(9)}  git ${millis(convertStart - gitStart)}  es ${millis(esEnd - esStart)}  ${formatMemory(memory)}`);
  }

  // 5. Record what the index holds, then check
  const finishStart = performance.now();
  await es('POST', `/${index}/_refresh`);
  await es('PUT', `/${index}/_mapping`, {
    _meta: { library: { repo: repoUrl, tag: latest.name, commit: latest.sha, updated_at: new Date().toISOString() } },
  });
  const { count } = await es('POST', `/${index}/_count`, {
    query: { term: { type: 'security-rule' } },
  });
  timings.es += performance.now() - finishStart;
  timings.total = performance.now() - startedAt;
  clearInterval(sampler);
  readMemory();

  const checks = [
    [`indexed = listed (${indexed} / ${ruleFiles.length})`, indexed === ruleFiles.length],
    [`no bulk errors (${failed})`, failed === 0],
    [`no duplicate rule_id (${duplicates.length})`, duplicates.length === 0],
    [`documents in index >= indexed (${count} / ${indexed})`, count >= indexed],
  ];
  for (const duplicate of duplicates.slice(0, 5)) console.warn(`  ! duplicate ${duplicate}`);

  console.log(`
Done. ${indexed} rules from ${latest.name} indexed into ${index}
  Git requests:      ${stats.requests}, ${kb(stats.bytesDownloaded)} downloaded
  ES requests:       ${esStats.requests}, ${kb(esStats.bytesSent)} sent
  Time:              total ${seconds(timings.total)}
                       resolve ${seconds(timings.resolve)}, list ${seconds(timings.list)}
                       git fetch + unpack ${seconds(timings.git)}, parse ${seconds(timings.convert)}, Elasticsearch ${seconds(timings.es)}

Peak memory seen:
  heap      ${mb(peak.heapUsed)}  (${peak.heapUsed <= HEAP_TARGET ? 'under' : 'OVER'} the ${mb(HEAP_TARGET)} target)
  buffers   ${mb(peak.arrayBuffers)}
  rss       ${mb(peak.rss)}  (also counts Node itself)

Checks:
${checks.map(([label, ok]) => `  ${ok ? 'ok  ' : 'FAIL'}  ${label}`).join('\n')}`);
  if (checks.some(([, ok]) => !ok)) process.exitCode = 1;
};

main()
  .catch((error) => {
    console.error(`\nFailed: ${error.message}`);
    process.exitCode = 1;
  })
  .finally(async () => {
    clearInterval(sampler);
    await closeTransport();
  });
