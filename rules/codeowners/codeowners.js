#!/usr/bin/env node
'use strict';

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const USAGE = `Usage: codeowners.js [options] [file ...]

Resolve GitHub CODEOWNERS owners for files. Last matching rule wins.

File sources (combine freely):
  file ...             Paths relative to the repo root
  -                    Read paths from stdin, one per line
  --pr <number|url>    Files changed in a PR (includes renamed-from paths)
  --branch [base]      Files changed on HEAD vs base (default: upstream/main)

Options:
  --repo <owner/name>  Repo used by --pr (default: elastic/kibana)
  --codeowners <path>  CODEOWNERS file (default: <git root>/.github/CODEOWNERS)
  --by-file            One line per file with owners and matching CODEOWNERS line
  --by-team            Files grouped by owner (default when using --pr/--branch/stdin)
  --json               Machine-readable output
  -h, --help           Show this help
`;

const UNOWNED = '(unowned)';

const escapeRegex = (char) => char.replace(/[.+^${}()|[\]\\]/g, '\\$&');

const globToRegexSource = (glob) => {
  let source = '';
  for (let i = 0; i < glob.length; i++) {
    const char = glob[i];
    if (char === '\\' && i + 1 < glob.length) {
      source += escapeRegex(glob[++i]);
    } else if (char === '*' && glob[i + 1] === '*') {
      const standaloneSegment = (i === 0 || glob[i - 1] === '/') && glob[i + 2] === '/';
      if (standaloneSegment) {
        source += '(?:.*/)?';
        i += 2;
      } else {
        source += '.*';
        i += 1;
      }
    } else if (char === '*') {
      source += '[^/]*';
    } else if (char === '?') {
      source += '[^/]';
    } else {
      source += escapeRegex(char);
    }
  }
  return source;
};

const compilePattern = (rawPattern) => {
  const directoryOnly = rawPattern.endsWith('/');
  const trimmed = directoryOnly ? rawPattern.slice(0, -1) : rawPattern;
  const anchored = trimmed.includes('/');
  const body = globToRegexSource(trimmed.replace(/^\//, ''));
  const prefix = anchored ? '^' : '^(?:.*/)?';
  const suffix = directoryOnly ? '/.*$' : '(?:/.*)?$';
  return new RegExp(`${prefix}${body}${suffix}`);
};

const tokenizeLine = (line) => {
  const tokens = [];
  let current = '';
  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (char === '\\' && i + 1 < line.length) {
      current += char + line[++i];
    } else if (/\s/.test(char)) {
      if (current) tokens.push(current);
      current = '';
    } else if (char === '#' && !current) {
      break;
    } else {
      current += char;
    }
  }
  if (current) tokens.push(current);
  return tokens;
};

const parseCodeowners = (content) => {
  const rules = [];
  content.split(/\r?\n/).forEach((line, index) => {
    const [pattern, ...owners] = tokenizeLine(line.trim());
    if (!pattern) return;
    rules.push({
      line: index + 1,
      pattern,
      owners,
      regex: compilePattern(pattern),
    });
  });
  return rules;
};

const normalizePath = (filePath) => filePath.replace(/\\/g, '/').replace(/^\.?\//, '');

const findOwners = (rules, filePath) => {
  const normalized = normalizePath(filePath);
  for (let i = rules.length - 1; i >= 0; i--) {
    if (rules[i].regex.test(normalized)) {
      const { owners, line, pattern } = rules[i];
      return { file: normalized, owners, line, pattern };
    }
  }
  return { file: normalized, owners: [], line: null, pattern: null };
};

const run = (command, args, options = {}) =>
  execFileSync(command, args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...options });

const splitLines = (text) =>
  text
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);

const gitRoot = () => run('git', ['rev-parse', '--show-toplevel']).trim();

const filesFromPr = (pr, repo) => {
  const number = String(pr).match(/(\d+)\/?$/)?.[1];
  if (!number) throw new Error(`Cannot read a PR number from '${pr}'`);
  const output = run('gh', [
    'api',
    '--paginate',
    `repos/${repo}/pulls/${number}/files`,
    '--jq',
    '.[] | .filename, (.previous_filename // empty)',
  ]);
  return splitLines(output);
};

