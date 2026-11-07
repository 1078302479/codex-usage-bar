import { sha256 } from './asar.mjs';
import { createSidebarQuota, nativeWindowData } from './sidebar-runtime.mjs';

// Version + whole target-asset fingerprint + unique insertion anchors.
// Never apply this profile heuristically to newer clients.
export const PROFILE = {
  id: 'windows-26.1103.31037-sidebar-v1',
  version: '26.1103.31037',
  target: 'webview/assets/async/882724.ace226df57.js',
  sourceSha256: 'a211e87e29af33eb455b2a0d966781789c7048386abeafcef8fdd300930ac7e7',
};

export function transformSidebar(source, profile = PROFILE) {
  if (source.includes('data-usagebar-sidebar')) throw new Error('Already patched');
  if (sha256(Buffer.from(source)) !== profile.sourceSha256) throw new Error('Unsupported asset fingerprint');
  const start = 'function ee(e){';
  const end = ',T}function en(e){';
  for (const anchor of [start, end]) {
    if (source.split(anchor).length !== 2) throw new Error('Insertion anchor not unique');
  }
  const factory = `const __UsageBarSidebar=(${createSidebarQuota.toString()})(s,a,h.Ab,${nativeWindowData.toString()});`;
  return source.replace(start, `${factory}${start}`).replace(end,
    ',(0,a.jsxs)("div",{"data-usagebar-wrapper":"1",style:{display:"flex",flexDirection:"column",alignItems:"center",gap:6,flexShrink:0},children:[(0,a.jsx)(__UsageBarSidebar,{usage:F}),T]})}function en(e){');
}
