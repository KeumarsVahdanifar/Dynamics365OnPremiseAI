# UI testing — driving the org in a real browser

`d365.ps1` proves the **server** is right: the component exists, the ribbon merged, the count query
returns 2. It cannot prove the **client** renders any of it. Ribbon buttons that never draw, an icon
the wrong colour, a web resource 404, a JavaScript exception, a dialog covering the page — none of
that is visible from the SDK, and guessing at it costs a deploy cycle per guess.

`uitest/` closes that gap. It drives an **already installed** Chrome (or Edge) through Playwright, so
nothing is downloaded, signs in with the credential `d365.ps1 login` already cached, and reports
console errors, failed requests, screenshots and whatever assertions you asked for — as JSON.

---

## Setup (once)

```
cd <plugin>\uitest
npm install playwright
```

No browser download is needed: the runner launches your installed Chrome via Playwright's `channel`
support (`-Channel msedge` for Edge).

## Running it

```powershell
# Unified Interface, with a specific app
powershell -ExecutionPolicy Bypass -File .\uitest\d365-uitest.ps1 `
    -Check checks\ribbon-badge.js -App <appid>

# classic web client
powershell -ExecutionPolicy Bypass -File .\uitest\d365-uitest.ps1 -Check checks\ribbon-badge.js -Classic

# just open a page and report console errors / screenshots
powershell -ExecutionPolicy Bypass -File .\uitest\d365-uitest.ps1 -Goto "main.aspx?etn=account&pagetype=entitylist"

# watch it happen
... -Check checks\ribbon-badge.js -Headed -KeepOpen
```

Options: `-Check <file>` `-App <appid>` `-Classic` `-Goto <relative-url>` `-Out <dir>`
`-Channel chrome|msedge` `-Settle <ms>` `-Headed` `-KeepOpen`.

Exit code `0` = every check passed, `1` = a check failed, `2` = the runner could not start.

**Credentials** come from the DPAPI-encrypted credential that `d365.ps1 login` cached, are passed to
the child process as environment variables, and are never written to disk. The runner also sets
`httpCredentials`, so an org using integrated auth needs no sign-in form at all.

## What you always get back

```json
{
  "ok": true,
  "shell": "uci",
  "login": "submitted credentials to the sign-in form",
  "dismissedOverlays": ["frame:a#buttonClose.navTourCloseButton"],
  "checks": [{ "name": "...", "pass": true, "detail": "..." }],
  "consoleErrors": ["Failed to load resource: 404  <- https://.../ClientGlobalContext.js.aspx"],
  "failedRequests": ["404 GET https://.../ClientGlobalContext.js.aspx"],
  "screenshots": ["...\\out\\shell.png"]
}
```

`consoleErrors` carries the **URL** from the console message location — a bare "404 (Not Found)" is
useless — and `failedRequests` lists every 4xx/5xx response with its URL.

First-run dialogs are dismissed automatically across **all frames** before the checks run. This
matters more than it sounds: the "Explore Dynamics 365" tour is an iframe with a full-page backdrop
that silently swallows every click, and while it is up a perfectly working feature looks dead.

## Writing a check module

A check module exports `run({ page, context, cfg, shot })` and returns
`{ checks: [{name, pass, detail}], screenshots: [...], extra: {...} }`.

```javascript
async function run({ page, shot }) {
    const count = await page.evaluate(() => document.querySelectorAll('#my-thing').length);
    return {
        checks: [{ name: 'exactly one widget', pass: count === 1, detail: 'found ' + count }],
        screenshots: [await shot('widget')],
        extra: { count }
    };
}
module.exports = { run };
```

Two modules ship with the plugin:

- **`checks/probe-header.js`** — dumps the shell's top-bar DOM (ids, `data-id`s, rectangles, likely
  containers). Run this *before* writing selectors that touch the application header; it is how the
  header anchors for both shells were established instead of guessed.
- **`checks/ribbon-badge.js`** — a worked example: one bell, a numeric badge (Persian digits
  normalised), the dropdown opening, mark-as-read decrementing the count, the centre page listing
  rows, plus frame probes and a trace dump when something fails.

## Habits that pay for themselves

1. **Never swallow a click error.** `.click().catch(() => {})` turns "an overlay is covering the
   button" into "the feature is broken". Report the error, then optionally fall back to a DOM click —
   the difference between the two tells you which problem you have.
2. **Count logical elements, not nodes.** A rendered ribbon button and its inner label can both carry
   the command id; filter to outermost matches or one button looks like two.
3. **Put a trace ring buffer on `window.top`** in the code under test and read it back in the check.
   Screenshots tell you the end state; the trace tells you the order things happened in.
4. **Wait for the thing, not for a number of seconds.** A shell that has to download a library before
   it can open a panel will fail a fixed `waitForTimeout` and pass a `waitFor({ state: 'visible' })`.
5. **Normalise the UI's locale.** A Persian badge reads `۷`; an assertion for `\d+` fails on data
   that is perfectly correct.
6. **Seed the data you assert on.** A check that expects unread rows fails after a previous run marked
   them all read. Create rows with `d365.ps1 create` immediately before the run.
