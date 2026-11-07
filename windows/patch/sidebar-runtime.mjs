// Self-contained functions: serialized into the existing renderer module.
// Credit details use the client's own read-only query hook and account context.
export function nativeWindowData(usage, observedAt, now) {
  const raw = usage?.rate_limit;
  const windows = [raw?.primary_window, raw?.secondary_window].filter(Boolean);
  const invalid = () => ({ label: '--', remaining: null, resetsAt: null, expired: false });
  const normalize = (value, fallback) => {
    if (!value) return { ...invalid(), label: fallback };
    const seconds = value.limit_window_seconds;
    const label = Number.isInteger(seconds) && seconds > 0
      ? seconds === 604800 ? '周' : seconds % 86400 === 0 ? `${seconds / 86400}d`
        : seconds % 3600 === 0 ? `${seconds / 3600}h` : `${Math.round(seconds / 60)}m` : fallback;
    const used = value.used_percent;
    const remaining = typeof used === 'number' && Number.isFinite(used) && used >= 0 && used <= 100
      ? Math.floor(100 - used) : null;
    // Native wham data reset_at is an epoch timestamp in seconds, not a duration.
    const reset = value.reset_at;
    const resetsAt = typeof reset === 'number' && Number.isFinite(reset) && reset > 0 && reset <= 253402300799
      ? reset * 1000 : null;
    return { label, remaining, resetsAt, expired: resetsAt !== null && resetsAt <= now };
  };
  // Preserve native primary/secondary semantics for nonstandard server windows.
  // Weekly-only plans must not accidentally put weekly quota in the short row.
  const weeklyOnly = windows.length === 1 && windows[0].limit_window_seconds === 604800;
  return {
    windows: weeklyOnly ? [normalize(null, '短期'), normalize(windows[0], '周')]
      : [normalize(raw?.primary_window, '短期'), normalize(raw?.secondary_window, '长期')],
    stale: !Number.isFinite(observedAt) || now - observedAt > 300000,
    available: Boolean(raw),
  };
}

