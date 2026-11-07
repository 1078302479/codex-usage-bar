import { mountQuotaWidget } from './widget.mjs';
const widget = mountQuotaWidget(document.querySelector('#quota-slot'));
let lastState;
let pending = false;
async function update() {
  if (pending) return;
  pending = true;
  try {
    const response = await fetch('/api/quota');
    if (!response.ok) throw new Error('connection-failed');
    lastState = await response.json();
    widget.state = lastState;
    document.querySelector('#mode').textContent = lastState.demo
      ? '演示模式：82% / 64% 均为示例数据。' : '真实数据模式：通过本机 Codex App Server 只读查询。';
  } catch {
    lastState = { snapshot: null, error: 'connection-failed' };
    widget.state = lastState;
    document.querySelector('#mode').textContent = '本地数据服务连接已断开。';
  } finally { pending = false; }
}
void update();
setInterval(update, 15000);
setInterval(() => { if (lastState) widget.state = lastState; }, 1000);
