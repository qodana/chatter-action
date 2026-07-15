#!/usr/bin/env node
'use strict';

const childProcess = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');

const ACTION_ROOT = process.env.GITHUB_ACTION_PATH || path.resolve(__dirname, '..');
const TRACE_PREFIX = 'chatter:gzip:';
const MAX_ENCODED_NOTE_BYTES = 200_000;
const MAX_DECODED_NOTE_BYTES = 2_000_000;
const MAX_BRANCH_COMMITS = 200;
const CHECK_NAME = 'Chatter attribution';
const MAX_CHECK_SUMMARY_CHARS = 65_000;

function log(message) {
  console.log(`chatter-action: ${message}`);
}

function warn(message) {
  console.log(`::warning::chatter-action: ${message}`);
}

function getInput(name, fallback = '') {
  const normalized = name.replace(/ /g, '_').toUpperCase();
  const value = process.env[`INPUT_${normalized}`] ?? process.env[`INPUT_${normalized.replace(/-/g, '_')}`];
  return value === undefined || value.trim() === '' ? fallback : value.trim();
}

function booleanInput(name, fallback) {
  const value = getInput(name, String(fallback)).toLowerCase();
  if (value === 'true') return true;
  if (value === 'false') return false;
  throw new Error(`${name} must be true or false`);
}

function setOutput(name, value) {
  if (process.env.GITHUB_OUTPUT) {
    fs.appendFileSync(process.env.GITHUB_OUTPUT, `${name}=${String(value)}\n`);
  }
}

function appendSummary(text) {
  if (process.env.GITHUB_STEP_SUMMARY) {
    fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, text);
  }
}

function execute(command, args, options = {}) {
  const result = childProcess.spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env || process.env,
    input: options.input,
    encoding: 'utf8',
    maxBuffer: 20 * 1024 * 1024,
  });
  const stdout = result.stdout || '';
  const stderr = result.stderr || '';
  const outcome = { ...result, stdout, stderr };
  if (result.error) {
    if (options.allowFailure) return outcome;
    throw result.error;
  }
  if (result.status !== 0 && !options.allowFailure) {
    const detail = stderr.trim() || stdout.trim() || `exit ${result.status}`;
    throw new Error(`${command} ${args.join(' ')} failed: ${detail}`);
  }
  return outcome;
}

function git(repo, args, options = {}) {
  return execute('git', args, { ...options, cwd: repo });
}

function gitText(repo, args, options = {}) {
  return git(repo, args, options).stdout.trim();
}

function gitLines(repo, args, options = {}) {
  const text = gitText(repo, args, options);
  return text ? text.split('\n').filter(Boolean) : [];
}

function readEvent() {
  const eventPath = process.env.GITHUB_EVENT_PATH;
  if (!eventPath) throw new Error('GITHUB_EVENT_PATH is required');
  return JSON.parse(fs.readFileSync(eventPath, 'utf8'));
}

function filterNotesRef(filter, requested) {
  const expected = filter === 'rollout'
    ? 'refs/notes/chatter'
    : filter === 'wal'
      ? 'refs/notes/wal-chatter'
      : null;
  if (!expected) throw new Error(`unsupported filter '${filter}' (want rollout|wal)`);
  if (requested && requested !== expected) {
    throw new Error(`notes-ref '${requested}' contradicts filter '${filter}' (chatter uses ${expected})`);
  }
  return expected;
}

function loadConfig() {
  const filter = getInput('filter', 'rollout');
  return {
    mode: getInput('mode', 'auto'),
    filter,
    notesRef: filterNotesRef(filter, getInput('notes-ref', '')),
    baseUrl: getInput('base-url', ''),
    comment: booleanInput('comment', true),
    check: booleanInput('check', true),
    githubToken: getInput('github-token', ''),
    predict: booleanInput('predict', false),
    pushNotes: booleanInput('push-notes', true),
    extensions: getInput('extensions', ''),
  };
}

