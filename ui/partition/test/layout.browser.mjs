// Runs entirely against a local fixture: no host authorization or disk access.
// PIZZA_PLAYWRIGHT_MODULE may point to an existing playwright-core installation.
// PIZZA_CHROMIUM_EXECUTABLE selects a locally installed Chromium binary.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import { fileURLToPath } from 'node:url';
const {CONTRACT}=await import(new URL('../../../zig-out/share/pizza/protocol/contract.js',import.meta.url));
const PROTOCOL_VERSION=CONTRACT['x-pizza'].version;
const { chromium } = await import(process.env.PIZZA_PLAYWRIGHT_MODULE || 'playwright-core');
const root = fileURLToPath(new URL('../../../', import.meta.url));
const SIZES = [
  [1861, 969],
  [1440, 960],
  [1280, 720],
  [1140, 615],
  [1024, 600],
  [960, 540],
  [768, 640],
  [390, 844],
  [600, 400],
  [320, 568],
  [800, 360],
];
const captures = process.env.PIZZA_LAYOUT_CAPTURES;
if (captures) await fs.mkdir(captures, { recursive: true });
const server = http.createServer(async (req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  if (path === '/webui.js') {
    res.setHeader('Content-Type', 'text/javascript');
    res.end('');
    return;
  }
  const file =
    path === '/protocol/contract.js'
      ? root + 'zig-out/share/pizza/protocol/contract.js'
      : root + 'ui/partition/prototype' + (path === '/' ? '/index.html' : path);
  try {
    const body = await fs.readFile(file);
    res.setHeader(
      'Content-Type',
      {
        html: 'text/html',
        js: 'text/javascript',
        css: 'text/css',
        svg: 'image/svg+xml',
        ttf: 'font/ttf',
      }[file.split('.').pop()] || 'application/octet-stream',
    );
    res.end(body);
  } catch {
    res.writeHead(404);
    res.end();
  }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const BASE = `http://127.0.0.1:${server.address().port}`;
let browser;
const ERRORS = [];
let checks = 0;
async function matrix(page, name, selector) {
  for (const [width, height] of SIZES) {
    await page.setViewportSize({ width, height });
    await page.evaluate(async () => {
      await document.fonts.ready;
      await Promise.allSettled(
        document
          .querySelector('#app .page')
          .getAnimations()
          .map((a) => a.finished),
      );
      await new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    });
    const bounds = await page.evaluate((selector) => {
      const rect = (el) => el.getBoundingClientRect().toJSON();
      const region = document.querySelector(selector);
      return {
        width: document.documentElement.scrollWidth,
        height: document.documentElement.scrollHeight,
        region: rect(region),
        nav: [
          ...document.querySelectorAll(
            '.page-nav button:not([hidden]),.page-nav a,.welcome .primary,.scene-actions .primary',
          ),
        ].map(rect),
      };
    }, selector);
    assert.ok(bounds.width <= width, `${name} ${width}×${height}: horizontal document overflow`);
    assert.ok(bounds.height <= height, `${name} ${width}×${height}: vertical document overflow`);
    assert.ok(
      bounds.region.height >= 40,
      `${name} ${width}×${height}: collapsed content ${JSON.stringify(bounds)}`,
    );
    for (const button of bounds.nav) {
      assert.ok(
        button.left >= 0 && button.right <= width && button.top >= 0 && button.bottom <= height,
        `${name} ${width}×${height}: navigation outside window`,
      );
    }
    if (await page.locator('.review-content').count()) {
      const layout = await page.evaluate(() => {
        const content = document.querySelector('.review-content'),
          mini = document.querySelector('.review-mini');
        content.scrollTop = content.scrollHeight;
        const note = content.querySelector('.review-boundary').getBoundingClientRect(),
          r = content.getBoundingClientRect(),
          s = mini.getBoundingClientRect();
        return {
          lastVisible: note.bottom <= r.bottom + 1,
          separated: s.bottom <= r.top + 1 || s.left >= r.right - 1,
        };
      });
      assert.ok(layout.lastVisible, `${name}: Undo notice cannot be reached`);
      assert.ok(layout.separated, `${name}: summary overlaps change list`);
      await page.locator('.review-content').evaluate((el) => (el.scrollTop = 0));
    }
    if (
      captures &&
      [
        [1861, 969],
        [390, 844],
        [600, 400],
      ].some(([w, h]) => w === width && h === height)
    )
      await page.screenshot({ path: `${captures}/${name}-${width}x${height}.png` });
    if (await page.locator('.scene-art').count()) {
      const art = await page.locator('.scene-art').boundingBox();
      assert.ok(art.height >= 40, `${name}: illustration collapsed`);
    }
    checks++;
  }
}
async function fixture(kind) {
  const context = await browser.newContext({
    acceptDownloads: true,
    ...(kind === 'authorization' ? { viewport: { width: 1280, height: 900 } } : {}),
  });
  const page = await context.newPage();
  page.on('pageerror', (e) => ERRORS.push(e.stack));
  await page.addInitScript(({kind,version,label}) => {
    const gib = 1073741824n,
      id = 'b'.repeat(64),
      digest = 'd'.repeat(64);
    const disk = {
      path: '/dev/pizza-ui-fixture',
      identity: 'a'.repeat(64),
      capacity: String(20n * gib),
      sector_size: 512,
      model: 'UI fixture only',
      partition_table: 'gpt',
      usable_offset: '1048576',
      usable_length: String(20n * gib - 2097152n),
      read_only: false,
      diagnostics: [],
      partitions: [
        {
          path: '/dev/pizza-ui-fixture1',
          id,
          offset: '1048576',
          length: String(8n * gib),
          name: label,
          filesystem: 'ext4',
          encryption: 'none',
          protected: false,
          mountpoints: [],
          capabilities: ['label', 'resize', 'format', 'delete'].map((operation) => ({
            operation,
            support: 'available',
            backend: 'host',
          })),
        },
      ],
    };
    const snapshot = {
      version,
      snapshot_id: 'c'.repeat(64),
      platform: 'linux',
      disks: [disk],
      diagnostics: [],
    };
    if (kind === 'authorization')
      snapshot.disks = Array.from({ length: 8 }, (_, i) => ({
        ...structuredClone(disk),
        path: disk.path + (i ? '-' + i : ''),
        identity: String(i).repeat(64),
      }));
    globalThis.fixture = { kind, status: 'running', calls: [], pendingInventory: [] };
    globalThis.webui = {
      isConnected() {
        return true;
      },
      async call(binding, payload) {
        if (binding === 'pizza_session')
          return JSON.stringify(
            kind === 'connection'
              ? {
                  error: 'fixture_unavailable',
                  message: 'The local fixture is unavailable. Retry the connection.',
                }
              : { version, writes_enabled: true, formats: ['ext4'] },
          );
        const req = JSON.parse(payload);
        fixture.calls.push(req);
        if (req.action === 'inventory') {
          if (fixture.failInventory) throw Error('Simulated inventory read failure.');
          const result = structuredClone(snapshot);
          if (kind === 'authorization' && !req.elevated && !fixture.authorized)
            for (const d of result.disks) {
              delete d.partition_table;
              delete d.usable_offset;
              delete d.usable_length;
            }
          if (fixture.reverseDisks) result.disks.reverse();
          if (fixture.removeDisk)
            result.disks = result.disks.filter((d) => d.path !== fixture.removeDisk);
          if (fixture.deferNextInventory) {
            fixture.deferNextInventory = false;
            await new Promise((resolve) => fixture.pendingInventory.push(resolve));
          }
          if (req.elevated) fixture.authorized = true;
          return JSON.stringify(result);
        }
        if (binding === 'pizza_plan' || req.action === 'validate') {
          // Presentation-only fixture: domain rules are exercised by Zig tests.
          // The bridge returns a layout supplied by this explicit UI scenario.
          if (binding === 'pizza_plan') {
            const layout=req.layout ?? disk.partitions.map((p)=>({id:p.id,offset:p.offset,length:p.length,name:p.name,filesystem:p.filesystem,retain_data:true}));
            const draft={version,snapshot_id:snapshot.snapshot_id,disk_identity:req.disk_identity,layout,intents:[]};
            if (!req.review) return JSON.stringify({version,draft,regions:layout.map((p)=>({...disk.partitions.find((old)=>old.id===p.id),...p}))});
            req.draft=draft;
          }
          const count = kind === 'empty' ? 0 : kind === 'crowded' ? 30 : 3;
          const validated={
            version,
            digest,
            executable: kind === 'changes',
            draft: req.draft,
            operations: Array.from({ length: count }, (_, i) => ({
              kind: i === 0 ? 'format' : 'resize',
              partition_id: id,
              length: String(8n * gib),
            })),
            diagnostics:
              kind === 'crowded'
                ? Array.from({ length: 8 }, () => ({
                    severity: 'error',
                    code: 'fixture_validation_message',
                    message:
                      'Validation fixture: ' +
                      'A long diagnostic that must remain readable and scrollable. '.repeat(12),
                  }))
                : [],
            destructive_partitions: count ? [id] : [],
          };
          return JSON.stringify(binding === 'pizza_plan' ? {version,draft:req.draft,validated,regions:req.draft.layout.map((p)=>({...disk.partitions.find((old)=>old.id===p.id),...p}))} : validated);
        }
        if (fixture.status === 'disconnected')
          throw Error('Simulated execution connection failure.');
        return JSON.stringify({
          version,
          id: 'e'.repeat(64),
          plan_digest: digest,
          status: fixture.status,
          completed: fixture.status === 'succeeded' ? 3 : 1,
          total: 3,
          message:
            fixture.status === 'failed'
              ? 'Stopped after a partially completed step. ' +
                'Review the durable report before creating another plan. '.repeat(12)
              : 'UI fixture execution status; no disk operation was requested.',
        });
      },
    };
  }, {kind,version:PROTOCOL_VERSION,label:String.fromCodePoint(0x4e00+Math.floor(Math.random()*256))+crypto.randomUUID().slice(0,8)});
  await page.goto(BASE);
  return { page, context };
}
try {
  browser = await chromium.launch({
    headless: true,
    ...(process.env.PIZZA_CHROMIUM_EXECUTABLE
      ? { executablePath: process.env.PIZZA_CHROMIUM_EXECUTABLE }
      : {}),
  });
  // Authorization and refresh must update data without remounting the page,
  // resetting disclosures/scroll/focus or replaying its opacity animation.
  {
    const { page, context } = await fixture('authorization');
    await page.locator('#open-disk').click();
    await page.evaluate(() => (globalThis.originalEditor = document.querySelector('.edit-page')));
    await page.locator('#read-details').click();
    await page.locator('#review:not([disabled])').waitFor();
    assert.equal(
      await page.evaluate(() => originalEditor === document.querySelector('.edit-page')),
      true,
    );
    await page.locator('#disks').click();
    await page.locator('[data-disk="3"]').click();
    await page.evaluate(() => {
      const list = document.querySelector('.disk-list'),
        card = document.querySelector('.disk-card.selected'),
        details = document.querySelector('.disk-detail');
      details.open = false;
      list.scrollTop = 150;
      globalThis.originalView = {
        page: document.querySelector('.disk-page'),
        list,
        card,
        icon: card.querySelector('svg'),
        details,
        scroll: list.scrollTop,
      };
      fixture.deferNextInventory = true;
    });
    await page.locator('#refresh').click();
    await page.waitForFunction(() => fixture.pendingInventory.length === 1);
    assert.equal(
      await page.evaluate(
        () =>
          originalView.page === document.querySelector('.disk-page') &&
          getComputedStyle(originalView.page).opacity === '1',
      ),
      true,
    );
    await page.evaluate(() => fixture.pendingInventory.shift()());
    await page.locator('#refresh:not([disabled])').waitFor();
    assert.deepEqual(
      await page.evaluate(() => ({
        page: originalView.page === document.querySelector('.disk-page'),
        card: originalView.card === document.querySelector('.disk-card.selected'),
        icon: originalView.icon === document.querySelector('.disk-card.selected svg'),
        details: originalView.details === document.querySelector('.disk-detail'),
        open: originalView.details.open,
        scroll: originalView.list.scrollTop === originalView.scroll,
        focus: document.activeElement.id === 'refresh',
        elevated: fixture.calls.filter((r) => r.action === 'inventory').at(-1).elevated,
      })),
      {
        page: true,
        card: true,
        icon: true,
        details: true,
        open: false,
        scroll: true,
        focus: true,
        elevated: true,
      },
    );
    await page.evaluate(() => (fixture.failInventory = true));
    await page.locator('#refresh').click();
    await page.locator('.toast.visible').waitFor();
    assert.equal(
      await page.evaluate(
        () =>
          originalView.page === document.querySelector('.disk-page') &&
          originalView.card.isConnected,
      ),
      true,
    );
    await page.evaluate(() => {
      fixture.failInventory = false;
      fixture.reverseDisks = true;
    });
    await page.locator('#refresh').click();
    await page.locator('#refresh:not([disabled])').waitFor();
    assert.equal(
      await page.evaluate(
        () => originalView.card === document.querySelector('.disk-card.selected'),
      ),
      true,
    );
    assert.equal(await page.locator('.disk-card.selected').getAttribute('data-disk'), '4');
    await page.evaluate(() => (fixture.removeDisk = originalView.card.dataset.key));
    await page.locator('#refresh').click();
    await page.locator('#refresh:not([disabled])').waitFor();
    assert.equal(await page.locator('.disk-card').count(), 7);
    assert.equal(await page.locator('.disk-card.selected').count(), 1);
    await context.close();
  }
  {
    const { page, context } = await fixture('authorization');
    await page.locator('#open-disk').click();
    await page.evaluate(() => (fixture.deferNextInventory = true));
    await page.locator('#read-details').click();
    await page.waitForFunction(() => fixture.pendingInventory.length === 1);
    await page.locator('#disks').click();
    await page.locator('[data-disk="3"]').click();
    await page.evaluate(() => {
      globalThis.originalDiskPage = document.querySelector('.disk-page');
      fixture.deferNextInventory = true;
    });
    await page.locator('#refresh').click();
    await page.waitForFunction(() => fixture.pendingInventory.length === 2);
    // Administrator read wins even when an older, unprivileged refresh returns later.
    await page.evaluate(() => fixture.pendingInventory.shift()());
    await page.waitForFunction(() =>
      document.querySelector('.disk-card.selected small').textContent.startsWith('GPT'),
    );
    await page.evaluate(() => fixture.pendingInventory.shift()());
    await page.locator('#refresh:not([disabled])').waitFor();
    assert.equal(
      await page.evaluate(() => originalDiskPage === document.querySelector('.disk-page')),
      true,
    );
    assert.match(await page.locator('.disk-card.selected .disk-name').textContent(), /-3$/);
    assert.match(await page.locator('.disk-card.selected small').textContent(), /^GPT/);
    assert.equal(await page.locator('.edit-page').count(), 0);
    await context.close();
  }
  for (const kind of ['empty', 'changes', 'crowded']) {
    const { page, context } = await fixture(kind);
    await page.locator('#open-disk').click();
    await page.locator('#review').click();
    await page.locator('.review-page').waitFor();
    assert.equal(await page.locator('#execute').isDisabled(), kind !== 'changes');
    await matrix(page, 'review-' + kind, '.review-content');
    // Export must still produce the exact draft, rather than display-rounded data.
    const download = page.waitForEvent('download');
    await page.locator('#export').click();
    const saved = JSON.parse(await fs.readFile(await (await download).path(), 'utf8'));
    assert.equal(saved.version, PROTOCOL_VERSION);
    assert.equal(typeof saved.layout[0].length, 'string');
    if (kind === 'changes') {
      await page.locator('#execute').click();
      await page.locator('#execution-progress').waitFor();
      await matrix(page, 'execution-running', '.status-workspace');
      await page.evaluate(() => (fixture.status = 'failed'));
      await page.getByRole('heading', { name: 'Review the result.' }).waitFor();
      await matrix(page, 'execution-failed', '.status-workspace');
      assert.equal(await page.locator('#execution-report').isVisible(), true);
      assert.equal(
        await page.evaluate(() => fixture.calls.filter((r) => r.action === 'execute').length),
        1,
      );
    }
    await context.close();
  }
  const { page: offline, context: offline_context } = await fixture('connection');
  await offline.locator('.connection-page').waitFor();
  await matrix(offline, 'connection', '.workspace');
  await offline_context.close();
  const { page: disconnected, context: disconnected_context } = await fixture('changes');
  await disconnected.locator('#open-disk').click();
  await disconnected.locator('#review').click();
  await disconnected.locator('#execute').click();
  await disconnected.locator('#execution-progress').waitFor();
  await disconnected.evaluate(() => (fixture.status = 'disconnected'));
  await disconnected.locator('#reconnect-execution').waitFor();
  await matrix(disconnected, 'execution-reconnect', '.workspace');
  await disconnected_context.close();
  const context = await browser.newContext();
  const demo = await context.newPage();
  demo.on('pageerror', (e) => ERRORS.push(e.stack));
  await demo.goto(BASE + '/?demo=1');
  await demo.locator('.welcome').waitFor();
  await matrix(demo, 'welcome', '.welcome');
  await demo.getByRole('button', { name: /Get Started/ }).click();
  await matrix(demo, 'disk', '.disk-list');
  await demo.locator('[data-go="edit"]').click();
  await matrix(demo, 'editor', '.editor-pizza');
  await demo.locator('[data-go="review"]').click();
  await matrix(demo, 'review-demo', '.review-content');
  await demo.locator('[data-go="progress"]').click();
  await demo.locator('.progress-view').waitFor();
  await matrix(demo, 'progress', '.progress-view');
  await demo.locator('.done').waitFor();
  await matrix(demo, 'done', '.done');
  await context.close();
  assert.deepEqual(ERRORS, []);
  console.log(
    `PASS: ${checks} viewport/state checks; review empty/changes/long diagnostics, export, execution, reconnect and all demo screens. No disk APIs used.`,
  );
} finally {
  await browser?.close();
  server.close();
}