export function createSidebarQuota(React, jsx, Popover, model, loadResetCreditsHook = null, ResetCreditView = null, display = null) {
  const h = jsx.jsx;
  const showShort = display?.showShort !== false;
  const showWeekly = display?.showWeekly !== false;
  const hasQuota = showShort || showWeekly;
  const showResetTimes = hasQuota && display?.showResetTimes !== false;
  const showCredits = display?.showResetCredits !== false && Boolean(ResetCreditView);
  if (!hasQuota && !showCredits) return function HiddenUsageBar() { return null; };
  function locateResetHeading(title) {
    const labels = new Set([title, '使用限额重置', 'Usage limit resets'].filter(Boolean));
    let attempts = 0;
    const timer = setInterval(() => {
      const heading = [...document.querySelectorAll('span[tabindex="-1"]')].find(element =>
        labels.has(element.textContent?.trim()) && element.getClientRects().length > 0);
      if (heading || ++attempts >= 50) clearInterval(timer);
      if (heading) {
        heading.scrollIntoView({ block: 'center' });
        heading.focus({ preventScroll: true });
      }
    }, 100);
  }
  const creditProps = (usage, now) => ({
    summaryCount: usage?.rate_limit_reset_credits?.available_count, now, expandCards: display?.expandCards !== false,
  });
  const makeCreditsQuery = () => showCredits && loadResetCreditsHook ? React.lazy(async () => {
    try {
      const useCredits = await loadResetCreditsHook();
      if (typeof useCredits !== 'function') throw new Error('Reset-credit query unavailable');
      return { default: function NativeResetCredits({ usage, now, onRetry, onUseReset }) {
        const query = useCredits();
        const status = query.error?.status ?? query.error?.statusCode ?? query.error?.response?.status;
        // Cached rows are shown only after a read for this mounted account.
        const ready = query.isFetchedAfterMount === true && !query.isPlaceholderData && !query.isError;
        return h(ResetCreditView, { ...creditProps(usage, now), response: ready ? query.data : null,
          loading: !ready && !query.isError, failed: Boolean(query.isError), failureReason: 'query',
          errorStatus: Number.isInteger(status) && status >= 400 && status <= 599 ? status : null, onRetry, onUseReset });
      } };
    } catch (error) {
      const failureReason = error?.message === 'reset-credit-runtime-dependency' ? 'runtime-dependency' : 'module-load';
      return { default: function UnavailableResetCredits({ usage, now, onRetry, onUseReset }) {
        return h(ResetCreditView, { ...creditProps(usage, now), response: null, failed: true, failureReason, onRetry, onUseReset });
      } };
    }
  }) : null;
  const initialCreditsQuery = makeCreditsQuery();
  return function UsageBarSidebar({ usage, onManageUsage, resetHeading }) {
    const [now, setNow] = React.useState(() => Date.now());
    const [open, setOpen] = React.useState(false);
    const onUseReset = typeof onManageUsage === 'function' ? () => {
      setOpen(false);
      onManageUsage();
      locateResetHeading(resetHeading);
    } : undefined;
    const [, setRetryGeneration] = React.useState(0);
    const creditComponent = React.useRef(initialCreditsQuery);
    const CreditsQuery = creditComponent.current;
    const retryCredits = () => {
      creditComponent.current = makeCreditsQuery();
      setRetryGeneration(value => value + 1);
    };
    const seen = React.useRef({ usage, at: Date.now() });
    // Treat a changed native snapshot as newly observed, not a verified network read.
    if (seen.current.usage !== usage) seen.current = { usage, at: Date.now() };
    React.useEffect(() => {
      const timer = setInterval(() => setNow(Date.now()), 1000);
      return () => clearInterval(timer);
    }, []);
    const data = model(usage, seen.current.at, now);
    const windows = data.windows.map((window, index) => ({ ...window, index }))
      .filter(window => window.index === 0 ? showShort : showWeekly);
    const text = window => window.remaining === null || window.expired ? '--'
      : `${window.remaining}%${data.stale ? '*' : ''}`;
    const tone = (window, index) => window.remaining !== null && window.remaining <= 5 ? '#c94545'
      : window.remaining !== null && window.remaining <= 20 ? '#a47518'
        : index === 0 ? '#478562' : '#6989ae';
    const resetParts = window => {
      if (window.expired) return ['已到重置时间，等待客户端更新'];
      if (!window.resetsAt) return ['重置时间未知'];
      const date = new Intl.DateTimeFormat('zh-CN', { timeZone: 'Asia/Shanghai',
        month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }).format(window.resetsAt);
      const minutes = Math.max(0, Math.ceil((window.resetsAt - now) / 60000));
      const remaining = minutes >= 1440 ? `${Math.floor(minutes / 1440)}天${Math.floor(minutes % 1440 / 60)}小时`
        : `${Math.floor(minutes / 60)}小时${minutes % 60}分`;
      return [`重置于 ${date}`, `还剩${remaining}`];
    };
    const details = h('div', { className: 'px-row-x py-row-y text-sm text-default text-start',
      children: [h('div', { key: 'heading', className: 'mb-4 flex items-center justify-between gap-3', children: [
        h('span', { key: 'title', id: 'usagebar-quota-heading', className: 'font-medium', children: hasQuota ? 'Codex 剩余额度' : 'Codex 重置卡' }),
        showResetTimes || showCredits ? h('span', { key: 'zone', className: 'text-xs text-secondary', children: '北京时间' }) : null,
      ] }),
        ...windows.map(window => h('div', { key: window.index, className: 'mb-4', children: [
          h('div', { key: 'row', className: 'mb-1.5 flex items-center justify-between gap-3', children: [
            h('span', { key: 'label', children: `${window.label}额度` }),
            h('span', { key: 'remaining', className: 'font-medium tabular-nums', children: text(window) }),
          ] }),
          window.remaining !== null && !window.expired ? h('div', { key: 'track', className: 'mb-1.5 h-1 overflow-hidden rounded-full bg-surface-secondary', children:
            h('div', { className: 'h-full rounded-full bg-text', style: { width: `${window.remaining}%` } }) }) : null,
          showResetTimes ? h('div', { key: 'reset', className: 'flex flex-wrap items-center justify-between gap-x-3 gap-y-1 text-xs text-secondary leading-relaxed',
            children: resetParts(window).map((part, index) => h('span', { key: index, style: { whiteSpace: 'nowrap' }, children: part })) }) : null,
        ] })),
        CreditsQuery ? h(React.Suspense, { key: 'credits', fallback: h(ResetCreditView, { ...creditProps(usage, now), response: null, loading: true, onUseReset }),
          children: h(CreditsQuery, { key: usage?.account_id ?? usage?.user_id ?? 'current', usage, now, onRetry: retryCredits, onUseReset }) })
          : showCredits ? h(ResetCreditView, { key: 'credits', ...creditProps(usage, now), response: null, onUseReset }) : null,
        hasQuota && (!data.available || data.stale) ? h('div', { key: 'footer', className: 'border-t border-default pt-2 text-xs text-secondary',
          children: !data.available ? '客户端尚未提供额度数据' : '数据超过5分钟未更新 · * 标记旧值' }) : null,
      ] });
    const trigger = h('button', { type: 'button', 'data-usagebar-sidebar': '1',
      'aria-label': hasQuota ? `Codex 剩余额度：${windows.map(w => `${w.label} ${text(w)}`).join('，')}。悬停查看详情` : 'Codex 重置卡，悬停查看详情',
        style: { display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 7, width: 44,
          padding: '7px 2px', border: 0, borderRadius: 10, background: 'var(--color-surface-hover, #9099a310)',
          cursor: 'default', lineHeight: 1.2, fontFamily: 'inherit', fontVariantNumeric: 'tabular-nums', flexShrink: 0 },
        children: hasQuota ? windows.map(window => h('span', { key: window.index, style: { display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 2 }, children: [
          h('span', { key: 'label', style: { fontSize: 9, color: 'var(--color-text-secondary, #888)' }, children: window.label }),
          h('span', { key: 'value', style: { fontSize: 12, fontWeight: 600, color: tone(window, window.index) }, children: text(window) }),
        ] })) : h('span', { style: { fontSize: 9, color: 'var(--color-text-secondary, #888)' }, children: '重置卡' }),
      });
    // Match the existing rail menu's surface, width, spacing and theme. The
    // native hover implementation handles pointer travel and keyboard dismissal.
    return h(Popover, { triggerButton: trigger, open, onOpenChange: setOpen, openOnHover: true, modal: false,
      align: 'end', side: 'right', contentWidth: 'menuReadout', size: 'compact', surface: 'menu',
      contentStyle: { width: 'max-content', maxWidth: 'min(400px, calc(100vw - 88px), var(--radix-dropdown-menu-content-available-width, 400px))' },
      contentRole: 'dialog', contentAriaLabelledBy: 'usagebar-quota-heading',
      onOpenAutoFocus: event => event.preventDefault(),
      children: details,
    });
  };
}
