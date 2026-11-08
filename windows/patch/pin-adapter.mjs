import { parse } from 'acorn';

export const PIN_FRAME = 'codex-usagebar-pinned-quota-v1';

export function transformPinMain(source) {
  // Reuse the existing primary-renderer and trusted-page checks for native comment popups.
  const openers = [...source.matchAll(/(\w+)\.setWindowOpenHandler\(\(\{disposition:\w+,url:(\w+),frameName:(\w+)\}\)=>\{(?=let \w+=.{1,100};if\([^;]{1,400}browserCommentPopupWindowCreatedHandlers)/g)];
  if (openers.length !== 1) return null;
  const [opening, contents, url, frame] = openers[0];
  const start = openers[0].index + opening.length;
  const guard = source.slice(start, start + 550).match(/&&"primary"===(\w+)&&(\w+)\((\w+)\.getURL\(\),this\.options\.moduleDir\)/);
  if (!guard || guard[3] !== contents) return null;
  const [, mode, trusted] = guard;
  const created = new RegExp('\\b' + contents + '\\.on\\("did-create-window",\\((\\w+),(\\w+)\\)=>\\{(?=let \\w+=.{1,100}\\.frameName)').exec(source.slice(start, start + 3600));
  if (!created) return null;
  const createdAt = start + created.index + created[0].length;
  const [, child, details] = created;
  const name = JSON.stringify(PIN_FRAME);
  const conditions = '"primary"===' + mode + '&&' + trusted + '(' + contents + '.getURL(),this.options.moduleDir)';
  const allow = 'if(' + frame + '===' + name + '){if(' + url + '!=="about:blank"||!(' + conditions + '))return{action:"deny"};' +
    'return{action:"allow",outlivesOpener:false,overrideBrowserWindowOptions:{width:392,height:630,minWidth:290,minHeight:180,' +
    'frame:false,alwaysOnTop:true,skipTaskbar:true,fullscreenable:false,maximizable:false,minimizable:false,resizable:true}}}';
  const secure = 'if(' + details + '.frameName===' + name + '){' + child + '.removeMenu();' +
    child + '.webContents.setWindowOpenHandler(()=>({action:"deny"}));' +
    'for(const event of ["will-navigate","will-redirect","will-frame-navigate"])' +
    child + '.webContents.on(event,e=>e.preventDefault());return;}';
  return source.slice(0, start) + allow + source.slice(start, createdAt) + secure + source.slice(createdAt);
}

export function discoverPortal(source) {
  // Identify the public React DOM client export rather than the reconciler's private createPortal.
  if (!source.includes('useFormStatus') || !source.includes('.createPortal=')) return null;
  const exports = parse(source, { ecmaVersion: 'latest', sourceType: 'module' }).body
    .flatMap(statement => statement.declaration?.declarations ?? []);
  const chunk = exports.find(item => item.id.name === '__rspack_esm_ids')?.init?.elements;
  const modules = exports.find(item => item.id.name === '__webpack_modules__')?.init?.properties ?? [];
  const matches = modules.filter(module => {
    const body = source.slice(module.value.start, module.value.end);
    return body.includes('.createPortal=') && body.includes('.useFormStatus=') && body.includes('.version=');
  });
  const moduleId = matches[0]?.key?.name ?? matches[0]?.key?.value;
  return chunk?.length === 1 && Number.isSafeInteger(chunk[0]?.value) && matches.length === 1 && typeof moduleId === 'string'
    ? { chunkId: chunk[0].value, moduleId } : null;
}

export async function discoverPinSupport(archive) {
  const main = [], portals = [];
  for (const [path, entry] of archive.entries) {
    if (entry.unpacked || entry.size > 16 * 1024 * 1024) continue;
    if (/^\.vite\/build\/[^/]+\.js$/.test(path)) {
      const source = (await archive.read(path)).toString();
      if (!source.includes('browserCommentPopupWindowCreatedHandlers')) continue;
      const transformed = transformPinMain(source);
      if (transformed) main.push({ path, transformed });
    } else if (/^webview\/.*\.m?js$/.test(path) && entry.size < 4 * 1024 * 1024) {
      const result = discoverPortal((await archive.read(path)).toString());
      if (result) portals.push(result);
    }
  }
  if (main.length !== 1 || portals.length !== 1) return null;
  return { ...main[0], portal: portals[0] };
}
