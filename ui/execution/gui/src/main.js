import { createBridge } from './bridge.js';
import { assertContract } from './validate.js';
const status = document.querySelector('#status');
const progress = document.querySelector('progress');
const timeline = document.querySelector('#timeline');

async function start() {
  const bridge = createBridge();
  globalThis.__pizzaDeliverEvents = (events) => {
    bridge.deliver(events);
    void bridge.request('ready', bridge.lastSequence);
  };
  globalThis.__pizzaBridgeError = (message) => {
    status.textContent = message;
  };
  globalThis.__pizzaExecutionState = (value) => {
    const state = assertContract('Execution', value);
    document.documentElement.dataset.executionStatus = state.status;
    const labels = {
      view_only: '只读查看',
      running: '正在模拟执行',
      succeeded: '模拟计划完成',
      failed: '步骤失败，计划已停止',
      hung: '模拟步骤挂起，尚未完成',
      degraded: '日志不可持久化，执行已停止',
      interrupted: '上次执行中断，需要人工处理',
    };
    status.textContent = `${labels[state.status]} · ${state.committed}/${state.total} · ${state.message}`;
    progress.value = state.committed;
  };
  assertContract('Health', await bridge.request('health'));
  const context = assertContract('Context', await bridge.request('context'));
  const plan = await bridge.request('plan');
  status.textContent = `${context.corpus === 'maint' ? '维护环境' : '应用会话'} · 本地原生连接`;
  progress.hidden = plan === null;
  if (context.capabilities.includes('journal-degraded'))
    status.textContent += ' · 日志尾部损坏，仅显示有效记录';
  if (plan === null) {
    status.textContent += ' · 等待加载维护计划';
  } else {
    assertContract('Plan', plan);
    progress.max = plan.steps.length;
  }
  const commits = new Set();
  await bridge.subscribe((entry) => {
    const item = document.createElement('li');
    item.textContent = `${entry.seq} · ${entry.phase} · ${entry.message}`;
    timeline.append(item);
    while (timeline.childElementCount > 256) timeline.firstElementChild.remove();
    if (entry.phase === 'commit' && entry.step_id > 0) commits.add(entry.step_id);
    progress.value = commits.size;
  });
  globalThis.__pizzaExecutionState(await bridge.request('execution'));
  await bridge.request('ready', bridge.lastSequence);
}
start().catch((error) => {
  status.textContent = `界面连接失败：${error.message}`;
});
