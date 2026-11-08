import assert from 'node:assert/strict';
import { test } from 'node:test';
import { discoverPortal, PIN_FRAME, transformPinMain } from '../patch/pin-adapter.mjs';

const source = 'function wire(contents,mode,trust){contents.setWindowOpenHandler(({disposition:d,url:u,frameName:f})=>{' +
  'let comment=decode(f);if(comment?.valid&&this.browserCommentPopupWindowCreatedHandlers.size>0&&"about:blank"===u&&"primary"===mode&&trust(contents.getURL(),this.options.moduleDir))return{action:"allow"};return{action:"deny"}' +
  '});contents.on("did-create-window",(popup,details)=>{let comment=decode(details.frameName);if(comment?.valid)nativePopup(popup)})}';

test('only the named blank window from the trusted primary renderer receives topmost options', () => {
  const transformed = transformPinMain(source);
  assert.ok(transformed);
  const wire = new Function('decode', 'nativePopup', transformed + ';return wire')(
    name => ({ valid: name === 'native-comment' }), () => {});
  let opener, created;
  const contents = {
    getURL: () => 'app://-/index.html',
    getZoomFactor: () => 1.25,
    setWindowOpenHandler(handler) { opener = handler; },
    on(event, handler) { if (event === 'did-create-window') created = handler; },
  };
  const manager = { options: {}, browserCommentPopupWindowCreatedHandlers: new Set([1]) };
  const request = { url: 'about:blank', frameName: PIN_FRAME,
    features: 'popup=yes,usagebarbounds=-230.00:400.00:-60.00:-20.00:360.00:160.00' };
  wire.call(manager, contents, 'primary', () => true);
  const result = opener(request);
  assert.equal(result.action, 'allow');
  assert.equal(result.outlivesOpener, false);
  assert.equal(result.overrideBrowserWindowOptions.alwaysOnTop, true);
  assert.equal(result.overrideBrowserWindowOptions.skipTaskbar, true);
  const { x, y, width, height } = result.overrideBrowserWindowOptions;
  assert.deepEqual({ x, y, width, height }, { x: -305, y: 375, width: 450, height: 200 });
  assert.deepEqual(opener({ ...request, features: 'popup=yes' }), { action: 'deny' });
  assert.deepEqual(opener({ ...request, url: 'https://example.test/' }), { action: 'deny' });
  assert.deepEqual(opener({ ...request, frameName: 'native-comment' }), { action: 'allow' });
  const blocked = [];
  created({ removeMenu() {}, webContents: {
    setZoomFactor(zoom) { assert.equal(zoom, 1.25); },
    once(event, handler) { assert.equal(event, 'did-finish-load'); handler(); },
    setWindowOpenHandler(handler) { assert.equal(handler().action, 'deny'); },
    on(event, handler) { handler({ preventDefault: () => blocked.push(event) }); },
  } }, request);
  assert.deepEqual(blocked, ['will-navigate', 'will-redirect', 'will-frame-navigate']);
  wire.call(manager, contents, 'secondary', () => true);
  assert.equal(opener(request).action, 'deny');
  wire.call(manager, contents, 'primary', () => false);
  assert.equal(opener(request).action, 'deny');
  assert.equal(transformPinMain(source + source), null);
});

test('uses only a unique public React DOM portal export', () => {
  const prefix = 'export const __rspack_esm_ids=[123];export const __webpack_modules__=';
  const module = 'ui(e,n){n.createPortal=()=>0;n.useFormStatus=()=>0;n.version="19.2.7"}';
  assert.deepEqual(discoverPortal(prefix + '{' + module + '}'), { chunkId: 123, moduleId: 'ui' });
  assert.equal(discoverPortal(prefix + '{' + module + ',' + module.replace('ui(', 'other(') + '}'), null);
});
