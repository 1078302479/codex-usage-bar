import { parse } from 'acorn';

async function rendererAssets(archive) {
  const index = (await archive.read('webview/index.html')).toString();
  const initial = [...index.matchAll(/<script\b[^>]*\bsrc="(\/assets\/[\w.-]+\.js)"/g)]
    .map(match => `webview${match[1]}`);
  const maps = [];
  for (const path of initial) {
    const source = (await archive.read(path)).toString();
    if (!source.includes('__webpack_require__') || !source.includes('assets/async/')) continue;
    const ast = parse(source, { ecmaVersion: 'latest', sourceType: 'module' });
    function walk(node, visit) {
      if (!node?.type) return;
      visit(node);
      for (const value of Object.values(node)) {
        if (Array.isArray(value)) value.forEach(child => walk(child, visit));
        else if (value?.type) walk(value, visit);
      }
    }
    walk(ast, node => {
      if (node.type !== 'AssignmentExpression' || node.left?.property?.name !== 'u'
          || !source.slice(node.right.start, node.right.end).includes('"assets/async/"')) return;
      walk(node.right, child => {
        if (child.type !== 'ObjectExpression' || !child.properties.length) return;
        const files = child.properties.map(property => ({ id: property.key?.value, hash: property.value?.value }));
        if (files.every(file => Number.isSafeInteger(file.id) && typeof file.hash === 'string' && /^[a-f0-9]+$/.test(file.hash))) {
          maps.push(files.map(file => `webview/assets/async/${file.id}.${file.hash}.js`));
        }
      });
    });
  }
  if (maps.length !== 1) throw new Error('Desktop renderer chunk map is unavailable or ambiguous');
  return { initial, allowed: new Set([...initial, ...maps[0]]) };
}

// Resolve top-level require() edges only. Loading a renderer chunk registers its
// modules but does not mount unrelated settings or invoke any mutation hooks.
export async function discoverModuleDependencies(archive, root) {
  const modules = new Map();
  const parsed = new Set();
  const renderer = archive.entries.has('webview/index.html') ? await rendererAssets(archive) : null;
  const paths = [...archive.entries].filter(([path, entry]) => (!renderer || renderer.allowed.has(path)) && /^webview\/.*\.m?js$/.test(path)
    && entry.size <= 16 * 1024 * 1024 && !entry.unpacked).map(([path]) => path);
  function visit(node, callback) {
    if (!node?.type || /Function/.test(node.type)) return;
    callback(node);
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) value.forEach(child => visit(child, callback));
      else if (value?.type) visit(value, callback);
    }
  }
  function index(source, path) {
    parsed.add(path);
    const ast = parse(source, { ecmaVersion: 'latest', sourceType: 'module' });
    const declarations = ast.body.filter(node => node.type === 'ExportNamedDeclaration')
      .flatMap(node => node.declaration?.declarations ?? []);
    const chunks = declarations.find(node => node.id.name === '__rspack_esm_ids')?.init?.elements?.map(node => node.value);
    const registry = declarations.find(node => node.id.name === '__webpack_modules__')?.init;
    if (!registry || !chunks?.length || !chunks.every(Number.isSafeInteger)) return;
    for (const property of registry.properties ?? []) {
      const fn = property.value, id = property.key.name ?? property.key.value;
      const requireName = fn?.params?.[2]?.name;
      const dependencies = new Set();
      if (requireName) visit(fn.body, node => {
        if (node.type === 'CallExpression' && node.callee?.type === 'Identifier' && node.callee.name === requireName
            && node.arguments.length === 1 && ['string', 'number'].includes(typeof node.arguments[0]?.value)) {
          dependencies.add(String(node.arguments[0].value));
        }
      });
      if (!modules.has(String(id))) modules.set(String(id), { chunks, dependencies: [...dependencies] });
    }
  }
  function closure() {
    const used = new Set(), unresolved = new Set(), queue = [root.moduleId];
    while (queue.length) {
      const id = String(queue.pop());
      if (used.has(id)) continue;
      used.add(id);
      const entry = modules.get(id);
      if (!entry) unresolved.add(id);
      else queue.push(...entry.dependencies);
    }
    return { used, unresolved };
  }
  if (renderer && !renderer.allowed.has(root.resourcePath)) throw new Error('Reset-credit hook belongs to a different renderer');
  for (const path of renderer?.initial ?? []) index((await archive.read(path)).toString(), path);
  index((await archive.read(root.resourcePath)).toString(), root.resourcePath);
  let changed;
  do {
    changed = false;
    const { unresolved } = closure();
    if (!unresolved.size) break;
    const escape = value => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const names = [...unresolved].flatMap(id => [escape(id), escape(JSON.stringify(id))]);
    const definition = new RegExp(`(?:^|[,{])\\s*(?:${names.join('|')})\\s*(?:\\(|:)`);
    for (const path of paths) {
      if (parsed.has(path)) continue;
      const source = (await archive.read(path)).toString();
      if (!definition.test(source)) continue;
      const before = modules.size;
      index(source, path);
      if (modules.size > before) changed = true;
    }
  } while (changed);
  const { used, unresolved } = closure();
  return {
    chunks: [...new Set([...used].flatMap(id => modules.get(id)?.chunks ?? []))].sort((a, b) => a - b),
    // Entry-runtime modules have no async chunk. The injected loader verifies
    // them against the actual runtime registry before initializing the hook.
    runtimeModules: [...unresolved].sort(),
  };
}
