# Pizza · desktop frontend

The page embedded in `pizza` and served over the WebUI bridge. Four screens follow the one
job the user has: **Choose** a disk → **Plan** a layout → **Review** the changes → **Apply**.

Run `zig build run` for the native window or `zig build run -- serve 4182` for a browser
preview; both use the same Zig backend. `?demo=1` swaps in an in-memory backend with sample
disks. It runs the same application code and never touches a disk.

## Design principles

- **The pizza is the main observation surface.** Slices show the planned byte proportions,
  with stable recipes, selection highlighting and a clickable legend for tiny partitions.
  Selecting a slice or using Enter/Space opens its inspector. Desktop layouts reserve the
  centre for the pizza; narrow windows put it first and scroll the remaining controls.
- **Exact boundaries stay available.** Expand the layout details to inspect the address
  space, partition table and `Now`/`After` lanes. Order and adjacency are exact; tiny lane
  regions have a visible minimum width. The panel retains its open state while editing.
- **A plan is a diff.** `Now` (the disk as read) sits above `After` (the plan). A partition
  keeps its colour in both lanes; created, resized, moved, erased and deleted regions are
  badged, and the same changes are listed in words beside the inspector while editing.
- **Nothing is hidden.** Every action is a visible button on the selected region. There is no
  context menu, long press or hover-only control. Boundary handles work with the pointer and
  the keyboard (arrows 1 MiB, Shift 1 GiB, Home / End).
- **Editing is reversible, applying is not.** Undo steps back one change; nothing is written
  until Apply. A plan that erases data names the partitions and needs an explicit
  acknowledgement before the Apply button unlocks; the reason it is locked is always shown.
- **Exact numbers.** Sizes are byte strings end to end (`BigInt` in the page). The inspector
  shows exact start, end and size; the size field takes MiB or GiB and is rounded down to a
  whole sector by the backend.

## Modules

| File                  | Responsibility                                                                      |
| --------------------- | ----------------------------------------------------------------------------------- |
| `main.js`             | Entry point: picks the native transport or the demo backend, starts the app.        |
| `app.js`              | Controller: application state, backend calls, screen changes, input handling.       |
| `views.js`            | Pure markup: state → the slots of each screen. No DOM access, no requests.          |
| `disk-map.js`         | The lane: segments, boundary handles, and what the plan does to each region.        |
| `plan-model.js`       | Byte arithmetic, capability checks, and `PlanClient` (serialized edits, undo).      |
| `execution-client.js` | `ExecutionMonitor`: polls a running execution and survives a lost reply.            |
| `transport.js`        | The WebUI bridge. The only module that knows binding names.                         |
| `demo-backend.js`     | In-memory stand-in for the backend, same request interface as `transport.js`.       |
| `dom.js`              | Escaping, downloads, and the slot painter that rewrites only regions whose markup changed. |
| `pizza.js`            | Procedural SVG artwork.                                                             |

Editing rules, plan generation and validation live in Zig (`core/planning`). The page only
displays backend layouts and sends edit commands; `demo-backend.js` mirrors those rules for
presentation and is not authoritative.

## Tests

```sh
zig build protocol-bindings
node --test ui/partition/test/*.test.mjs

PIZZA_PLAYWRIGHT_MODULE=/absolute/path/to/playwright-core/index.mjs \
PIZZA_CHROMIUM_EXECUTABLE=/absolute/path/to/chromium \
node ui/partition/test/layout.browser.mjs
```

`layout.browser.mjs` drives the real page in Chromium against fixtures only (the demo backend
and a stubbed bridge). It walks the whole journey: creating, renaming, undoing, exact and
refused resizes, keyboard and pointer boundary moves, formatting, the data-loss
acknowledgement, plan export, execution to completion, authorization of a view-only disk,
explained backend errors, and a lost execution reply. Each screen is checked at seven window
sizes from 1861×969 down to the 360×400 minimum for horizontal overflow and reachable
navigation. Set `PIZZA_LAYOUT_CAPTURES` to a directory to save screenshots; `screenshots/`
holds captures of the demo taken this way.

Fonts and their OFL licenses are bundled under `assets/fonts`.

Session recovery reads protected backend state through `discover`. An explicit “Find saved
session” action may request administrator authorization; startup only reuses an existing
helper. Browser storage is a shortcut, and an absent browser reference cannot hide a
prepared maintenance session. Completed execution reports are opened automatically only
when a saved local reference exists; manual discovery can reopen the latest durable report.
