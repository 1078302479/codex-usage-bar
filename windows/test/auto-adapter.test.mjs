import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { analyzeRenderer, discoverAdapter, transformAuto, AUTO_ADAPTER } from '../patch/auto-adapter.mjs';
import { encodeHeader } from '../patch/archive-build.mjs';
import { openAsar, sha256 } from '../patch/asar.mjs';
import { checkCompatibility } from '../patch/manage.mjs';

// Synthetic compiled module. These are our fixtures, not copied client code.
function renderer({ component = 'rail', react = 'React', jsx = 'view', tooltip = 'help', usage = 'snapshot' } = {}) {
  return `export const modules = {entry(module,exports,load){
    load.define(exports,{AmbientUsageRailMenu:()=>${component}});
    var ${react}=load('react'),${jsx}=load('jsx'),${tooltip}=load('tooltip');
    function ${component}(input){
      let {usage:${usage}}=input;
      let state=${react}.useState(false);
      let primary=${usage}?.rate_limit?.primary_window;
      let secondary=${usage}?.rate_limit?.secondary_window;
      let used=primary?.used_percent, duration=secondary?.limit_window_seconds;
      let hint=(0,${jsx}.jsx)(${tooltip}.tip,{content:'Usage',side:'right',children:'hint'});
      let original=(0,${jsx}.jsx)(${tooltip}.menu,{triggerButton:hint,contentWidth:'menuReadout',size:'compact',side:'right',children:'original icon'});
      return state[0],original;
    }
  }};`;
}

test('AST adapter resolves renamed component, namespaces, tooltip and native usage binding', () => {
  for (const names of [{}, { component: 'x9', react: 'r7', jsx: 'j3', tooltip: 't2', usage: 'u1' }]) {
    const source = renderer(names), analysis = analyzeRenderer(source);
    assert.equal(analysis.react, names.react ?? 'React');
    assert.equal(analysis.usage, names.usage ?? 'snapshot');
    const transformed = transformAuto(source);
    assert.ok(transformed.includes('data-usagebar-wrapper'));
    assert.ok(transformed.includes('original icon'));
    assert.ok(transformed.includes(`usage:${analysis.usage}`));
    assert.throws(() => transformAuto(transformed), /Already patched/);
  }
});

test('structural changes fail closed instead of guessing', () => {
  const source = renderer();
  assert.throws(() => analyzeRenderer(source.replace('primary_window', 'new_primary')), /quota field changed/);
  assert.throws(() => analyzeRenderer(source.replace("side:'right'", "side:'left'")), /tooltip/);
  assert.throws(() => analyzeRenderer(source.replace('return state[0],original;', 'if(state[0])return original;return original;')), /return structure/);
  const stale = analyzeRenderer(source);
  stale.usage = 'otherAccount';
  assert.throws(() => transformAuto(source, stale), /Stale/);
});

test('transformed component preserves original rendering and reuses the injected component identity', async () => {
  const source = transformAuto(renderer());
  const loaded = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
  const exports = {};
  const jsx = (type, props) => ({ type, props });
  function load(name) {
    if (name === 'react') return { useState: () => [false] };
    if (name === 'jsx') return { jsx, jsxs: jsx };
    return { tip: 'native-tooltip' };
  }
  load.define = (output, getters) => {
    for (const [key, get] of Object.entries(getters)) Object.defineProperty(output, key, { get });
  };
  loaded.modules.entry({}, exports, load);
  const usage = { rate_limit: {} };
  const first = exports.AmbientUsageRailMenu({ usage });
  const second = exports.AmbientUsageRailMenu({ usage });
  assert.equal(first.type, 'div');
  assert.equal(first.props.children[1].props.children, 'original icon');
  assert.equal(first.props.children[0].props.usage, usage);
  assert.equal(first.props.children[0].type, second.props.children[0].type);
});

test('duplicate component definitions and patched source are rejected', () => {
  const source = renderer();
  const duplicate = source.replace('export const modules = {', 'export const modules = {extra(m,e,l){l.define(e,{AmbientUsageRailMenu:()=>rail});function rail(){}},');
  assert.throws(() => analyzeRenderer(duplicate), /not unique/);
});

function archiveFixture(files, version = '99.12.34') {
  const entries = new Map(Object.entries(files).map(([name, content]) => [name, { size: Buffer.byteLength(content) }]));
  return { entries, async read(name) {
    return Buffer.from(name === 'package.json' ? JSON.stringify({ productName: 'Codex', version }) : files[name]);
  } };
}

test('discover accepts a new version and changed asset path using verified structure', async () => {
  const path = 'webview/new-assets/new-name.mjs';
  const source = renderer({ component: 'newRail', usage: 'currentUsage' });
  const archive = archiveFixture({
    'webview/other.js': 'const reference="AmbientUsageRailMenu";', [path]: source,
  });
  const adapter = await discoverAdapter(archive);
  assert.equal(adapter.id, AUTO_ADAPTER);
  assert.equal(adapter.target, path);
  assert.equal(adapter.version, '99.12.34');
  assert.equal(adapter.sourceSha256, sha256(Buffer.from(source)));
});