const filesFromBranch = (base) => {
  const [remote, ...rest] = base.split('/');
  if (rest.length > 0) {
    try {
      run('git', ['fetch', remote, rest.join('/')], { stdio: 'ignore' });
    } catch {
      process.stderr.write(`warning: could not fetch ${base}, using local ref\n`);
    }
  }
  return splitLines(run('git', ['diff', '--name-only', `${base}...HEAD`]));
};

const parseArgs = (argv) => {
  const options = {
    files: [],
    stdin: false,
    pr: null,
    branch: null,
    repo: 'elastic/kibana',
    codeowners: null,
    view: null,
    json: false,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === '-h' || arg === '--help') options.help = true;
    else if (arg === '--json') options.json = true;
    else if (arg === '--by-file') options.view = 'file';
    else if (arg === '--by-team') options.view = 'team';
    else if (arg === '--pr') options.pr = argv[++i];
    else if (arg === '--repo') options.repo = argv[++i];
    else if (arg === '--codeowners') options.codeowners = argv[++i];
    else if (arg === '--branch') {
      options.branch = next && !next.startsWith('-') ? argv[++i] : 'upstream/main';
    } else if (arg === '-') options.stdin = true;
    else if (arg.startsWith('-')) throw new Error(`Unknown option '${arg}'`);
    else options.files.push(arg);
  }
  return options;
};

const groupByOwner = (results) => {
  const groups = new Map();
  for (const { file, owners } of results) {
    for (const owner of owners.length > 0 ? owners : [UNOWNED]) {
      if (!groups.has(owner)) groups.set(owner, []);
      groups.get(owner).push(file);
    }
  }
  return [...groups.entries()].sort(
    ([ownerA, filesA], [ownerB, filesB]) =>
      (ownerA === UNOWNED) - (ownerB === UNOWNED) ||
      filesB.length - filesA.length ||
      ownerA.localeCompare(ownerB)
  );
};

const formatByFile = (results) =>
  results
    .map(({ file, owners, line }) => {
      const ownerText = owners.length > 0 ? owners.join(' ') : UNOWNED;
      return `${file}\t${ownerText}\t${line ? `CODEOWNERS:${line}` : '-'}`;
    })
    .join('\n');

const formatByTeam = (results) =>
  groupByOwner(results)
    .map(([owner, files]) => `${owner} (${files.length})\n${files.map((f) => `  ${f}`).join('\n')}`)
    .join('\n\n');

const main = () => {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    process.stdout.write(USAGE);
    return;
  }

  const root = gitRoot();
  const codeownersPath = options.codeowners || path.join(root, '.github', 'CODEOWNERS');
  const rules = parseCodeowners(fs.readFileSync(codeownersPath, 'utf8'));

  const files = [...options.files];
  if (options.stdin) files.push(...splitLines(fs.readFileSync(0, 'utf8')));
  if (options.pr) files.push(...filesFromPr(options.pr, options.repo));
  if (options.branch) files.push(...filesFromBranch(options.branch));

  const uniqueFiles = [...new Set(files.map(normalizePath))];
  if (uniqueFiles.length === 0) {
    process.stderr.write(USAGE);
    process.exitCode = 1;
    return;
  }

  const results = uniqueFiles.map((file) => findOwners(rules, file));

  if (options.json) {
    process.stdout.write(`${JSON.stringify(results, null, 2)}\n`);
    return;
  }

  const bulkInput = Boolean(options.pr || options.branch || options.stdin);
  const view = options.view || (bulkInput ? 'team' : 'file');
  process.stdout.write(`${view === 'team' ? formatByTeam(results) : formatByFile(results)}\n`);
};

module.exports = { parseCodeowners, findOwners, compilePattern, groupByOwner };

if (require.main === module) {
  try {
    main();
  } catch (error) {
    process.stderr.write(`error: ${error.message}\n`);
    process.exitCode = 1;
  }
}
