#!/usr/bin/env node
/**
 * Compiles every .lua file in /src with the real Luau compiler.
 * Catches syntax errors that Luau itself would reject (Roblox Studio would show
 * these in the Output window). Run: node tools/check-syntax.mjs
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Lua } from '@luau-rs/luau';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
function walk(dir, out = []) {
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) walk(full, out);
    else if (entry.endsWith('.lua')) out.push(full);
  }
  return out;
}

const lua = await Lua.create({ sandbox: true });
let failures = 0;
const files = walk(join(root, 'src')).sort();
for (const file of files) {
  const rel = file.slice(root.length + 1);
  try {
    lua.compile(readFileSync(file, 'utf8'), rel);
    console.log(`ok   ${rel}`);
  } catch (err) {
    failures += 1;
    console.log(`FAIL ${rel}\n     ${err.message}`);
  }
}
console.log(`\n${files.length - failures}/${files.length} files compile cleanly`);
process.exit(failures > 0 ? 1 : 0);