test('multiple assets or unrecognized data contracts require manual adaptation', async () => {
  await assert.rejects(discoverAdapter(archiveFixture({
    'webview/first.js': renderer(), 'webview/second.js': renderer(),
  })), /No unique/);
  await assert.rejects(discoverAdapter(archiveFixture({
    'webview/changed.js': renderer().replace('used_percent', 'changed_percent'),
  })), /quota field changed/);
});

test('compatibility checks the executable and reports missing optional features without writing a patch', async t => {
  const app = await mkdtemp(join(tmpdir(), 'usagebar-compatibility-'));
  t.after(() => rm(app, { recursive: true }));
  const archivePath = join(app, 'resources', 'app.asar');
  const exePath = join(app, 'ChatGPT.exe');
  await mkdir(join(app, 'resources'));
  const pkg = Buffer.from(JSON.stringify({ productName: 'Codex', version: '99.12.34' }));
  const rail = Buffer.from(renderer());
  const asar = Buffer.concat([encodeHeader({ files: {
    'package.json': { offset: '0', size: pkg.length },
    webview: { files: { 'rail.js': { offset: String(pkg.length), size: rail.length } } },
  } }), pkg, rail]);
  await writeFile(archivePath, asar);
  const archive = await openAsar(archivePath);
  const hash = sha256(archive.headerBytes);
  await archive.close();

  assert.equal((await checkCompatibility(app)).status, 'unavailable');
  await writeFile(exePath, 'bad executable');
  const failed = await checkCompatibility(app);
  assert.equal(failed.status, 'incompatible');
  assert.equal(failed.clientVersion, '99.12.34');
  assert.match(failed.reason, /integrity record/);

  const executable = Buffer.from(`[{"file":"resources\\\\app.asar","alg":"SHA256","value":"${hash}"}]`);
  await writeFile(exePath, executable);
  assert.deepEqual(await checkCompatibility(app), {
    status: 'partial', clientVersion: '99.12.34', resetCredits: false, pin: false,
  });
  assert.deepEqual((await readdir(app)).sort(), ['ChatGPT.exe', 'resources']);
  assert.deepEqual(await readFile(archivePath), asar);
  assert.deepEqual(await readFile(exePath), executable);
});

test('injected credit loader uses module-scoped require and waits for its dependency chunks', async () => {
  const shadowed = renderer().replace('function rail(input){', 'function rail(input){ const load = "a display label";');
  const source = transformAuto(shadowed, undefined, {
    moduleId: 'credits', exportName: 'read', chunks: [10, 20], runtimeModules: ['runtimeCore'],
  });
  const loaded = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
  const exports = {}, registered = new Set();
  let lazyLoader;
  const jsx = (type, props) => ({ type, props });
  const React = { useState: value => [typeof value === 'function' ? value() : value, () => {}],
    useRef: current => ({ current }), useEffect() {}, lazy(loader) { lazyLoader = loader; return Symbol('lazy'); } };
  function requireModule(name) {
    if (name === 'react') return React;
    if (name === 'jsx') return { jsx, jsxs: jsx };
    if (name === 'credits') {
      assert.deepEqual([...registered].sort(), [10, 20]);
      return { read: () => ({}) };
    }
    return { tip: 'native-tooltip', menu: 'native-menu' };
  }
  requireModule.define = (output, getters) => {
    for (const [key, get] of Object.entries(getters)) Object.defineProperty(output, key, { get });
  };
  requireModule.e = async id => { await Promise.resolve(); registered.add(id); };
  requireModule.m = { runtimeCore() {} };
  loaded.modules.entry({}, exports, requireModule);
  exports.AmbientUsageRailMenu({ usage: {} });
  const result = await lazyLoader();
  assert.equal(result.default.name, 'NativeResetCredits');
});

test('sidebar receives the native settings callback after the original menu initializes it', async () => {
  const input = renderer().replace('return state[0],original;',
    `let open; const Content=help.tip; return state[0],open=input.navigate,(0,view.jsx)(Content,{onManageUsage:open,children:original});`);
  const loaded = await import(`data:text/javascript;base64,${Buffer.from(transformAuto(input)).toString('base64')}`);
  const exports = {};
  const jsx = (type, props) => ({ type, props });
  function load(name) {
    if (name === 'react') return { useState: () => [false] };
    if (name === 'jsx') return { jsx, jsxs: jsx };
    return { tip: 'tooltip', menu: 'menu' };
  }
  load.define = (output, getters) => {
    for (const [key, get] of Object.entries(getters)) Object.defineProperty(output, key, { get });
  };
  loaded.modules.entry({}, exports, load);
  const navigate = () => {};
  const tree = exports.AmbientUsageRailMenu({ usage: {}, navigate });
  assert.equal(tree.props.children[0].props.onManageUsage, navigate);
  assert.equal(tree.props.children[1].props.onManageUsage, navigate);
});
