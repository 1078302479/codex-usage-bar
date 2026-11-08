import { parse } from 'acorn';
import { sha256 } from './asar.mjs';
import { createSidebarQuota, nativeWindowData } from './sidebar-runtime.mjs';
import { resetCreditPresentation, createResetCreditView } from './reset-credits.mjs';
import { discoverModuleDependencies } from './module-dependencies.mjs';
import { PIN_FRAME } from './pin-adapter.mjs';

export const AUTO_ADAPTER = 'windows-sidebar-structural-v1';

function walk(node, visit) {
  if (!node || typeof node.type !== 'string') return;
  visit(node);
  for (const value of Object.values(node)) {
    if (Array.isArray(value)) value.forEach(child => walk(child, visit));
    else if (value && typeof value.type === 'string') walk(value, visit);
  }
}

function ownNodes(fn, visit) {
  function descend(node) {
    if (node !== fn.body && /Function/.test(node.type)) return;
    visit(node);
    for (const value of Object.values(node)) {
      if (Array.isArray(value)) value.filter(child => child?.type).forEach(descend);
      else if (value?.type) descend(value);
    }
  }
  descend(fn.body);
}

function propertyName(node) {
  if (node?.type === 'Identifier') return node.name;
  if (node?.type === 'Literal') return node.value;
  return null;
}

function memberName(node) {
  if (node?.type !== 'MemberExpression') return null;
  if (node.computed && node.property.type !== 'Literal') return null;
  return propertyName(node.property);
}

function calleeOf(node) {
  const callee = node.callee;
  return callee?.type === 'SequenceExpression' ? callee.expressions.at(-1) : callee;
}

function unique(values, label) {
  const names = [...new Set(values)];
  if (names.length !== 1) throw new Error(`Ambiguous or unsupported ${label}`);
  return names[0];
}

export function analyzeRenderer(source) {
  if (source.includes('data-usagebar-sidebar')) throw new Error('Already patched');
  const ast = parse(source, { ecmaVersion: 'latest', sourceType: 'module' });
  const candidates = [];
  walk(ast, module => {
    // Rspack module methods are independent lexical scopes. Resolve every local
    // identifier inside the actual exporting module, never by minified spelling.
    if (!['FunctionExpression', 'ArrowFunctionExpression'].includes(module.type) || module.body.type !== 'BlockStatement') return;
    const exported = [];
    ownNodes(module, node => {
      if (node.type !== 'ObjectExpression') return;
      for (const property of node.properties) {
        if (propertyName(property.key) === 'AmbientUsageRailMenu'
            && property.value?.type === 'ArrowFunctionExpression'
            && property.value.body.type === 'Identifier') exported.push(property.value.body.name);
      }
    });
    if (!exported.length) return;
    const name = unique(exported, 'rail export');
    const functions = module.body.body.filter(node => node.type === 'FunctionDeclaration' && node.id?.name === name);
    if (functions.length !== 1) throw new Error('Rail component declaration not unique');
    candidates.push({ module, fn: functions[0] });
  });
  if (candidates.length === 0) {
    const error = new Error('Rail component export not found');
    error.code = 'NO_RAIL_EXPORT';
    throw error;
  }
  if (candidates.length !== 1) throw new Error('Rail component module not unique');
  const { module, fn } = candidates[0];
  if (fn.async || fn.generator) throw new Error('Asynchronous rail component is unsupported');
  const react = [], jsx = [], tooltips = [], menus = [], returns = [], usage = [], navigation = [], intl = [];
  const properties = new Set();
  walk(fn, node => {
    const name = memberName(node);
    if (name) properties.add(name);
  });
  ownNodes(fn, node => {
    if (node.type === 'ReturnStatement') returns.push(node);
    if (node.type === 'VariableDeclarator' && node.id.type === 'ObjectPattern'
        && node.init?.type === 'Identifier' && node.init.name === fn.params[0]?.name) {
      for (const property of node.id.properties) {
        if (propertyName(property.key) === 'usage' && property.value?.type === 'Identifier') usage.push(property.value.name);
      }
    }
    if (node.type !== 'CallExpression') return;
    const callee = calleeOf(node);
    if (callee?.object?.type !== 'Identifier') return;
    const name = memberName(callee);
    if (name === 'useState') react.push(callee.object.name);
    if (name === 'formatMessage' && node.arguments[0]?.type === 'ObjectExpression'
        && node.arguments[0].properties.some(prop => propertyName(prop.key) === 'id'
          && String(prop.value?.value).startsWith('codex.ambientUsage.railMenu.'))) intl.push(callee.object.name);
    if (!['jsx', 'jsxs'].includes(name)) return;
    jsx.push(callee.object.name);
    const [component, props] = node.arguments;
    if (props?.type !== 'ObjectExpression') return;
    const keys = props.properties.map(property => propertyName(property.key));
    const manage = props.properties.find(property => propertyName(property.key) === 'onManageUsage');
    if (manage?.value?.type === 'Identifier') navigation.push(manage.value.name);
    if (component?.type !== 'MemberExpression') return;
    const side = props.properties.find(property => propertyName(property.key) === 'side');
    if (keys.includes('content') && keys.includes('children') && side?.value?.value === 'right') {
      tooltips.push(source.slice(component.start, component.end));
    }
    const width = props.properties.find(property => propertyName(property.key) === 'contentWidth');
    const size = props.properties.find(property => propertyName(property.key) === 'size');
    if (keys.includes('triggerButton') && keys.includes('children') && side?.value?.value === 'right'
        && width?.value?.value === 'menuReadout' && size?.value?.value === 'compact') {
      menus.push(source.slice(component.start, component.end));
    }
  });
  if (returns.length !== 1 || !returns[0].argument) throw new Error('Rail return structure changed');
  for (const field of ['rate_limit', 'primary_window', 'secondary_window', 'used_percent', 'limit_window_seconds']) {
    if (!properties.has(field)) throw new Error(`Native quota field changed: ${field}`);
  }
  const result = { moduleInsertion: module.body.start + 1,
    returnStart: returns[0].argument.start, returnEnd: returns[0].argument.end,
    react: unique(react, 'React namespace'), jsx: unique(jsx, 'JSX namespace'),
    tooltip: unique(tooltips, 'native tooltip'), menu: unique(menus, 'native quota menu'),
    usage: unique(usage, 'native usage binding'), require: module.params[2]?.name,
    manageUsage: navigation.length ? unique(navigation, 'native usage navigation') : null,
    intl: intl.length ? unique(intl, 'native locale formatter') : null };
  if (!result.require) throw new Error('Renderer chunk loader unavailable');
  const moduleBindings = new Set(module.params.filter(param => param.type === 'Identifier').map(param => param.name));
  for (const statement of module.body.body) {
    if (statement.type !== 'VariableDeclaration') continue;
    for (const declaration of statement.declarations) {
      if (declaration.id.type === 'Identifier') moduleBindings.add(declaration.id.name);
    }
  }
  const tooltipRoot = result.tooltip.split('.')[0];
  const menuRoot = result.menu.split('.')[0];
  if (!/^[A-Za-z_$][\w$]*\.[A-Za-z_$][\w$]*$/.test(result.tooltip)
      || !/^[A-Za-z_$][\w$]*\.[A-Za-z_$][\w$]*$/.test(result.menu)
      || [result.react, result.jsx, tooltipRoot, menuRoot].some(name => !moduleBindings.has(name))) {
    throw new Error('Renderer dependencies moved out of module scope');
  }
  return result;
}

