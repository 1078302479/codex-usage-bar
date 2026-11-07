// Normalize only server-supplied reset-credit fields. Summary counts and missing
// dates are kept separate, matching the macOS app's completeness rules.
export function resetCreditPresentation(response, summaryCount, now) {
  const countOf = value => Number.isSafeInteger(value) && value >= 0 ? value : null;
  const count = countOf(response?.available_count) ?? countOf(summaryCount);
  const rows = Array.isArray(response?.credits) ? response.credits : null;
  const timestamp = value => {
    if (typeof value === 'number' && Number.isFinite(value) && value > 0 && value <= 253402300799) return value * 1000;
    if (typeof value !== 'string' || !/^\d{4}-\d\d-\d\dT.*(?:Z|[+-]\d\d:\d\d)$/.test(value)) return null;
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : null;
  };
  const groups = new Map();
  for (const row of rows ?? []) {
    if (!row || typeof row.id !== 'string' || !row.id) continue;
    const current = groups.get(row.id);
    const normalized = { id: row.id, status: row.status, resetType: row.reset_type ?? null,
      expiresAt: timestamp(row.expires_at), title: typeof row.title === 'string' ? row.title.trim() : '' };
    const fingerprint = JSON.stringify(normalized);
    if (!current) groups.set(row.id, { row: normalized, fingerprint, conflict: false });
    else if (current.fingerprint !== fingerprint) current.conflict = true;
  }
  const cards = count === 0 ? [] : [...groups.values()]
    .filter(value => !value.conflict && value.row.status === 'available'
      && (value.row.resetType === null || ['codexRateLimits', 'codex_rate_limits'].includes(value.row.resetType)))
    .map(value => value.row)
    .sort((left, right) => (left.expiresAt ?? Infinity) - (right.expiresAt ?? Infinity) || left.id.localeCompare(right.id));
  const future = cards.filter(card => card.expiresAt !== null && card.expiresAt > now);
  const expiring = future.filter(card => card.expiresAt <= now + 72 * 3600000).length;
  const complete = count !== null && rows !== null && cards.length === count
    && cards.every(card => card.expiresAt !== null && card.expiresAt > now);
  return { count, cards, complete, expiring, earliest: future[0]?.expiresAt ?? null, detailsReturned: rows !== null };
}

export function createResetCreditView(React, jsx, model) {
  const h = jsx.jsx;
  return function ResetCreditView({ response, summaryCount, now, loading, failed, failureReason, errorStatus, onRetry, onUseReset, expandCards = true }) {
    const [expanded, setExpanded] = React.useState(expandCards);
    const data = model(response, summaryCount, now);
    const useButton = () => h('button', { key: 'use', type: 'button', onClick: onUseReset,
      'aria-label': '使用重置卡，打开使用限额重置设置',
      className: 'shrink-0 rounded-lg bg-surface-secondary px-2 py-1 text-xs font-medium text-default', children: '使用' });
    const formatDate = time => new Intl.DateTimeFormat('zh-CN', { timeZone: 'Asia/Shanghai',
      year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hour12: false }).format(time);
    const countdown = time => {
      if (time <= now) return '已到期，待核验';
      const minutes = Math.ceil((time - now) / 60000);
      return `${Math.floor(minutes / 1440)}天 ${Math.floor(minutes % 1440 / 60)}小时 ${minutes % 60}分钟后到期`;
    };
    const status = loading ? '正在读取卡片明细…' : failed
      ? failureReason === 'module-load' ? '重置卡组件加载失败'
        : failureReason === 'runtime-dependency' ? '重置卡组件依赖未就绪'
          : `重置卡明细查询失败${errorStatus ? `（HTTP ${errorStatus}）` : ''}`
      : !data.detailsReturned ? '服务暂未返回卡片到期明细'
        : data.count === 0 ? '当前没有可用重置卡'
          : data.cards.length === 0 ? '尚无可用的到期明细' : null;
    return h('section', { className: 'border-t border-default pt-4', 'aria-label': '重置卡', children: [
      h('div', { key: 'header', className: 'mb-3 flex items-center justify-between gap-3 font-medium', children: [
        h('span', { key: 'title', children: '重置卡' }),
        h('div', { key: 'count', className: 'flex items-center gap-2 tabular-nums', children: [
          data.count === null ? '数量待确认' : `可用 ${data.count} 张`,
          onUseReset && data.count > 0 && (!expanded || data.cards.length === 0) ? useButton() : null,
        ] }),
      ] }),
      status ? h('p', { key: 'status', className: 'mb-3 text-xs text-secondary', role: failed ? 'status' : undefined, children: status }) : null,
      failed && onRetry ? h('button', { key: 'retry', type: 'button', className: 'mb-3 text-xs text-secondary hover:text-default',
        onClick: onRetry, children: '重试' }) : null,
      !loading && !failed && data.count !== 0 ? h('div', { key: 'expiring', className: 'mb-3 flex items-center justify-between gap-3 text-xs text-secondary', children: [
        h('span', { key: 'label', children: '未来 72 小时内' }),
        h('span', { key: 'value', className: data.expiring > 0 ? 'text-warning' : 'text-secondary', children:
          data.complete ? `3天内到期 ${data.expiring} 张` : data.expiring > 0 ? `已知 ${data.expiring} 张到期` : '到期数量待确认' }),
      ] }) : null,
      data.earliest !== null ? h('div', { key: 'earliest', className: 'mb-3 rounded-lg border border-default bg-surface-secondary p-3', children: [
        h('div', { key: 'countdown', className: `mb-1 font-medium tabular-nums${data.earliest - now <= 86400000 ? ' text-warning' : ''}`, children: countdown(data.earliest) }),
        h('div', { key: 'date', className: 'text-xs text-secondary', children: `${formatDate(data.earliest)} 到期（北京时间）` }),
      ] }) : null,
      data.cards.length > 0 ? h('button', { key: 'toggle', type: 'button', className: 'mb-2 text-xs text-secondary hover:text-default',
        'aria-expanded': expanded, onClick: () => setExpanded(!expanded), children: expanded ? '卡片明细 ▴' : '卡片明细 ▾' }) : null,
      expanded && data.cards.length > 0 ? h('div', { key: 'cards', className: 'rounded-lg border border-default', style: { maxHeight: 220, overflowY: 'auto' }, children:
        data.cards.map((card, index) => h('div', { key: card.id, className: `px-3 py-2${index > 0 ? ' border-t border-default' : ''}`, children: [
          h('div', { key: 'title', className: 'mb-1 flex items-center justify-between gap-2 text-xs font-medium',
            children: [card.title || `重置卡 ${index + 1}`, onUseReset ? useButton() : null] }),
          h('div', { key: 'expiry', className: 'flex flex-wrap justify-between gap-x-3 gap-y-1 text-xs text-secondary tabular-nums', children: [
            h('span', { key: 'date', style: { whiteSpace: 'nowrap' }, children: card.expiresAt === null ? '到期时间未返回' : formatDate(card.expiresAt) }),
            h('span', { key: 'remaining', style: { whiteSpace: 'nowrap' }, children: card.expiresAt === null ? '待确认' : countdown(card.expiresAt) }),
          ] }),
        ] })) }) : null,
      data.detailsReturned && data.count !== null && data.count > data.cards.length ? h('p', {
        key: 'partial', className: 'mt-2 text-xs text-secondary', children: '部分卡片明细未返回，以上仅统计已知到期时间' }) : null,
    ] });
  };
}
