// Drives the real frontend in Chromium against fixtures only: the demo backend
// and a stubbed WebUI bridge. It never reaches the native backend or a disk.
// PIZZA_PLAYWRIGHT_MODULE may point to an existing playwright-core installation,
// PIZZA_CHROMIUM_EXECUTABLE to a Chromium binary, PIZZA_LAYOUT_CAPTURES to a
// directory that receives screenshots.
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import http from 'node:http';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../../../', import.meta.url));
const contract = root + 'zig-out/share/pizza/protocol/contract.js';
const { CONTRACT } = await import(contract);
const VERSION = CONTRACT['x-pizza'].version;
const { chromium } = await import(process.env.PIZZA_PLAYWRIGHT_MODULE || 'playwright-core');
const captures = process.env.PIZZA_LAYOUT_CAPTURES;
if (captures) await fs.mkdir(captures, { recursive: true });

const SIZES = [
  [1861, 969],
  [1160, 740],
  [1024, 600],
  [768, 640],
  [390, 844],
  [800, 360],
  [360, 400],
];
const TYPES = {
  html: 'text/html',
  js: 'text/javascript',
  css: 'text/css',
  svg: 'image/svg+xml',
  ttf: 'font/ttf',
};

const server = http.createServer(async (req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  if (path === '/webui.js') return res.setHeader('Content-Type', TYPES.js).end('');
  const file =
    path === '/protocol/contract.js'
      ? contract
      : root + 'ui/partition/prototype' + (path === '/' ? '/index.html' : path);
  try {
    const body = await fs.readFile(file);
    res
      .setHeader('Content-Type', TYPES[file.split('.').pop()] ?? 'application/octet-stream')
      .end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const BASE = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({ executablePath: process.env.PIZZA_CHROMIUM_EXECUTABLE });
const errors = [];
let checks = 0;

async function open(url, init) {
  const context = await browser.newContext({
    viewport: { width: 1160, height: 740 },
    acceptDownloads: true,
  });
  const page = await context.newPage();
  page.on('pageerror', (e) => errors.push(e.stack));
  page.on('console', (m) => m.type() === 'error' && !/404/.test(m.text()) && errors.push(m.text()));
  if (init) await page.addInitScript(init, VERSION);
  await page.goto(BASE + url);
  return page;
}

/** Every window size: no horizontal overflow, and navigation stays reachable. */
async function fits(page, name) {
  for (const [width, height] of SIZES) {
    await page.setViewportSize({ width, height });
    await page.evaluate(async () => {
      await document.fonts.ready;
      await Promise.allSettled(
        document
          .querySelector('.screen')
          .getAnimations()
          .map((a) => a.finished),
      );
    });
    const m = await page.evaluate(() => {
      const app = document.querySelector('#app');
      const foot = document.querySelector('.slot-foot');
      return {
        doc: [document.documentElement.scrollWidth, document.documentElement.scrollHeight],
        app: app.scrollWidth - app.clientWidth,
        buttons: [...(foot?.querySelectorAll('.btn') ?? [])].map((b) =>
          b.getBoundingClientRect().toJSON(),
        ),
      };
    });
    const at = `${name} ${width}×${height}`;
    assert.ok(m.doc[0] <= width && m.app <= 0, `${at}: horizontal overflow ${JSON.stringify(m)}`);
    assert.ok(m.doc[1] <= height, `${at}: the document scrolls instead of the app region`);
    for (const b of m.buttons)
      assert.ok(
        b.left >= 0 && b.right <= width + 0.5 && b.bottom <= height + 0.5,
        `${at}: navigation outside window`,
      );
    if (captures && (width === 1160 || width === 390))
      await page.screenshot({ path: `${captures}/${name}-${width}x${height}.png` });
    checks++;
  }
  await page.setViewportSize({ width: 1160, height: 740 });
}
const count = (page) => page.locator('.slot-changes .count').innerText();
const segment = (page, name) => page.locator('.lane-live .seg', { hasText: name }).first();

try {
  // 1. The demo backend runs the whole journey through the real application.
  const page = await open('/?demo=1');
  await page.waitForSelector('.screen-disks .disk');
  assert.equal(await page.locator('.disk').count(), 3);
  await fits(page, 'choose');

  await page.locator('.disk').first().click();
  await page.waitForSelector('.screen-plan .lane-live');
  assert.equal(await count(page), '0');
  assert.ok(await page.locator('[data-action="review"]').isDisabled(), 'nothing to review yet');
  assert.ok(await page.locator('[data-action="undo"]').isDisabled());

  // A protected partition can be inspected, never changed.
  await segment(page, 'EFI').click();
  assert.ok(await page.locator('#size-value').isDisabled());
  assert.ok(await page.locator('[data-action="delete"]').isDisabled());

  // Free space → new partition; the plan is a visible diff and is undoable.
  await segment(page, 'Free Space').click();
  await page.locator('[data-action="add-left"]').click();
  await page.waitForSelector('.lane-live .seg-created');
  assert.equal(await count(page), '1');
  await page.locator('#label').fill('Scratch');
  await page.locator('#label').press('Tab');
  await page.waitForSelector('.lane-live .seg-created:has-text("Scratch")');
  await page.locator('[data-action="undo"]').click();
  await page.waitForFunction(
    () =>
      !document.querySelector('.lane-live .seg-created .seg-name')?.textContent.includes('Scratch'),
  );
  await page.locator('[data-action="undo"]').click();
  await page.waitForFunction(() => !document.querySelector('.lane-live .seg-created'));
  assert.equal(await count(page), '0');

  // Exact size entry, a refused size, and keyboard boundary movement.
  await segment(page, 'Data').click();
  await page.locator('#size-value').fill('200');
  await page.locator('#size-value').press('Enter');
  await page.waitForSelector('.lane-live .seg-resized');
  assert.match(await segment(page, 'Data').innerText(), /200 GiB/);
  await page.locator('#size-value').fill('99999');
  await page.locator('#size-value').press('Enter');
  await page.waitForSelector('.toast.visible');
  assert.equal(
    await page.locator('#size-value').inputValue(),
    '200',
    'a refused size is not left in the field',
  );
  const grip = page.locator('.grip').last();
  await grip.focus();
  await page.keyboard.press('Shift+ArrowRight');
  await page.waitForFunction(
    () => document.querySelector('.lane-live .seg-resized .seg-size')?.textContent === '201 GiB',
  );
  assert.ok(
    await page.evaluate(() => document.activeElement?.matches('.grip')),
    'the boundary keeps focus',
  );

  // Pointer drag commits through the backend.
  const box = await grip.boundingBox();
  await page.mouse.move(box.x, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x - 60, box.y + box.height / 2, { steps: 4 });
  assert.ok(await page.locator('.grip.is-dragging').count(), 'drag shows a live readout');
  await page.mouse.up();
  await page.waitForFunction(
    () => document.querySelector('.lane-live .seg-resized .seg-size')?.textContent !== '201 GiB',
  );

  // Formatting marks data loss everywhere it is shown.
  await page.locator('#filesystem').selectOption('xfs');
  await page.waitForSelector('.lane-live .seg-erased');
  assert.ok(await page.locator('.change-danger').count());
  await page.evaluate(() => document.querySelector('.toast').classList.remove('visible'));
  await fits(page, 'plan');

  // Review: destructive plans need an explicit acknowledgement.
  await page.locator('[data-action="review"]').click();
  await page.waitForSelector('.screen-review');
  const apply = page.locator('[data-action="execute"]');
  assert.ok(await apply.isDisabled(), 'apply is blocked until data loss is acknowledged');
  assert.match(await page.locator('.ack').innerText(), /Data/);
  await fits(page, 'review');
  const saved = page.waitForEvent('download');
  await page.locator('[data-action="export-plan"]').click();
  const draft = JSON.parse(await fs.readFile(await (await saved).path(), 'utf8'));
  assert.equal(draft.version, VERSION);
  assert.ok(
    draft.layout.every((p) => /^\d+$/.test(p.offset) && /^\d+$/.test(p.length)),
    'exact byte strings',
  );
  await page.locator('[data-action="show-plan"]').click();
  await page.waitForSelector('.screen-plan');
  assert.match(await segment(page, 'Data').innerText(), /erase/i, 'returning to the plan keeps it');
  await page.locator('[data-action="review"]').click();
  await page.locator('.ack input').check();
  await apply.click();

  await page.waitForSelector('.screen-run');
  await fits(page, 'apply');
  await page.waitForSelector('.run-card.is-done', { timeout: 15000 });
  assert.equal(await page.locator('h1').innerText(), 'All set.');
  await page.locator('[data-action="finish-run"]').click();
  await page.waitForSelector('.screen-disks');
  assert.match(await page.locator('.disk').first().innerText(), /xfs|Data/);
  await page.context().close();

  // 2. Stubbed bridge: authorization, refusal copy, and a lost execution.
  const live = await open('/', (version) => {
    const hex = (c) => c.repeat(64);
    const gib = 1073741824n;
    const part = {
      id: hex('b'),
      path: '/dev/fixture1',
      offset: '1048576',
      length: String(8n * gib),
      name: 'Fixture',
      filesystem: 'ext4',
      encryption: 'none',
      protected: false,
      mountpoints: [],
      capabilities: ['label', 'resize', 'format', 'delete'].map((operation) => ({
        operation,
        support: 'available',
        reason: '',
      })),
    };
    const disk = {
      path: '/dev/fixture',
      identity: hex('a'),
      capacity: String(20n * gib),
      sector_size: 512,
      model: 'UI fixture',
      read_only: false,
      partition_table: 'gpt',
      usable_offset: '1048576',
      usable_length: String(20n * gib - 2097152n),
      partitions: [part],
      diagnostics: [],
    };
    globalThis.fixture = { calls: [], authorized: false };
    globalThis.webui = {
      isConnected: () => true,
      async call(binding, payload) {
        const req = payload ? JSON.parse(payload) : {};
        fixture.calls.push({ binding, ...req });
        const reply = (value) => JSON.stringify({ version, ...value });
        if (binding === 'pizza_session') return reply({ writes_enabled: true, formats: ['ext4'] });
        if (req.action === 'inventory') {
          const d = structuredClone(disk);
          if (req.elevated) fixture.authorized = true;
          if (!fixture.authorized)
            for (const key of ['partition_table', 'usable_offset', 'usable_length', 'identity'])
              delete d[key];
          return reply({ snapshot_id: hex('c'), platform: 'linux', disks: [d], diagnostics: [] });
        }
        if (binding === 'pizza_plan') {
          if (req.command?.kind === 'delete')
            return JSON.stringify({
              error: 'OperationUnavailable',
              message: 'OperationUnavailable',
            });
          const layout = req.layout ?? [
            {
              id: part.id,
              offset: part.offset,
              length: part.length,
              name: part.name,
              filesystem: 'ext4',
              retain_data: true,
            },
          ];
          if (req.command?.kind === 'label') layout[0].name = req.command.name;
          const intents =
            layout[0].name === part.name
              ? []
              : [{ kind: 'label', partition_id: part.id, label: layout[0].name }];
          const draft = {
            version,
            snapshot_id: hex('c'),
            disk_identity: disk.identity,
            layout,
            intents,
          };
          const result = { draft, regions: layout.map((p) => ({ ...part, ...p })) };
          if (req.review)
            result.validated = {
              version,
              digest: hex('d'),
              executable: true,
              offline_validation_required: false,
              operations: intents,
              diagnostics: [],
              destructive_partitions: [],
              draft,
            };
          return reply(result);
        }
        throw Error('Simulated loss of the execution reply.');
      },
    };
  });
  await live.waitForSelector('.screen-disks .disk');
  assert.match(await live.locator('.disk').innerText(), /Needs authorization/);
  await live.locator('.disk').click();
  await live.waitForSelector('.screen-plan .notice-access');
  assert.equal(
    await live.locator('.lane-live .grip').count(),
    0,
    'view-only disks have no handles',
  );
  await live.locator('[data-action="authorize"]').click();
  await live.waitForSelector('.lane-row-after');
  assert.equal(await live.locator('.notice-access').count(), 0);
  await live.locator('[data-action="delete"]').click();
  await live.waitForSelector('.toast.visible');
  assert.match(
    await live.locator('.toast').innerText(),
    /not available for this partition/,
    'error names are explained',
  );
  await live.locator('#label').fill('Renamed');
  await live.locator('#label').press('Enter');
  await live.waitForSelector('.changes .change');
  await live.locator('[data-action="review"]').click();
  await live.waitForSelector('.screen-review');
  assert.equal(await live.locator('.ack').count(), 0, 'no acknowledgement without data loss');
  await live.locator('[data-action="execute"]').click();
  await live.waitForSelector('.screen-disconnected');
  await fits(live, 'disconnected');
  const stored = await live.evaluate(
    (v) => JSON.parse(localStorage.getItem(`pizza.execution.v${v}`)),
    VERSION,
  );
  assert.deepEqual(
    stored,
    { id: null, digest: 'd'.repeat(64) },
    'the approval is remembered before the reply',
  );
  await live.context().close();

  assert.deepEqual(errors, []);
  console.log(`layout.browser: ${checks} window checks passed`);
} finally {
  await browser.close();
  server.close();
}
