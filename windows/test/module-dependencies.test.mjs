import test from 'node:test';
import assert from 'node:assert/strict';
import { discoverModuleDependencies } from '../patch/module-dependencies.mjs';

function bundle(chunk, modules) {
  return `export const __rspack_esm_ids=[${chunk}];export const __webpack_modules__={${modules}};`;
}

test('credit query preload follows transitive static dependencies before module initialization', async () => {
  const files = {
    'webview/query.js': bundle(10, 'query(m,e,r){var dep=r("wrapper");function consumeLater(){r("unused")}r("runtimeCore")}'),
    'webview/wrapper.js': bundle(20, 'wrapper(m,e,r){var dep=r("state")}'),
    'webview/state.js': bundle(30, 'state(m,e,r){r("wrapper")}'),
    'webview/unrelated.js': bundle(40, 'unused(m,e,r){}'),
  };
  const archive = {
    entries: new Map(Object.entries(files).map(([path, source]) => [path, { size: source.length }])),
    read: async path => Buffer.from(files[path]),
  };
  const plan = await discoverModuleDependencies(archive, { moduleId: 'query', resourcePath: 'webview/query.js' });
  assert.deepEqual(plan.chunks, [10, 20, 30]);
  assert.deepEqual(plan.runtimeModules, ['runtimeCore']);
});

test('desktop chunk map excludes another renderer’s implementation of the same module', async () => {
  const files = {
    'webview/index.html': '<script type="module" src="/assets/entry.js"></script>',
    'webview/assets/entry.js': 'const req={};req.u=id=>"assets/async/"+id+"."+({10:"a0",20:"b0"}[id])+".js";export{req as __webpack_require__};',
    'webview/assets/async/10.a0.js': bundle(10, 'query(m,e,r){r("dep")}'),
    'webview/assets/async/11.a1.js': bundle(11, 'dep(m,e,r){r("wrongRenderer")}'),
    'webview/assets/async/20.b0.js': bundle(20, 'dep(m,e,r){}'),
  };
  const archive = {
    entries: new Map(Object.entries(files).map(([path, source]) => [path, { size: source.length }])),
    read: async path => Buffer.from(files[path]),
  };
  const plan = await discoverModuleDependencies(archive, { moduleId: 'query', resourcePath: 'webview/assets/async/10.a0.js' });
  assert.deepEqual(plan, { chunks: [10, 20], runtimeModules: [] });
});