export function transformAuto(source, analysis = analyzeRenderer(source), resetCredits = null, display = null, pinPortal = null) {
  // Reanalyze instead of accepting stale offsets or identifiers from a report.
  if (JSON.stringify(analysis) !== JSON.stringify(analyzeRenderer(source))) throw new Error('Stale renderer analysis');
  const binding = '__UsageBarAutoSidebar';
  const createBinding = '__UsageBarCreateSidebar';
  if (source.includes(binding) || source.includes(createBinding)) throw new Error('Adapter binding collision');
  const chunks = resetCredits?.chunks ?? (resetCredits ? [resetCredits.chunkId] : []);
  const runtimeModules = resetCredits?.runtimeModules ?? [];
  const loader = resetCredits ? `()=>Promise.all(${JSON.stringify(chunks)}.map(id=>${analysis.require}.e(id))).then(()=>{if(${analysis.require}.m&&${JSON.stringify(runtimeModules)}.some(id=>!${analysis.require}.m[id]))throw new Error("reset-credit-runtime-dependency");return ${analysis.require}(${JSON.stringify(resetCredits.moduleId)})[${JSON.stringify(resetCredits.exportName)}]})` : 'null';
  const creditView = `(${createResetCreditView.toString()})(${analysis.react},${analysis.jsx},${resetCreditPresentation.toString()})`;
  const pin = pinPortal ? `{name:${JSON.stringify(PIN_FRAME)},portal:()=>${analysis.require}.e(${pinPortal.chunkId}).then(()=>${analysis.require}(${JSON.stringify(pinPortal.moduleId)}).createPortal)}` : "null";
  const factory = `(${createSidebarQuota.toString()})(${analysis.react},${analysis.jsx},${analysis.menu},${nativeWindowData.toString()},${loader},${creditView},${JSON.stringify(display)},${pin})`;
  const originalReturn = source.slice(analysis.returnStart, analysis.returnEnd);
  const title = analysis.intl ? `${analysis.intl}.formatMessage({id:"settings.usage.resets.title",defaultMessage:"Usage limit resets"})` : 'null';
  const navigation = analysis.manageUsage ? `,onManageUsage:${analysis.manageUsage},resetHeading:${title}` : '';
  // Evaluate the original return first. It initializes the memoized settings callback.
  const replacement = `(__usagebarOriginal=>${analysis.jsx}.jsxs("div",{"data-usagebar-wrapper":"1",style:{display:"flex",flexDirection:"column",alignItems:"center",gap:6,flexShrink:0},children:[${analysis.jsx}.jsx((${binding}??=${createBinding}()),{usage:${analysis.usage}${navigation}}),__usagebarOriginal]}))((${originalReturn}))`;
  const modified = source.slice(0, analysis.returnStart) + replacement + source.slice(analysis.returnEnd);
  // Resolve native imports at module scope, where a minified component's local
  // variables cannot shadow the Rspack require function or its dependencies.
  const declaration = `let ${binding};function ${createBinding}(){return ${factory}}`;
  const output = modified.slice(0, analysis.moduleInsertion) + declaration + modified.slice(analysis.moduleInsertion);
  parse(output, { ecmaVersion: 'latest', sourceType: 'module' });
  return output;
}

