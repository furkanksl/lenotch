import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';

const fixture = `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleShortVersionString</key><string>1.1.2</string>
	<key>CFBundleVersion</key>
	<string>9</string>
	<!-- Keep other fields, comments, and whitespace as-is. -->
	<key>CFBundleIdentifier</key><string>com.lenotch.app</string>
</dict>
</plist>
`;

function setup(t, contents = fixture) {
  const root = mkdtempSync(join(tmpdir(), 'lenotch-bump-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(join(root, 'tools'));
  mkdirSync(join(root, 'Resources'));
  for (const path of ['package.json', 'tools/bump-version.mjs']) {
    copyFileSync(new URL(`../${path}`, import.meta.url), join(root, path));
  }
  const plist = join(root, 'Resources/Info.plist');
  writeFileSync(plist, contents);
  return { root, read: () => readFileSync(plist, 'utf8') };
}

function run(root, command, args) {
  const result = spawnSync(command, args, { cwd: root, encoding: 'utf8' });
  if (result.error) throw result.error;
  return result;
}

const expected = (version, build) => fixture.replace('>1.1.2<', `>${version}<`).replace('>9<', `>${build}<`);

test('npm run bump patch updates the plist and increments the build on each run', (t) => {
  const { root, read } = setup(t);
  const first = run(root, 'npm', ['run', 'bump', 'patch']);
  assert.equal(first.status, 0, first.stderr);
  assert.equal(read(), expected('1.1.3', 10));
  assert.match(first.stdout, /## 1\.1\.3 in CHANGELOG\.md/);

  const second = run(root, 'npm', ['run', 'bump', 'patch']);
  assert.equal(second.status, 0, second.stderr);
  assert.equal(read(), expected('1.1.4', 11));
});

for (const [target, version] of [['minor', '1.2.0'], ['major', '2.0.0'], ['1.10.0', '1.10.0']]) {
  test(`bump ${target} sets ${version} without changing unrelated plist content`, (t) => {
    const { root, read } = setup(t);
    const result = run(root, process.execPath, ['tools/bump-version.mjs', target]);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(read(), expected(version, 10));
  });
}

test('invalid arguments and non-increasing versions leave both fields alone', (t) => {
  const { root, read } = setup(t);
  for (const args of [[], ['patch', 'minor'], ['1.2'], ['1.2.0-beta'], ['01.2.0'], ['1.1.2'], ['1.1.1']]) {
    const result = run(root, process.execPath, ['tools/bump-version.mjs', ...args]);
    assert.equal(result.status, 1, `expected rejection of ${JSON.stringify(args)}`);
    assert.equal(read(), fixture);
  }
});

test('an invalid build number does not partially update the version', (t) => {
  const invalid = fixture.replace('>9<', '>1.0<');
  const { root, read } = setup(t, invalid);
  const result = run(root, process.execPath, ['tools/bump-version.mjs', 'patch']);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /positive integer build number/);
  assert.equal(read(), invalid);
});