function installBinary(config) {
  const runnerTemp = process.env.RUNNER_TEMP || fs.mkdtempSync(path.join(os.tmpdir(), 'chatter-action-'));
  const chatterHome = path.join(runnerTemp, 'chatter-action');
  fs.mkdirSync(chatterHome, { recursive: true });
  const env = { ...process.env, CHATTER_HOME: chatterHome };
  if (config.baseUrl) env.CHATTER_BASE_URL = config.baseUrl;
  execute('sh', [path.join(ACTION_ROOT, 'install.sh'), '--bin-only'], { env });
  const binary = path.join(chatterHome, 'bin', 'chatter');
  fs.accessSync(binary, fs.constants.X_OK);
  log(`using chatter binary ${binary}`);
  return binary;
}

function fetchNotes(repo, notesRef) {
  const result = git(repo, ['fetch', '--no-tags', 'origin', `+${notesRef}:${notesRef}`], { allowFailure: true });
  if (result.status !== 0) {
    log(`no ${notesRef} on origin yet`);
    return 0;
  }
  return normalizeFetchedNotes(repo, notesRef);
}

function parseTrace(raw) {
  let json = raw;
  if (raw.startsWith(TRACE_PREFIX)) {
    if (Buffer.byteLength(raw) > MAX_ENCODED_NOTE_BYTES) return null;
    const compressed = Buffer.from(raw.slice(TRACE_PREFIX.length), 'base64');
    const decoded = zlib.gunzipSync(compressed, { maxOutputLength: MAX_DECODED_NOTE_BYTES + 1 });
    if (decoded.length > MAX_DECODED_NOTE_BYTES) return null;
    json = decoded.toString('utf8');
  } else if (Buffer.byteLength(raw) > MAX_DECODED_NOTE_BYTES) {
    return null;
  }
  try {
    const parsed = JSON.parse(json);
    return parsed && typeof parsed === 'object' ? parsed : null;
  } catch (_) {
    return null;
  }
}

function encodeTrace(trace) {
  return `${TRACE_PREFIX}${zlib.gzipSync(Buffer.from(JSON.stringify(trace))).toString('base64')}`;
}

function normalizeFetchedNotes(repo, notesRef) {
  let normalized = 0;
  for (const entry of gitLines(repo, ['notes', '--ref', notesRef, 'list'])) {
    const commit = entry.trim().split(/\s+/)[1];
    if (!commit) continue;
    const note = git(repo, ['notes', '--ref', notesRef, 'show', commit], { allowFailure: true });
    if (note.status !== 0) continue;
    const raw = note.stdout.trim();
    if (raw.startsWith(TRACE_PREFIX)) continue;
    const trace = parseTrace(raw);
    if (!trace) continue;
    const encoded = encodeTrace(trace);
    if (Buffer.byteLength(encoded) > MAX_ENCODED_NOTE_BYTES) {
      warn(`cannot normalize oversized plain trace note for ${commit.slice(0, 10)}`);
      continue;
    }
    const written = git(repo, ['notes', '--ref', notesRef, 'add', '-f', '-F', '-', commit], {
      input: `${encoded}\n`,
      allowFailure: true,
    });
    if (written.status !== 0) {
      warn(`cannot normalize plain trace note for ${commit.slice(0, 10)}`);
    } else {
      normalized += 1;
    }
  }
  return normalized;
}

function readTrace(repo, notesRef, commit) {
  const note = git(repo, ['notes', '--ref', notesRef, 'show', commit], { allowFailure: true });
  if (note.status !== 0) return null;
  return parseTrace(note.stdout.trim());
}

function noteCoverage(repo, notesRef, commits) {
  let noted = 0;
  for (const commit of commits) {
    if (readTrace(repo, notesRef, commit)) noted += 1;
  }
  return `${noted}/${commits.length}`;
}

function ensureGitIdentity(repo) {
  if (git(repo, ['config', 'user.email'], { allowFailure: true }).status !== 0) {
    git(repo, ['config', 'user.email', 'chatter-action@jetbrains.com']);
  }
  if (git(repo, ['config', 'user.name'], { allowFailure: true }).status !== 0) {
    git(repo, ['config', 'user.name', 'chatter-action']);
  }
}

