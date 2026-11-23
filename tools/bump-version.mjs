import { mkdtempSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const plistPath = fileURLToPath(new URL('../Resources/Info.plist', import.meta.url));
const usage = 'Usage: npm run bump <patch|minor|major|X.Y.Z>';
const versionPattern = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;

function bump(args) {
  const [target] = args;
  if (args.length !== 1) throw new Error(usage);
  const index = ['major', 'minor', 'patch'].indexOf(target);
  const explicit = versionPattern.exec(target);
  if (index === -1 && !explicit) throw new Error(`Invalid version: ${target}\n${usage}`);

  const plist = readFileSync(plistPath, 'utf8');
  // Replace only these two strings so the rest of the plist keeps its formatting.
  function field(key) {
    const pattern = new RegExp(`(<key>${key}</key>\\s*<string>)([^<]*)(</string>)`, 'g');
    const entries = [...plist.matchAll(pattern)];
    if (entries.length !== 1) throw new Error(`Expected one ${key} string in Resources/Info.plist.`);
    return { pattern, value: entries[0][2] };
  }

  const version = field('CFBundleShortVersionString');
  const build = field('CFBundleVersion');
  const parsed = versionPattern.exec(version.value);
  if (!parsed || !/^[1-9][0-9]*$/.test(build.value)) {
    throw new Error('Resources/Info.plist must have an X.Y.Z version and a positive integer build number.');
  }

  const current = parsed.slice(1).map(BigInt);
  const next = explicit
    ? explicit.slice(1).map(BigInt)
    : current.map((part, i) => i < index ? part : i === index ? part + 1n : 0n);
  const firstChange = next.findIndex((part, i) => part !== current[i]);
  if (firstChange === -1 || next[firstChange] < current[firstChange]) {
    throw new Error(`New version must be higher than ${version.value}.`);
  }

  const nextVersion = next.join('.');
  const nextBuild = BigInt(build.value) + 1n;
  const updated = plist
    .replace(version.pattern, (_match, open, _value, close) => `${open}${nextVersion}${close}`)
    .replace(build.pattern, (_match, open, _value, close) => `${open}${nextBuild}${close}`);

  const mode = statSync(plistPath).mode & 0o777;
  const temp = mkdtempSync(join(dirname(plistPath), '.bump-'));
  try {
    const staged = join(temp, 'Info.plist');
    writeFileSync(staged, updated, { mode });
    renameSync(staged, plistPath);
  } finally {
    rmSync(temp, { recursive: true });
  }

  console.log(`LeNotch ${version.value} → ${nextVersion} (build ${build.value} → ${nextBuild})`);
  console.log(`Add release notes under ## ${nextVersion} in CHANGELOG.md before building.`);
}

try {
  bump(process.argv.slice(2));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
