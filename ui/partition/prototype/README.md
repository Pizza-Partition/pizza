# Pizza · interactive Web UI prototype

Five connected screens: Welcome → Select a Disk → Slice Your Disk → Review & Confirm → All Set. A short simulated apply transition connects review to completion.

Run `zig build run` for the native desktop backend, or `zig build run -- serve 4182` for browser preview. Both use the same Zig backend and WebUI transport. `?demo=1` selects the original in-memory visual demonstration.

The desktop program displays real inventory and exports protocol-v4 plans using exact integer byte geometry. Administrator access uses the first available tool (run0, then pkexec, then kdesudo) to launch the same executable in privileged-exec mode; development builds work directly, without installation. Maintenance handoff remains blocked until implementation and reboot acceptance are complete. Only demo mode uses fictional data, held in memory and reset on reload.

- Disk selection, slice selection, divider dragging / number input, naming, file systems, contextual left / right add, delete / reset, review and JSON export work.
- System slices are protected in this prototype. Dragging a divider redistributes capacity between its two adjacent slices. Number entry shrinks into new adjacent free space or grows into adjacent free spans. Physical sector alignment, file-system constraints and real move feasibility require the real planner.
- Slice sizes always sum to disk capacity. Only the editor dims unselected slices; welcome, review, transition and completion use opaque artwork.
- The food is native SVG: original ingredient silhouettes from the supplied `New project 3/src/Pizza.tsx`, composed into responsive wedges, with simpler shading and no native relief or 3D runtime. Fonts and their OFL licenses are bundled under `assets/fonts`.
- English copy follows the supplied keyframes. This is a visual / interaction prototype, not the production frontend or maintenance environment.

`index.html` is the shell, `style.css` the responsive visual system, `app.js` the sample interaction model, and `pizza.js` the procedural artwork. `live.js`, `live-model.js` and `transport.js` implement the native connection; `app.js` remains demo-only.

## Preview captures

The `screenshots/` folder contains the five desktop scenes and the narrow-screen editor. They are captures of the working HTML prototype, not generated mockups.

Selection updates preserve disk cards, the pizza SVG and inspector inputs. Slice opacity and position transition over 200 / 260 ms without restarting the page entrance animation. Repeated selection, focus retention, label edits and subsequent resize / add / delete actions were checked in the browser; SVG paint definitions stay unchanged across selections. `07-selection-fix.png` captures the updated editor.

The file-system picker uses a matching warm paper menu with a brick-red selection check. `format-picker.js` implements the select-only combobox / listbox, arrow and Home / End navigation, type-to-search, Enter / Space selection, Escape cancellation, Tab / outside dismissal and disabled states. Mouse and keyboard selection were checked against the review plan. The menu repositions above the field when space below is limited.

The editor identifies each slice with an external callout: name, capacity and file system, connected by an elbow leader to the slice's actual angular midpoint. Text stays outside the pizza and remains opaque. Labels can also select a slice; selecting preserves SVG resources. Resizing, renaming, changing file systems and adding / removing partitions update the callouts. Checked the 0.1 GB free-space boundary and desktop / narrow layouts. `09-external-callouts.png` shows this design.

`partition-bar.js` provides draggable dividers, keyboard adjustment (arrows, Shift + arrows, Home / End), and a segment context menu. Add left / right takes capacity from the clicked free span, or splits the clicked allocated partition while keeping at least 10 GB. New slices are inserted on the requested side; deleting returns capacity to free space at that position and merges adjoining free spans. Right-click, Shift + F10, a long press, or the three-dot button opens the same menu. The menu is attached to `body` so page animations cannot offset its viewport coordinates; it flips beside the pointer at window edges. Checked real pointer dragging, both insertion directions, deletion / merge, minimum / maximum sizes, protected System, review output and total capacity. Desktop and narrow layouts place the menu within about 6 px of the invocation point. `10-partition-bar-menu.png` shows this interaction.

Verified in the browser: disk switching, selecting slices, numeric and keyboard resizing, 0 GB and 0.1 GB free-space boundaries, naming, changing file systems, adding and deleting slices, review contents, simulated completion, opacity rules and the help dialog. Checked desktop and 390 px responsive layouts; the browser reported no JavaScript errors. JavaScript syntax checks also pass.

## Window layout regression

All screens use a viewport-sized shell. Review uses the shared `review-layout.js`
structure in live and demo modes: the changes/diagnostics region scrolls independently,
the summary folds above it in narrow windows, and navigation stays visible. Welcome,
preview progress and completion fit their artwork into the remaining space; short
landscape windows place text beside the artwork.

`ui/partition/test/layout.browser.mjs` serves only source files and simulated protocol
responses on a temporary localhost port. It never calls the native backend. With an
existing Playwright Core installation and Chromium executable, run from the repo root:

```sh
zig build protocol-bindings
PIZZA_PLAYWRIGHT_MODULE=/absolute/path/to/playwright-core/index.mjs \
PIZZA_CHROMIUM_EXECUTABLE=/absolute/path/to/chromium \
node ui/partition/test/layout.browser.mjs
```

The fixture checks 11 window sizes (320×568 through 1861×969, including 800×360),
empty and populated reviews, long diagnostics, exact-byte plan export, simulated
execution failure/reconnection, and every demo screen. Set `PIZZA_LAYOUT_CAPTURES`
to an output directory to save desktop, narrow and short-window screenshots.

Authorization updates the existing editor instead of remounting it. Disk refreshes
patch cards and partition details by stable device path, preserving selection,
focus, scroll and disclosure state. The list stays visible during reads and on
read failure; returning from authorization does not replay the list's entrance
animation. A late ordinary read cannot replace a newer administrator snapshot,
and an authorization response cannot navigate a user back to an editor they left.
The browser fixture covers these delayed-response cases, refresh failure, disk
reordering and removal without invoking system authorization.