function requireFullHistory(repo) {
  if (gitText(repo, ['rev-parse', '--is-shallow-repository']) !== 'false') {
    throw new Error("shallow checkout: add 'fetch-depth: 0' to actions/checkout");
  }
}

function ensureCommit(repo, sha) {
  if (git(repo, ['rev-parse', '-q', '--verify', `${sha}^{commit}`], { allowFailure: true }).status !== 0) {
    git(repo, ['fetch', '--no-tags', 'origin', sha]);
  }
}

function patchId(repo, commit) {
  const diff = git(repo, ['diff', '--full-index', `${commit}^`, commit], { allowFailure: true });
  if (diff.status !== 0 || !diff.stdout) return '';
  const id = git(repo, ['patch-id', '--stable'], { input: diff.stdout, allowFailure: true });
  return id.status === 0 ? (id.stdout.trim().split(/\s+/)[0] || '') : '';
}

function commitMapping(repo, landed, requestedPr = '') {
  const parentLine = gitText(repo, ['rev-list', '--parents', '-n1', landed]);
  const parents = parentLine.split(' ').slice(1).filter(Boolean);
  if (parents.length >= 2) return { method: 'MERGE_PARENTS', pairs: [] };
  const firstParent = parents[0] || landed;

  const body = gitText(repo, ['show', '-s', '--format=%b', landed]);
  const cherry = body.match(/cherry picked from commit ([0-9a-f]{7,64})/i);
  if (cherry) {
    const resolved = git(repo, ['rev-parse', '-q', '--verify', `${cherry[1]}^{commit}`], { allowFailure: true });
    if (resolved.status === 0) return { method: 'CHERRY_TRAILER', pairs: [[resolved.stdout.trim(), landed]] };
  }

  let pr = requestedPr;
  if (!pr) {
    const subject = gitText(repo, ['show', '-s', '--format=%s', landed]);
    pr = (subject.match(/\(#(\d+)\)\s*$/) || [])[1] || '';
  }
  if (pr) {
    const fetched = git(repo, ['fetch', '--no-tags', '--quiet', 'origin', `refs/pull/${pr}/head`], { allowFailure: true });
    if (fetched.status === 0) {
      const prHead = gitText(repo, ['rev-parse', 'FETCH_HEAD']);
      const mergeBase = git(repo, ['merge-base', firstParent, prHead], { allowFailure: true }).stdout.trim() || firstParent;
      const branch = gitLines(repo, ['rev-list', prHead, '--not', mergeBase, '--max-count', String(MAX_BRANCH_COMMITS)]);
      if (branch.length >= 2) {
        const pool = branch.map((commit) => ({ commit, id: patchId(repo, commit), used: false }));
        let current = landed;
        const pairs = [];
        for (let index = 0; index < branch.length; index += 1) {
          const id = patchId(repo, current);
          const match = pool.find((entry) => !entry.used && entry.id && entry.id === id);
          if (!match) break;
          match.used = true;
          pairs.push([match.commit, current]);
          const previous = git(repo, ['rev-parse', '-q', '--verify', `${current}^`], { allowFailure: true }).stdout.trim();
          if (!previous && index + 1 < branch.length) break;
          current = previous;
        }
        if (pairs.length === branch.length) return { method: 'REBASE_MERGE', pairs };
        return { method: 'SQUASH_VIA_PR', pairs: branch.map((commit) => [commit, landed]) };
      }
      if (branch.length === 1) {
        const source = branch[0];
        return {
          method: patchId(repo, landed) && patchId(repo, landed) === patchId(repo, source) ? 'PATCH_ID' : 'PR_CONTENT',
          pairs: [[source, landed]],
        };
      }
      return { method: 'PR_CONTENT', pairs: [[prHead, landed]] };
    }
  }

  const identities = gitText(repo, ['show', '-s', '--format=%ae%x1f%ce', landed]).split('\x1f');
  return identities[0] && identities[0] === identities[1]
    ? { method: 'IDENTITY', pairs: [] }
    : { method: 'UNKNOWN', pairs: [] };
}

function writeMapping(pairs) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'chatter-action-mapping-'));
  const mappingPath = path.join(directory, 'mapping.txt');
  fs.writeFileSync(mappingPath, pairs.map(([oldSha, newSha]) => `${oldSha} ${newSha}`).join('\n') + '\n');
  return mappingPath;
}