export async function readCodexVersion(archive) {
  const pkg = JSON.parse((await archive.read('package.json')).toString());
  if (pkg.productName !== 'Codex' || typeof pkg.version !== 'string'
      || !/^[A-Za-z0-9._-]{1,80}$/.test(pkg.version)) throw new Error('Unsupported client package');
  return pkg.version;
}

export async function discoverAdapter(archive) {
  const version = await readCodexVersion(archive);
  const candidates = [], resetHooks = [];
  for (const [path, entry] of archive.entries) {
    if (!/^webview\/.*\.m?js$/.test(path) || entry.size > 16 * 1024 * 1024 || entry.unpacked) continue;
    const source = (await archive.read(path)).toString();
    if (source.includes('/wham/rate-limit-reset-credits')) {
      const hook = discoverResetCreditsHook(source);
      if (hook) resetHooks.push({ ...hook, resourcePath: path, sourceSha256: sha256(Buffer.from(source)) });
    }
    if (!source.includes('AmbientUsageRailMenu')) continue;
    // Ambiguous or changed modules fail closed, with their path in the report.
    let analysis;
    try { analysis = analyzeRenderer(source); }
    catch (error) {
      if (error.code === 'NO_RAIL_EXPORT') continue;
      throw new Error(`${path}: ${error.message}`);
    }
    candidates.push({ id: AUTO_ADAPTER, version, target: path,
      sourceSha256: sha256(Buffer.from(source)), analysis, source });
  }
  if (candidates.length !== 1) throw new Error('No unique compatible rail resource found');
  if (resetHooks.length > 1) throw new Error('Native reset-credit query hook is ambiguous');
  const resetCredits = resetHooks[0] ? { ...resetHooks[0], ...await discoverModuleDependencies(archive, resetHooks[0]) } : null;
  return { ...candidates[0], resetCredits };
}

export function discoverResetCreditsHook(source) {
  const ast = parse(source, { ecmaVersion: 'latest', sourceType: 'module' });
  let chunkIds;
  walk(ast, node => {
    if (node.type === 'VariableDeclarator' && node.id.name === '__rspack_esm_ids' && node.init?.type === 'ArrayExpression') {
      chunkIds = node.init.elements.map(value => value?.value);
    }
  });
  const matches = [];
  walk(ast, property => {
    const module = property.value;
    if (property.type !== 'Property' || module?.type !== 'FunctionExpression' || module.body.type !== 'BlockStatement') return;
    const functions = module.body.body.filter(node => node.type === 'FunctionDeclaration');
    const readers = functions.filter(fn => {
      const statement = fn.body.body[0];
      const request = statement?.argument;
      return fn.params.length === 0 && fn.body.body.length === 1 && statement?.type === 'ReturnStatement'
        && request?.type === 'CallExpression' && memberName(calleeOf(request)) === 'safeGet'
        && request.arguments.length === 1 && request.arguments[0]?.value === '/wham/rate-limit-reset-credits';
    });
    for (const reader of readers) {
      const hooks = functions.filter(fn => {
        let found = false;
        ownNodes(fn, node => {
          if (node.type !== 'ObjectExpression') return;
          const queryFn = node.properties.find(prop => propertyName(prop.key) === 'queryFn');
          const queryKey = node.properties.find(prop => propertyName(prop.key) === 'queryKey');
          if (queryFn?.value?.name === reader.id.name && queryKey?.value?.type === 'ArrayExpression'
              && queryKey.value.elements.length === 1 && queryKey.value.elements[0]?.value === 'rate-limit-reset-credits') found = true;
        });
        return found;
      });
      for (const hook of hooks) ownNodes(module, node => {
        if (node.type !== 'ObjectExpression') return;
        for (const exported of node.properties) {
          if (exported.value?.type === 'ArrowFunctionExpression' && exported.value.body?.type === 'Identifier'
              && exported.value.body.name === hook.id.name) {
            matches.push({ moduleId: propertyName(property.key), exportName: propertyName(exported.key) });
          }
        }
      });
    }
  });
  if (matches.length === 0) return null;
  if (matches.length !== 1 || chunkIds?.length !== 1 || !Number.isSafeInteger(chunkIds[0])) {
    throw new Error('Native reset-credit query export is ambiguous');
  }
  return { chunkId: chunkIds[0], ...matches[0] };
}
