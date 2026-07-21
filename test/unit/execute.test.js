'use strict';

const test = require('node:test');
const assert = require('node:assert');

const { execute, git, GIT_TIMEOUT_MS } = require('../../src/index.js');

test('execute kills a hung command and throws a clear timeout error', () => {
  assert.throws(
    () => execute('sleep', ['30'], { timeout: 600 }),
    /timed out after \d+s/,
  );
});

test('execute surfaces a timeout without throwing when allowFailure is set', () => {
  const result = execute('sleep', ['30'], { timeout: 600, allowFailure: true });
  assert.strictEqual(result.error && result.error.code, 'ETIMEDOUT');
  assert.notStrictEqual(result.status, 0, 'a timed-out command must not report success');
});

test('git uses the tight 1-minute deadline yet fast local commands pass', () => {
  assert.strictEqual(GIT_TIMEOUT_MS, 60_000);
  const out = git(process.cwd(), ['rev-parse', '--is-inside-work-tree']).stdout.trim();
  assert.strictEqual(out, 'true');
});