async function pushNotes(repo, notesRef) {
  const incoming = `${notesRef}-chatter-action-incoming`;
  let lastError = '';
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    const pushed = git(repo, ['push', '--no-verify', 'origin', `${notesRef}:${notesRef}`], { allowFailure: true });
    if (pushed.status === 0) {
      log(`notes pushed (attempt ${attempt})`);
      git(repo, ['update-ref', '-d', incoming], { allowFailure: true });
      return;
    }
    lastError = pushed.stderr.trim() || pushed.stdout.trim();
    log(`notes push rejected (attempt ${attempt}); merging remote notes and retrying`);
    git(repo, ['fetch', '--no-tags', 'origin', `+${notesRef}:${incoming}`]);
    const merged = git(repo, ['notes', '--ref', notesRef, 'merge', '-s', 'ours', incoming], { allowFailure: true });
    if (merged.status !== 0) warn('notes merge reported conflicts; kept local deterministic side');
    await new Promise((resolve) => setTimeout(resolve, attempt * 1000));
  }
  throw new Error(`failed to push ${notesRef} after 5 attempts: ${lastError}`);
}

async function runMainline(repo, event, config, binary) {
  requireFullHistory(repo);
  ensureGitIdentity(repo);
  const normalized = fetchNotes(repo, config.notesRef);
  if (normalized && config.pushNotes) {
    log(`publishing ${normalized} normalized plain trace note(s) before compute`);
    await pushNotes(repo, config.notesRef);
  } else if (normalized) {
    warn('plain trace notes were normalized locally, but push-notes=false prevents compute from using them');
  }

  const targets = [];
  if (process.env.GITHUB_EVENT_NAME === 'pull_request' || process.env.GITHUB_EVENT_NAME === 'pull_request_target') {
    if (!event.pull_request?.merged) return;
    const sha = event.pull_request.merge_commit_sha;
    if (!sha) throw new Error('merged PR without merge_commit_sha');
    ensureCommit(repo, sha);
    targets.push({ sha, pr: String(event.pull_request.number || '') });
  } else if (process.env.GITHUB_EVENT_NAME === 'push') {
    const before = event.before;
    const after = event.after;
    if (!after || /^0+$/.test(after)) return;
    const range = !before || /^0+$/.test(before) ? [after, '-n', String(MAX_BRANCH_COMMITS)] : [`${before}..${after}`];
    for (const sha of gitLines(repo, ['rev-list', '--first-parent', ...range])) targets.push({ sha, pr: '' });
  } else {
    throw new Error(`mainline mode cannot run on event '${process.env.GITHUB_EVENT_NAME}'`);
  }

  let computed = 0;
  const methods = [];
  for (const target of targets) {
    const mapping = commitMapping(repo, target.sha, target.pr);
    methods.push(mapping.method);
    log(`mapping for ${target.sha.slice(0, 10)}: ${mapping.method} (${mapping.pairs.length} pair(s))`);
    if (mapping.method === 'MERGE_PARENTS' || mapping.method === 'IDENTITY') continue;
    if (mapping.method === 'UNKNOWN') {
      warn(`cannot map ${target.sha.slice(0, 10)} back to authored commits; skipping`);
      continue;
    }

    const pairs = mapping.pairs.filter(([oldSha, newSha]) => oldSha !== newSha);
    if (!pairs.length) {
      log('all mapped commits already have their landed SHA; no compute needed');
      continue;
    }
    const oldShas = pairs.map(([oldSha]) => oldSha);
    const coverage = noteCoverage(repo, config.notesRef, oldShas);
    setOutput('notes-coverage', coverage);
    if (coverage.startsWith('0/')) {
      warn(`no branch commit of ${target.sha.slice(0, 10)} has a readable published note (${coverage}); skipping`);
      continue;
    }

    const mappingPath = writeMapping(pairs);
    execute(binary, ['compute', '--filter', config.filter, '--repo', repo, '--mapping', mappingPath]);
    computed += 1;
    appendSummary(`### chatter: trace notes for \`${target.sha.slice(0, 10)}\`\n\n- mapping method: \`${mapping.method}\`, branch-note coverage: ${coverage}\n`);
  }
  setOutput('method', methods[0] || '');
  setOutput('computed-commits', computed);
  if (computed && config.pushNotes) await pushNotes(repo, config.notesRef);
  if (computed && !config.pushNotes) log('push-notes=false: computed notes left local only');
}

