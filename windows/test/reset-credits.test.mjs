import test from 'node:test';
import assert from 'node:assert/strict';
import { resetCreditPresentation } from '../patch/reset-credits.mjs';
import { discoverResetCreditsHook } from '../patch/auto-adapter.mjs';
import { createSidebarQuota, nativeWindowData } from '../patch/sidebar-runtime.mjs';
import { createResetCreditView } from '../patch/reset-credits.mjs';

const now = Date.UTC(2026, 10, 6, 12);
const card = (id, hours, extra = {}) => ({ id, status: 'available', reset_type: 'codex_rate_limits',
  expires_at: hours === null ? null : (now + hours * 3600000) / 1000, ...extra });

test('reset cards show authoritative counts and macOS-equivalent 72-hour and nearest-expiry summary', () => {
  const data = resetCreditPresentation({ available_count: 3, credits: [card('late', 90), card('soon', 3), card('next', 48)] }, 99, now);
  assert.equal(data.count, 3);
  assert.equal(data.complete, true);
  assert.equal(data.expiring, 2);
  assert.equal(data.earliest, now + 3 * 3600000);
  assert.deepEqual(data.cards.map(value => value.id), ['soon', 'next', 'late']);
});

test('missing data remains unknown, zero is valid and missing dates are never invented', () => {
  const absent = resetCreditPresentation(null, undefined, now);
  assert.equal(absent.count, null);
  assert.equal(absent.complete, false);
  assert.equal(absent.detailsReturned, false);
  assert.equal(resetCreditPresentation(null, 2, now).count, 2);
  const zero = resetCreditPresentation({ available_count: 0, credits: [card('old', 2)] }, 3, now);
  assert.equal(zero.count, 0);
  assert.deepEqual(zero.cards, []);
  const incomplete = resetCreditPresentation({ available_count: 3, credits: [card('unknown', null)] }, null, now);
  assert.equal(incomplete.complete, false);
  assert.equal(incomplete.earliest, null);
  assert.equal(incomplete.cards[0].expiresAt, null);
});

test('conflicting IDs, used cards and other reset types cannot inflate expiry counts', () => {
  const row = card('duplicate', 10);
  const data = resetCreditPresentation({ available_count: 4, credits: [row, row,
    card('conflict', 1), card('conflict', 2), card('used', 5, { status: 'redeemed' }),
    card('other', 3, { reset_type: 'other_product' })] }, null, now);
  assert.equal(data.cards.length, 1);
  assert.equal(data.expiring, 1);
  assert.equal(data.complete, false);
});

test('expired dates do not count toward future 72 hours and ISO timestamps use explicit zones', () => {
  const data = resetCreditPresentation({ available_count: 3, credits: [card('expired', -1),
    card('iso', null, { expires_at: new Date(now + 3600000).toISOString() }),
    card('bad', null, { expires_at: '2026-11-07 12:00' })] }, null, now);
  assert.equal(data.expiring, 1);
  assert.equal(data.earliest, now + 3600000);
  assert.equal(data.cards.find(value => value.id === 'bad').expiresAt, null);
});

function queryModule({ reader = 'readCredits', hook = 'useCredits', moduleId = 'creditsModule', exported = 'readOnlyHook' } = {}) {
  return `export const __rspack_esm_ids=[123];export const __webpack_modules__={${moduleId}(m,e,r){
    r.define(e,{${exported}:()=>${hook}});
    function ${reader}(){return client.safeGet('/wham/rate-limit-reset-credits')}
    function ${hook}(){return query({queryKey:['rate-limit-reset-credits'],queryFn:${reader}})}
    function consume(){return client.safePost('/wham/rate-limit-reset-credits/consume')}
  }};`;
}

test('native query adapter finds only the read hook across renamed identifiers', () => {
  assert.deepEqual(discoverResetCreditsHook(queryModule()), { chunkId: 123, moduleId: 'creditsModule', exportName: 'readOnlyHook' });
  assert.deepEqual(discoverResetCreditsHook(queryModule({ reader: 'a', hook: 'b', moduleId: 'c', exported: 'd' })),
    { chunkId: 123, moduleId: 'c', exportName: 'd' });
  assert.equal(discoverResetCreditsHook(queryModule().replace("safeGet('/wham/rate-limit-reset-credits')", "safePost('/wham/rate-limit-reset-credits')")), null);
  assert.equal(discoverResetCreditsHook(queryModule().replace("queryKey:['rate-limit-reset-credits']", "queryKey:['other']")), null);
  assert.equal(discoverResetCreditsHook(queryModule().replace("return client.safeGet", "client.safePost('/mutate');return client.safeGet")), null);
});

test('native credit hook loads lazily, rejects old cached rows and contains chunk load failure', async () => {
  let load;
  const React = { useState: value => [typeof value === 'function' ? value() : value, () => {}],
    useRef: current => ({ current }), useEffect() {}, Suspense: Symbol('Suspense'),
    lazy(loader) { load = loader; return Symbol('lazy'); } };
  const jsx = { jsx: (type, props) => ({ type, props }) };
  const View = createResetCreditView(React, jsx, resetCreditPresentation);
  let state = { data: { available_count: 99 }, isFetchedAfterMount: false, isError: false };
  let requests = 0;
  const Widget = createSidebarQuota(React, jsx, Symbol('menu'), nativeWindowData,
    async () => { requests++; return () => state; }, View);
  const usage = { account_id: 'current-account', rate_limit_reset_credits: { available_count: 2 } };
  const tree = Widget({ usage });
  assert.equal(requests, 0);
  const suspense = tree.props.children.props.children.find(child => child?.type === React.Suspense);
  assert.equal(suspense.props.children.props.key, 'current-account');
  const query = (await load()).default;
  const cached = query({ usage, now });
  assert.equal(cached.props.response, null);
  assert.equal(cached.props.loading, true);
  assert.equal(cached.props.summaryCount, 2);
  state = { ...state, isFetchedAfterMount: true, data: { available_count: 2, credits: [] } };
  assert.equal(query({ usage, now }).props.response, state.data);
  state = { ...state, isError: true };
  assert.equal(query({ usage, now }).props.response, null);
  assert.equal(query({ usage, now }).props.failed, true);
  createSidebarQuota(React, jsx, Symbol('menu'), nativeWindowData,
    async () => { throw new Error('chunk failed'); }, View);
  assert.equal((await load()).default({ usage, now }).props.failed, true);
});
