// Pure display model shared by the browser component and the local reader.
export function quotaWindow(value, fallback, now = Date.now()) {
  const used = value?.usedPercent;
  const remaining = typeof used === 'number' && Number.isFinite(used) && used >= 0 && used <= 100
    ? Math.floor(100 - used) : null;
  const reset = value?.resetsAt;
  const resetsAt = typeof reset === 'number' && reset > 0 && reset <= 253402300799
    ? reset * 1000 : null;
  const mins = value?.windowDurationMins;
  const label = Number.isInteger(mins) && mins > 0
    ? mins === 10080 ? '周' : mins % 1440 === 0 ? `${mins / 1440}d`
      : mins % 60 === 0 ? `${mins / 60}h` : `${mins}m` : fallback;
  return { label, remaining, resetsAt, resetPending: resetsAt !== null && resetsAt <= now };
}

export function normalizeQuota(response, now = Date.now()) {
  // Do not silently display a different product's bucket as Codex.
  const map = response?.rateLimitsByLimitId;
  const bucket = map && Object.keys(map).length ? map.codex : response?.rateLimits;
  if (!bucket) throw new Error('no-quota');
  return {
    observedAt: now,
    primary: quotaWindow(bucket.primary, '短期', now),
    secondary: quotaWindow(bucket.secondary, '长期', now),
  };
}

export function displayWindow(window, snapshot, now = Date.now(), failed = false) {
  const expired = window.resetsAt !== null && window.resetsAt <= now;
  const stale = failed || now - snapshot.observedAt > 300_000;
  return {
    text: expired || window.remaining === null ? '--' : `${window.remaining}%${stale ? '*' : ''}`,
    state: expired ? '等待重置核验' : stale ? '数据已过期' : '已核验',
    tone: window.remaining === null ? 'normal' : window.remaining <= 5 ? 'danger'
      : window.remaining <= 20 ? 'warning' : 'normal',
  };
}