function changedFiles(repo, head, baseRef, extensions) {
  const mergeBase = gitText(repo, ['merge-base', `refs/remotes/origin/${baseRef}`, head]);
  let files = gitLines(repo, ['-c', 'core.quotePath=false', 'diff', '--name-only', mergeBase, head]);
  const allowed = extensions.split(',').map((extension) => extension.trim()).filter(Boolean)
    .map((extension) => extension.startsWith('.') ? extension : `.${extension}`);
  if (allowed.length) files = files.filter((file) => allowed.some((extension) => file.endsWith(extension)));
  return files;
}

function blameChangedAt(repo, revision, baseRef, extensions, binary, filter) {
  let aiLines = 0;
  let totalLines = 0;
  const rows = [];
  const attributions = [];
  for (const file of changedFiles(repo, revision, baseRef, extensions)) {
    if (git(repo, ['cat-file', '-e', `${revision}:${file}`], { allowFailure: true }).status !== 0) continue;
    const blamed = execute(binary, ['blame', file, '--commit', revision, '--json', '--filter', filter, '--repo', repo], { allowFailure: true });
    if (blamed.status !== 0) continue;
    let report;
    try { report = JSON.parse(blamed.stdout); } catch (_) { continue; }
    const item = report[0] || {};
    const ai = Number(item.attributedLines || 0);
    const total = Number(item.totalLines || 0);
    aiLines += ai;
    totalLines += total;
    if (ai) rows.push(`| \`${file}\` | ${ai} / ${total} |`);
    for (const count of Array.isArray(item.chatCounts) ? item.chatCounts : []) {
      const lines = Number(count.lineCount || 0);
      if (!count.chatId || lines <= 0) continue;
      attributions.push({
        chatId: String(count.chatId),
        providerName: count.providerName || '',
        model: count.model || '',
        lines,
      });
    }
  }
  return { aiLines, totalLines, rows, attributions };
}

function agentTable(repo, notesRef, commits, attributions) {
  const sourceByChat = new Map();
  for (const commit of commits) {
    const trace = readTrace(repo, notesRef, commit);
    for (const file of trace?.files || []) {
      for (const conversation of file.conversations || []) {
        if (!conversation.url) continue;
        const key = `${conversation.agent || '?'}\t${conversation.contributor?.model_id || '-'}`;
        if (!sourceByChat.has(String(conversation.url))) sourceByChat.set(String(conversation.url), key);
      }
    }
  }

  const totals = new Map();
  for (const attribution of attributions) {
    const key = attribution.providerName
      ? `${attribution.providerName}\t${attribution.model || '-'}`
      : sourceByChat.get(attribution.chatId) || '?\t-';
    totals.set(key, (totals.get(key) || 0) + attribution.lines);
  }
  if (!totals.size) return '';
  const rows = [...totals.entries()].map(([key, lines]) => ({ key, lines })).sort((a, b) => b.lines - a.lines);
  return `\n| agent | model | lines |\n|---|---|---|\n${rows.map(({ key, lines }) => {
    const [agent, model] = key.split('\t');
    return `| ${agent} | ${model} | ${lines} |`;
  }).join('\n')}\n`;
}

function githubApiUrl(pathname) {
  const root = (process.env.GITHUB_API_URL || 'https://api.github.com').replace(/\/+$/, '');
  return `${root}${pathname}`;
}

