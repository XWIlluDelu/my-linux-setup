// Exercise the shipped UI logic without a browser or dependencies.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function element() {
  return {
    dataset: {}, style: {}, children: [], innerHTML: '',
    appendChild(child) { this.children.push(child); },
    querySelector() { return element(); },
  };
}
const elements = new Map();
const document = {
  documentElement: element(),
  getElementById(id) {
    if (!elements.has(id)) elements.set(id, element());
    return elements.get(id);
  },
  createElement: element,
  querySelectorAll: () => [],
};
const alerts = [];
const context = vm.createContext({
  document, window: {}, console, Date,
  localStorage: { getItem: () => null, setItem() {} },
  alert: value => alerts.push(value),
  setTimeout() {},
  fetch: async () => ({ ok: true, json: async () => ({ sessions: [] }) }),
});
const html = fs.readFileSync(path.join(__dirname, '../extras/my-ai-tools/claude-session-manager/session-manager.html'), 'utf8');
const source = html.match(/<script>([\s\S]*?)<\/script>/)[1];
vm.runInContext(source.replace('      fetchSessions();', '      globalThis.ui = { state, highlight, render, fetchSessions, deleteSession };'), context);

(async () => {
  const { ui } = context;
  const payload = '<img src=x onerror=alert(1)> & "';
  assert.ok(!ui.highlight(payload).includes('<img'));
  ui.state.searchQuery = 'img';
  assert.ok(ui.highlight(payload).startsWith('&lt;<mark>img</mark>'));
  ui.state.searchQuery = '';

  const session = { sessionId: 'safe-id', recordId: 'claude:safe-id', title: payload, projectPath: payload, firstPrompt: payload, lastPrompt: '', storageBytes: 10, sessionDirStorageBytes: 20, subagentStorageBytes: 15 };
  context.fetch = async () => ({ ok: true, json: async () => ({ sessions: [session] }) });
  await ui.fetchSessions();
  assert.equal(ui.state.sessions[0].totalStorageBytes, 30, 'subagents must not be counted twice');
  ui.state.selectedRecordId = session.recordId;
  ui.render();
  assert.ok(!document.getElementById('drawerScroll').innerHTML.includes('<img'));
  assert.ok(document.getElementById('sessionsBody').children.every(child => !child.innerHTML.includes('<img')));

  context.fetch = async () => ({ ok: false, status: 500, json: async () => ({ error: 'disk failure' }) });
  await ui.deleteSession(session);
  assert.equal(ui.state.sessions.length, 1, 'failed deletion must remain visible');
  assert.ok(alerts.includes('disk failure'));
  context.fetch = async () => ({ ok: true, json: async () => ({ ok: true }) });
  await ui.deleteSession(session);
  assert.equal(ui.state.sessions.length, 0);
  assert.equal(document.getElementById('emptyState').dataset.visible, true);
  console.log('session UI tests: pass');
})().catch(error => { console.error(error); process.exitCode = 1; });
