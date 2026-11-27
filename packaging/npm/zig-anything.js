#!/usr/bin/env node
// Launcher for the zig-anything npm package: runs the prebuilt binary for
// this platform with the same arguments, stdio and exit code.
'use strict';
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const fs = require('node:fs');

const targets = {
  'linux-x64': 'x86_64-linux-musl',
  'linux-arm64': 'aarch64-linux-musl',
  'darwin-x64': 'x86_64-macos',
  'darwin-arm64': 'aarch64-macos',
  'win32-x64': 'x86_64-windows',
  'win32-arm64': 'aarch64-windows',
};

const key = `${process.platform}-${process.arch}`;
const target = targets[key];
if (!target) {
  console.error(`zig-anything: no prebuilt binary for ${key}; build from source: https://github.com/Layfate/zig-anything/blob/main/docs/GUIDE.md#building-from-source`);
  process.exit(3);
}
const exe = path.join(__dirname, '..', 'binaries', target, process.platform === 'win32' ? 'zig-anything.exe' : 'zig-anything');
if (!fs.existsSync(exe)) {
  console.error(`zig-anything: missing ${exe}; reinstall the package`);
  process.exit(3);
}
const r = spawnSync(exe, process.argv.slice(2), { stdio: 'inherit', windowsHide: true });
if (r.error) {
  console.error(`zig-anything: cannot start ${exe}: ${r.error.message}`);
  process.exit(3);
}
if (r.signal) process.kill(process.pid, r.signal);
process.exit(r.status ?? 3);