function githubHeaders(token) {
  return {
    authorization: `Bearer ${token}`,
    accept: 'application/vnd.github+json',
    'content-type': 'application/json',
    'x-github-api-version': '2022-11-28',
  };
}

function checkSummary(report) {
  const summary = report.replace(/^<!-- chatter-action-report -->\n?/, '');
  if (summary.length <= MAX_CHECK_SUMMARY_CHARS) return summary;
  const suffix = '\n\n_Report truncated for the GitHub Checks API._\n';
  return `${summary.slice(0, MAX_CHECK_SUMMARY_CHARS - suffix.length)}${suffix}`;
}

async function postCheckRun(event, report, token) {
  const pr = event.pull_request;
  const baseRepo = event.repository?.full_name;
  const headRepo = pr?.head?.repo?.full_name;
  const headSha = pr?.head?.sha;
  if (!token || !baseRepo || !headSha || headRepo !== baseRepo) return;
  try {
    const response = await fetch(githubApiUrl(`/repos/${baseRepo}/check-runs`), {
      method: 'POST',
      headers: githubHeaders(token),
      body: JSON.stringify({
        name: CHECK_NAME,
        head_sha: headSha,
        status: 'completed',
        conclusion: 'success',
        external_id: `chatter-action:${process.env.GITHUB_RUN_ID || 'local'}:${headSha}`,
        output: {
          title: CHECK_NAME,
          summary: checkSummary(report),
        },
      }),
    });
    if (!response.ok) throw new Error(`create check run returned ${response.status}`);
    log(`published '${CHECK_NAME}' check run`);
  } catch (error) {
    warn(`failed to publish check run: ${error.message}`);
  }
}

async function postReportComment(event, report, token) {
  if (!event.pull_request) return;
  const baseRepo = event.repository?.full_name;
  const headRepo = event.pull_request.head?.repo?.full_name;
  if (!token || !baseRepo || headRepo !== baseRepo) return;
  try {
    const headers = githubHeaders(token);
    const number = event.pull_request.number;
    const listed = await fetch(githubApiUrl(`/repos/${baseRepo}/issues/${number}/comments?per_page=100`), { headers });
    if (!listed.ok) throw new Error(`list comments returned ${listed.status}`);
    const comments = await listed.json();
    const existing = comments.find((comment) => String(comment.body || '').startsWith('<!-- chatter-action-report -->'));
    const endpoint = existing
      ? githubApiUrl(`/repos/${baseRepo}/issues/comments/${existing.id}`)
      : githubApiUrl(`/repos/${baseRepo}/issues/${number}/comments`);
    const response = await fetch(endpoint, {
      method: existing ? 'PATCH' : 'POST',
      headers,
      body: JSON.stringify({ body: report }),
    });
    if (!response.ok) throw new Error(`write comment returned ${response.status}`);
  } catch (error) {
    warn(`failed to post PR comment: ${error.message}`);
  }
}

