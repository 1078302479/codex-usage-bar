import { displayWindow } from './quota.mjs';

export class CodexQuotaWidget extends HTMLElement {
  constructor() {
    super();
    this.attachShadow({ mode: 'open' });
    this.shadowRoot.innerHTML = `<style>
      :host{display:block;width:48px;font:12px 'Segoe UI',sans-serif;color:#30363d}
      button{font:inherit;cursor:pointer;color:inherit} .trigger{width:44px;border:0;border-radius:12px;background:#e9edf180;padding:7px 2px;display:grid;gap:6px}
      .label{font-size:10px;color:#747a83;display:block}.value{font-weight:650;font-size:13px;color:#388653}
      .secondary .value{color:#617c9e}.warning .value{color:#986500}.danger .value{color:#bc3535}
      .trigger:focus-visible{outline:2px solid #527ca7;outline-offset:2px}
      .card{position:fixed;box-sizing:border-box;width:288px;padding:17px;background:#fcfcfd;border:1px solid #dfe2e6;border-radius:14px;box-shadow:0 8px 28px #1923311c;z-index:1000}
      [hidden]{display:none!important} h2{font-size:15px;margin:0 0 16px;font-weight:650}
      .row{display:flex;justify-content:space-between;margin-bottom:7px}.row strong{font-size:16px}
      progress{width:100%;height:5px;appearance:none;border:0;display:block;margin:0 0 7px}
      progress::-webkit-progress-bar{background:#e3e6e9;border-radius:5px}progress::-webkit-progress-value{background:#70aa83;border-radius:5px}
      .secondary progress::-webkit-progress-value{background:#8ca4bf}
      .reset{font-size:11px;color:#777e87;margin:0 0 18px;line-height:1.6}.footer{border-top:1px solid #e6e7eb;padding-top:10px;color:#777e87;font-size:11px}
      @media(prefers-color-scheme:dark){:host{color:#e1e5ea}.trigger{background:#ffffff09}.card{background:#24272d;border-color:#3d424a}.label,.reset,.footer{color:#a7adb7}.value{color:#8bcca0}.secondary .value{color:#a1badd}}
      @media(prefers-reduced-motion:no-preference){.trigger{transition:background .12s}.trigger:hover{background:#bec8d333}}
    </style>
    <button class="trigger" aria-label="查看 Codex 剩余额度和重置时间" aria-expanded="false" aria-controls="details">
      <span class="primary"><span class="label">短期</span><span class="value">--</span></span>
      <span class="secondary"><span class="label">长期</span><span class="value">--</span></span>
    </button>
    <section class="card" id="details" role="region" aria-label="额度详情" hidden>
      <h2>Codex 剩余额度</h2>
      <div class="primary detail"><div class="row"><span class="name"></span><strong></strong></div><progress max="100"></progress><p class="reset"></p></div>
      <div class="secondary detail"><div class="row"><span class="name"></span><strong></strong></div><progress max="100"></progress><p class="reset"></p></div>
      <div class="footer" aria-live="polite">正在连接</div>
    </section>`;
    this.trigger = this.shadowRoot.querySelector('.trigger');
    this.card = this.shadowRoot.querySelector('.card');
    this.trigger.addEventListener('click', () => {
      this.pinned = !this.pinned;
      this.open(this.pinned);
    });
    for (const element of [this.trigger, this.card]) {
      element.addEventListener('mouseenter', () => { clearTimeout(this.closeTimer); this.open(true); });
      element.addEventListener('mouseleave', () => {
        this.closeTimer = setTimeout(() => { if (!this.pinned) this.open(false); }, 200);
      });
    }
    this.trigger.addEventListener('focus', () => this.open(true));
    this.trigger.addEventListener('blur', () => { if (!this.pinned) this.open(false); });
    this.addEventListener('keydown', event => {
      if (event.key === 'Escape') { this.pinned = false; this.open(false); }
    });
    this.reposition = () => { if (!this.card.hidden) this.open(true); };
  }

  connectedCallback() { window.addEventListener('resize', this.reposition); }
  disconnectedCallback() { clearTimeout(this.closeTimer); window.removeEventListener('resize', this.reposition); }

  open(show) {
    this.card.hidden = !show;
    this.trigger.setAttribute('aria-expanded', String(show));
    if (!show) return;
    const rect = this.getBoundingClientRect();
    const width = Math.min(288, innerWidth - 16);
    this.card.style.width = `${width}px`;
    this.card.style.left = `${Math.max(8, Math.min(rect.right + 12, innerWidth - width - 8))}px`;
    this.card.style.top = `${Math.max(8, Math.min(rect.top, innerHeight - this.card.offsetHeight - 8))}px`;
  }

  set state(value) {
    this.currentState = value;
    const { snapshot, error, demo } = value;
    const now = Date.now();
    const messages = { 'login-required': '请先在 Codex 中登录', 'account-changed': '账号变化，等待重新核验',
      'no-quota': '未返回 Codex 额度', timeout: '查询超时', 'connection-failed': '连接失败，稍后自动重试' };
    for (const key of ['primary', 'secondary']) {
      const data = snapshot?.[key];
      const display = data ? displayWindow(data, snapshot, now, Boolean(error)) : { text: '--', tone: 'normal' };
      const compact = this.shadowRoot.querySelector(`.trigger .${key}`);
      compact.className = `${key} ${display.tone}`;
      compact.querySelector('.label').textContent = data?.label ?? (key === 'primary' ? '短期' : '长期');
      compact.querySelector('.value').textContent = display.text;
      const detail = this.shadowRoot.querySelector(`.detail.${key}`);
      detail.querySelector('.name').textContent = `${data?.label ?? (key === 'primary' ? '短期' : '长期')}额度`;
      detail.querySelector('strong').textContent = display.text;
      const progress = detail.querySelector('progress');
      progress.hidden = !data || data.remaining === null || data.resetsAt !== null && data.resetsAt <= now;
      progress.value = data?.remaining ?? 0;
      let reset = '重置时间未知';
      if (data?.resetsAt) {
        if (data.resetsAt <= now) reset = '已到重置时间，等待服务端核验';
        else {
          const formatted = new Intl.DateTimeFormat('zh-CN', { timeZone: 'Asia/Shanghai', month: 'numeric',
            day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }).format(data.resetsAt);
          const mins = Math.ceil((data.resetsAt - now) / 60000);
          const countdown = mins >= 1440 ? `${Math.floor(mins / 1440)}天${Math.floor(mins % 1440 / 60)}小时`
            : `${Math.floor(mins / 60)}小时${mins % 60}分`;
          reset = `重置于 ${formatted}（北京时间） · 还剩${countdown}`;
        }
      }
      detail.querySelector('.reset').textContent = reset;
    }
    this.shadowRoot.querySelector('.footer').textContent = demo ? '示例数据 · 非真实额度'
      : error ? messages[error] ?? '额度暂不可用'
      : snapshot ? `最近核验 ${new Date(snapshot.observedAt).toLocaleTimeString('zh-CN')} · ${displayWindow(snapshot.primary, snapshot, now).state}`
      : '正在连接本机 Codex…';
  }
}
customElements.define('codex-quota-widget', CodexQuotaWidget);

// Host integration is explicit: mounting above the official icon requires a
// real client-provided slot. This module never guesses or patches client DOM.
export function mountQuotaWidget(slot) {
  const widget = document.createElement('codex-quota-widget');
  slot.append(widget);
  return widget;
}
