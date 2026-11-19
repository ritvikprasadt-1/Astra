#!/usr/bin/env node
/**
 * Offline Luau test harness for the space-exploration project.
 *
 * Loads the REAL modules from /src into a sandboxed Luau VM (Node + WASM),
 * emulating just enough of the Roblox instance tree (`require(script.Parent.X)`,
 * `game:GetService(...)`, `task.*`) to execute them. Then runs every test file
 * in /tools/tests.
 *
 * Why: Roblox Studio cannot be scripted from this environment, so this harness
 * is how game logic is genuinely executed and verified. It compiles the exact
 * files that ship, so a syntax error or logic bug fails the build.
 *
 * Usage:  node tools/harness/run.mjs [name-filter]
 * Exit:   0 = all assertions passed
 */
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Lua } from '@luau-rs/luau';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');
const src = join(root, 'src');

/** Recursively collect .lua files as "Folder/Sub/Name" keys. */
function walk(dir, out = []) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) walk(full, out);
    else if (entry.name.endsWith('.lua')) {
      const rel = full.slice(src.length + 1).replace(/\.lua$/, '');
      out.push({ path: rel, source: readFileSync(full, 'utf8') });
    }
  }
  return out;
}

const files = walk(src);
const lua = await Lua.create({ sandbox: true });

// Luau print/warn -> Node stdout.
lua.globals.set('io_write', (text) => process.stdout.write(String(text)));

// Compile every module up-front; a syntax error fails loudly with its path.
// Each module is wrapped in `function(...) ... end` so it can be executed with
// its own environment via setfenv, exactly like a Roblox ModuleScript.
const moduleFunctions = {};
lua.globals.set('__FILE_PATHS', files.map((f) => f.path));
for (const f of files) {
  const bytecode = lua.compile(`return function(...)\n${f.source}\nend`, f.path);
  moduleFunctions[f.path] = lua.executeBytecode(bytecode)[0];
}
// NOTE: lua.globals.set on a plain object only takes effect if the value is
// pushed as individual Lua values; function handles are pushed correctly, but
// a JS *object* would be re-encoded. Build the table inside Luau instead.
lua.globals.set('__MODFN', Object.values(moduleFunctions));
lua.execute(`
  __MODULES = {}
  local paths = __FILE_PATHS
  local fns = __MODFN
  for i = 1, #paths do
    __MODULES[paths[i]] = fns[i]
  end
`);

// The loader returns the Roblox stub bag; publish it as Luau globals.
const loaders = lua.execute(readFileSync(join(here, 'loader.lua'), 'utf8'));
for (const [key, value] of Object.entries(loaders[0].toObject())) {
  lua.globals.set(key, value);
}

// Create the whole instance tree up-front so require() order never matters.
lua.execute('Harness.registerModules(__FILE_PATHS)');

const describeSource = readFileSync(join(here, 'describe.lua'), 'utf8');
// Compile test helpers as function handles too (bytecode set() would store a string).
// describe.lua takes the shared results table as its single argument.
const describeFn = lua.executeBytecode(
  lua.compile(`return function(...)\n${describeSource}\nend`, 'describe.lua'),
)[0];

const filter = process.argv[2];
const testDir = join(root, 'tools/tests');
const tests = existsSync(testDir)
  ? readdirSync(testDir)
      .filter((f) => f.endsWith('.lua') && (!filter || f.includes(filter)))
      .sort()
  : [];

let totalPass = 0;
let totalFail = 0;
const failures = [];

for (const file of tests) {
  const source = readFileSync(join(testDir, file), 'utf8');
  lua.execute(`__PHASE = { pass = 0, fail = 0, failures = {}, suite = ${JSON.stringify(file)} }`);
  lua.globals.set('__describeChunk', describeFn);
  lua.globals.set(
    '__testChunk',
    lua.executeBytecode(lua.compile(`return function(...)\n${source}\nend`, `tools/tests/${file}`))[0],
  );
  let result;
  try {
    result = lua.execute(`
      local phase = __PHASE
      __describeChunk(phase)
      local suite = __testChunk()
      local ok, err = pcall(suite, function(path) return Harness.loadModule(path) end, phase)
      if not ok then
        phase.fail = phase.fail + 1
        table.insert(phase.failures, "suite crashed: " .. tostring(err))
      end
      return phase.pass, phase.fail, table.concat(phase.failures, "\\n")
    `.replace('__TEST_NAME', JSON.stringify(file)));
  } catch (err) {
    result = [0, 1, `LOAD ERROR: ${err.message}`];
  }
  const [pass, fail, failureText] = result;
  totalPass += Number(pass);
  totalFail += Number(fail);
  console.log(`${Number(fail) > 0 ? '✗' : '✓'} ${file}  (${pass} passed, ${fail} failed)`);
  if (failureText) failures.push(`--- ${file} ---\n${failureText}`);
}

if (failures.length) console.log('\n' + failures.join('\n\n'));
console.log(`\n${totalPass} assertions passed, ${totalFail} failed`);
process.exit(totalFail > 0 ? 1 : 0);