async function runPrReport(repo, event, config, binary) {
  requireFullHistory(repo);
  ensureGitIdentity(repo);
  fetchNotes(repo, config.notesRef);
  const pr = event.pull_request;
  if (!pr) throw new Error('pr mode requires a pull_request event');
  const head = pr.head.sha;
  const baseRef = pr.base.ref;
  ensureCommit(repo, head);
  git(repo, ['fetch', '--no-tags', '--quiet', 'origin', `+refs/heads/${baseRef}:refs/remotes/origin/${baseRef}`], { allowFailure: true });
  const branch = gitLines(repo, ['rev-list', head, '--not', `refs/remotes/origin/${baseRef}`, '--max-count', String(MAX_BRANCH_COMMITS)]);
  let report;
  if (!branch.length) {
    report = '<!-- chatter-action-report -->\n### chatter: agent trace\n\nNo branch commits to attribute.\n';
  } else {
    const coverage = noteCoverage(repo, config.notesRef, branch);
    setOutput('notes-coverage', coverage);
    const factual = blameChangedAt(repo, head, baseRef, config.extensions, binary, config.filter);
    const percent = factual.totalLines ? Math.floor((100 * factual.aiLines) / factual.totalLines) : 0;
    report = [
      '<!-- chatter-action-report -->',
      '### chatter: agent attribution of this branch',
      '',
      `**${factual.aiLines} of ${factual.totalLines}** lines in changed files are AI-attributed (${percent}%), from trace notes on **${coverage}** branch commits.`,
      factual.rows.length ? `\n| file | AI lines |\n|---|---|\n${factual.rows.join('\n')}` : '',
      agentTable(repo, config.notesRef, branch, factual.attributions),
      '',
    ].join('\n');
    setOutput('ai-lines', factual.aiLines);
    setOutput('total-lines', factual.totalLines);

    if (config.predict) {
      const fetched = git(repo, ['fetch', '--no-tags', '--quiet', 'origin', `+refs/pull/${pr.number}/merge:refs/chatter-action/pr-merge`], { allowFailure: true });
      if (fetched.status === 0) {
        const mergeSha = gitText(repo, ['rev-parse', 'refs/chatter-action/pr-merge']);
        const pairs = branch.filter((commit) => commit !== mergeSha).map((commit) => [commit, mergeSha]);
        if (pairs.length) {
          const predicted = execute(binary, ['compute', '--filter', config.filter, '--repo', repo, '--mapping', writeMapping(pairs)], { allowFailure: true });
          if (predicted.status === 0) {
            const blamed = blameChangedAt(repo, mergeSha, baseRef, config.extensions, binary, config.filter);
            const percentPrediction = blamed.totalLines ? Math.floor((100 * blamed.aiLines) / blamed.totalLines) : 0;
            report += `\n#### Preview of GitHub's test merge (not published)\n\nComputed on temporary test-merge commit \`${mergeSha.slice(0, 10)}\`: **${blamed.aiLines} of ${blamed.totalLines}** lines (${percentPrediction}%).\n`;
            if (blamed.rows.length) report += `\n| file | AI lines |\n|---|---|\n${blamed.rows.join('\n')}\n`;
            report += agentTable(repo, config.notesRef, [mergeSha], blamed.attributions);
            setOutput('predicted-ai-lines', blamed.aiLines);
          } else {
            log('prediction compute failed; the factual section stands alone');
          }
        }
      }
    }
  }
  const reportDir = fs.mkdtempSync(path.join(os.tmpdir(), 'chatter-action-report-'));
  const reportPath = path.join(reportDir, 'report.md');
  fs.writeFileSync(reportPath, report);
  appendSummary(report);
  setOutput('report-path', reportPath);
  if (config.check) await postCheckRun(event, report, config.githubToken);
  if (config.comment) await postReportComment(event, report, config.githubToken);
}

function selectMode(config, event) {
  if (config.mode === 'pr' || config.mode === 'mainline') return config.mode;
  if (config.mode !== 'auto') throw new Error(`unknown mode '${config.mode}'`);
  const eventName = process.env.GITHUB_EVENT_NAME;
  if (eventName === 'push') return 'mainline';
  if (eventName === 'pull_request' || eventName === 'pull_request_target') {
    if (event.action === 'closed') return event.pull_request?.merged ? 'mainline' : null;
    return 'pr';
  }
  throw new Error(`unsupported event '${eventName}' (use mode: pr|mainline explicitly)`);
}

async function main() {
  const event = readEvent();
  const config = loadConfig();
  const mode = selectMode(config, event);
  if (!mode) {
    log('PR closed without merge; nothing to do');
    return;
  }
  log(`mode: ${mode} (event: ${process.env.GITHUB_EVENT_NAME})`);
  const repo = process.cwd();
  git(repo, ['rev-parse', '--git-dir']);
  const binary = installBinary(config);
  if (mode === 'mainline') await runMainline(repo, event, config, binary);
  else await runPrReport(repo, event, config, binary);
}

main().catch((error) => {
  console.error(`::error::chatter-action: ${error.message}`);
  process.exit(1);
});
