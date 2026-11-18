# Swiftr mods

<!-- Written by Swiftr {{version}} on every start. Edits here are overwritten. -->

This folder, `{{home}}`, holds the mods and layouts of **Swiftr**, a Mac app
for terminals and coding agents. A mod is a small program that draws a panel
in Swiftr's window. When the person asks for one ("a list of my open pull
requests", "show this folder's branch and its last CI run"), you write it
here, check it, and tell them what it does. They switch it on in Swiftr.

## What a mod is, and is not

- A mod is JavaScript. Its script describes a panel with chained builders
  (`div().flex().child(…)`); Swiftr lays the panel out and draws it itself,
  with the Mac's own text and graphics. There is no HTML, no CSS, no web
  view, no Node, no npm, and no `setTimeout`.
- There are no mods written in Swift. Do not offer one.
- The format is herdr-app's (https://herdr.dev). A mod written for one app
  runs in the other where both know the names it calls. `API.md`, beside
  this file, lists every name Swiftr knows.
- Swiftr's own interface (its sidebar, tabs, terminals, Messages mode) is
  not made of mods and a mod cannot change it. A mod adds a panel: in the
  mods sidebar on the window's right, around the tab if a layout says so,
  or over the window as a dialog.

## The files

```
{{home}}/
  AGENTS.md               this guide; Swiftr rewrites it
  API.md                  every name a mod can call; Swiftr rewrites it
  bin/swiftr-mod          the tool that checks a mod; it runs Swiftr's own copy
  mods/<name>/main.js     a mod
  mods/<name>/mod.json    optional: its title, and how it opens over the window
  layouts/<name>.json     a layout
  keys.json               keys that run commands
  data/                   what mods store; Swiftr writes it
```

Save a mod's `main.js` and Swiftr loads it again.

## Write a mod

1. Make `mods/<name>/main.js`. It default-exports a class that extends `View`.
2. Run `{{home}}/bin/swiftr-mod check {{home}}/mods/<name>`. Fix every
   `error:` line. A `not in Swiftr yet:` line names builders Swiftr does not
   draw: use others from `API.md`.
3. Run `swiftr-mod shot <mod folder> /tmp/<name>.png --width 360 --height 560`
   and look at the picture. Never call a mod done without both.
4. Tell the person what the mod asks for (see "What the person allows").
   You cannot allow it for them: it shows in Swiftr's mods sidebar and in
   Settings › Mods with its list, and stays off until they press Allow.

A check has no app behind it: the lists are empty and every `exec` fails
with code 127, so you see the mod's empty and error states only. To see
the others, give `check` and `shot` a data file with `--data file.json`.
Its keys are the names under "What a mod can read", and `exec` lists
answers to programs, matched by a regular expression on the command line:

```json
{
  "focused": { "space": "s1", "tab": "t1", "pane": "p1", "terminal": "x1", "agent": null, "cwd": "/Users/me/app" },
  "agents": [{ "address": "x2", "title": "Fix the login test", "status": "working", "program": "claude" }],
  "exec": [{ "match": "^git status", "code": 0, "stdout": " M README.md\n" }]
}
```

`--do "click:Refresh; type:Search=cat; wait:300"` presses and types before
the picture, and `--texts` prints what the panel shows. More steps:
`key:tab` (or `shift-tab`, `space`, `enter`, `escape`, `down`…),
`hover:Text`, `drop:Text=/a/file,/another`, `drag:Text=40,0`,
`right-click:Text`, `click-id:the-id`.

```js
// mods/hello/main.js
import { View, div } from "gpui-kit";
import { v_flex } from "gpui-base";
import { agents, theme } from "herdr";

export default class Hello extends View {
  init() {
    this.clicks = 0;
  }

  render() {
    const t = theme();
    return v_flex().size_full().p(12).gap(8)
      .child(div().text_color(t.muted).child(`${agents().length} agents`))
      .child(
        div().id("add").px(10).h(28).flex().items_center().rounded(6)
          .bg(t.raised).hover((s) => s.bg(t.hover))
          .on_click((_event, cx) => { this.clicks++; cx.notify(); })
          .child(`Clicked ${this.clicks}`)
      );
  }
}
```

- `init(props, cx)` runs once; `render(cx)` gives back a tree of elements.
- Call `cx.notify()` when what you show changed. A handler gets `(event, cx)`.
- What `render` reads from `"herdr"` (`agents()`, `spaces()`, `theme()`…)
  draws the panel again when it changes. Do not poll those.
- Work that waits goes in `cx.spawn(async () => { … })`. Timers are
  `cx.sleep(ms)`, `cx.timer.after(ms, f)` and `cx.timer.every(ms, f)`.
- To fetch again when a value changes (the focused folder, say), read it in
  `render`, compare it with the one you kept, and start the work when they
  differ.
- Layout is flexbox. A child of `v_flex()` takes the full width, as the
  example's button does: `self_start()` keeps it as wide as its text.
- Conditions chain: `.when(cond, (el) => el.child(…))`,
  `.when_else(cond, (el) => …, (el) => …)`, and
  `.when_some(value, (el, value) => …)`, which runs when `value` is not null.
- A mod draws only while it shows. Keep `render` cheap: it runs often.
- Use the theme's colors, never fixed ones: `background`, `foreground`,
  `surface`, `raised`, `hover`, `selected`, `border`, `input`, `muted`,
  `dim`, `accent`, `accent_foreground`, and for agents `working`, `blocked`,
  `done`, `idle`. Swiftr has a light and a dark look.
- Text in a panel can be selected and copied by the person. Sizes are in
  points; the sidebar is 240 to 640 wide, so let rows shrink and truncate.

## Controls, menus and motion

The parts in `"gpui-base"` (`Button`, `Checkbox`, `Switch`, `Radio`,
`Toggle`, `Link`, `Slider`, `NumberInput`, `Popover`, `HoverCard`, `Popup`,
`Select`, `Collapsible`, `AccordionItem`…) draw nothing, here as in
herdr-app. Each is a `div()` that knows how to behave: you give it its look
with the theme's colors, and Swiftr gives it the Mac's manners.

```js
import { View, div } from "gpui-kit";
import { Checkbox, Popover, v_flex } from "gpui-base";
import { theme } from "herdr";

export default class Options extends View {
  init() { this.wrap = false; this.sort = "Name"; this.menu = false; }
  render() {
    const t = theme();
    const pick = (name) => div().id("sort-" + name).px(8).py(4).rounded(5)
      .hover((s) => s.bg(t.hover))
      .on_click((_e, cx) => { this.sort = name; this.menu = false; cx.notify(); })
      .child(name);
    return v_flex().size_full().p(12).gap(10).text_color(t.foreground)
      .child(Checkbox.new("wrap").checked(this.wrap)
        .on_change((value, cx) => { this.wrap = value; cx.notify(); })
        .flex().items_center().gap(6)
        .child(div().size(14).rounded(4).border_1()
          .border_color(this.wrap ? t.accent : t.border)
          .bg(this.wrap ? t.accent : t.input))
        .child("Wrap lines"))
      .child(Popover.new("sort").open(this.menu)
        .on_open_change((open, cx) => { this.menu = open; cx.notify(); })
        .trigger(div().px(10).py(4).rounded(6).border_1().border_color(t.border)
          .child("Sort by " + this.sort))
        .content(v_flex().mt(4).p(4).w(160).rounded(8).bg(t.raised)
          .border_1().border_color(t.border).shadow_md()
          .child(pick("Name")).child(pick("Date")).child(pick("Size"))));
  }
}
```

- A press on a `Checkbox`, a `Switch` or a `Toggle` calls `on_change` with
  the new value; a `Radio` only ever reports `true`. Keep the value in your
  view and hand it back with `checked(…)` or `pressed(…)`. `disabled(true)`
  turns a part off. A `Link` opens its `href(…)` in the browser.
- Tab and ⇧Tab go from part to part and from field to field. Space and
  Return press the part that has the keyboard; the arrows, Home and End
  move a slider. A part reached by Tab gets the Mac's focus ring, unless
  you give it a look with `focus((s) => …)`. `tab_index(0)` makes a plain
  element a stop; `tab_stop(false)` takes a part out.
- `Popover.new(id).trigger(el).content(el)` opens on a press and shuts on
  Escape or a press outside. With `open(value)` and `on_open_change` the
  state is yours, as above; without them it keeps its own. `anchor(…)`
  picks the corner (`top_left`, `top_right`, `bottom_left`, `top_center`…).
  The content shows in a layer over the window, so it may be wider than
  the sidebar; it stays inside the window.
- `HoverCard.new(id)` opens once the pointer rests on its trigger.
  `Popup.new(id, trigger)` shows what its `content` slot holds and does
  nothing else: fill the slot to open it. `Select.new(id)` adds the keys
  of a list of choices (Return and the arrows open it, Escape shuts it);
  moving the highlight is your `on_key_down`.
- A slider is four parts on one `SliderState.new({ min, max, step, value })`:
  `Slider` holds `SliderTrack` (what the pointer presses), which holds
  `SliderIndicator` (the groove; `range_style((fill) => …)` styles the
  filled part), which holds `SliderThumb`. Swiftr places the fill and the
  thumb. `state.on("change", (value, cx) => …)` hears each move.
- `NumberInput.new(inputState)` steps with ↑ and ↓ and with what you put in
  `increment_button(el)` and `decrement_button(el)`; `set_step`, `set_min`
  and `set_max` on the state bound it.
- `h_resizable(id)` and `v_resizable(id)` hold `resizable_panel()`s with a
  divider to drag between them; Swiftr keeps the sizes by the group's id.
- Motion needs no timer. `transition(property, ms)` and
  `spring(property, { response, damping })` glide to a new value;
  `loop(property, { from, to, period })` goes there and back for ever;
  `frames(["|", "/", "-"], ms)` is a text spinner; `spin(seconds)` turns an
  element. The properties are `opacity`, `width`, `height`, `left`, `top`.
- `on_drop(({ paths }, cx) => …)` takes files dropped from the Finder.
  `drag_paths([path])` lets the person drag files out; files outside the
  mod's own folder need the leave to read files.
- VoiceOver reads each part by its role and its text, and every element
  with an `on_click` as a button. Name what has no text with
  `accessibility_label("…")`; say what a hand-drawn element is with
  `role("tab")`, `aria_selected(true)`, `aria_expanded(open)`.

## What a mod can read

From `"herdr"`. Each is a plain value, ready in `render`:

- `spaces()`: `{ id, index, name, folder, machine, active, status, tabs }`,
  each tab `{ id, index, name, active, status, panes, zoomed }`. `machine`
  is null on this Mac.
- `agents()`: the coding agents that run:
  `{ address, pane, space, space_name, tab, tab_index, tab_name, status,
  program, title, focused }`.
- `panes()`: `{ pane, terminal, tab, title, cwd, status, program, focused,
  zoomed }`.
- `focused()`: `{ space, tab, pane, terminal, agent, cwd }`, or null.
  `cwd` is the focused terminal's folder.
- `machines()`: `{ name, layout }`; `name` is null for this Mac, `layout`
  is `"ready"`, `"loading"` or `"unavailable"`.
- `status` is `"working"`, `"blocked"` (the agent waits for the person),
  `"done"`, `"idle"`, or null for a plain terminal.
- `theme()`, `settings()` (`dark`, `font_family`, `font_size`), `window()`,
  `layout()`, `layouts()`, `props()` (what the layout or `mod.open` gave
  this copy), `home()` (the person's home folder), `appHome()` (this
  folder).
- `shared(key)` and `setShared(key, value)`: state every mod sees.
  `cx.window.localStorage` keeps this mod's own.

## What a mod can do

- `run(name, args)`: a Swiftr command. `tab.new`, `tab.select {id}`,
  `tab.close {id}`, `tab.next`, `tab.prev`, `tab.rename {id}` (opens the
  tab's name for the person to type), `tab.move {id, index}` (`index`
  counts from 1), `space.new`, `space.select {id}`, `space.next`,
  `space.prev`, `pane.focus {pane}`, `pane.split {direction: "right" | "down"}`,
  `pane.close`, `pane.zoom`, `agent.focus {address}`,
  `terminal.focus {address}`, `mod.open {mod, props}`, `mod.close {mod}`,
  `layout.switch {name}`, `layout.show {id}`, `layout.hide {id}`,
  `layout.toggle {id}`, `layout.select {stack, child}`,
  `layout.resize {id, px}`, `window.minimize`, `window.maximize`,
  `window.close`, `app.settings`. Other names do nothing.
- `await exec(command, args, { cwd, timeout, machine })`: runs a program and
  gives `{ code, stdout, stderr }`. It is not a shell: no pipes.
  `machine` is a space's `machine`, to run there.
- `await hc(args)`: herdr-core's tool, which runs the terminals.
- `await readTextFile(path)` (null when absent), `await writeTextFile(path,
  text)`, `await watchFolder(path)` (answers when the folder changes),
  `await pickFolder()`.
- `await fetch(url, { method, headers, body })`: `status`, `ok`, `text()`,
  `json()`. `body` is text or bytes.
- Bytes: `import { Buffer } from "buffer"`, a `Uint8Array` with
  `Buffer.from(text, "base64")`, `buffer.toString("hex")` and the like.
  From `"fs/promises"`, `readFile(path, "utf8")` gives text and
  `readFile(path)` gives the file's bytes; `writeFile` takes either.
- Sums, from `"crypto"`: `createHash("sha256").update(text).digest("hex")`
  (also `sha1`, `md5`, `sha384`, `sha512`), `randomBytes(n)`,
  `randomUUID()`. From `"zlib"`: `gzipSync(data)`, `gunzipSync(data)`,
  `deflateSync(data)`, `inflateSync(data)`.
- Sockets, when `fetch` is not enough. From `"net"`,
  `await connect(host, port)` gives a socket: `await socket.read(maxBytes)`
  is the next bytes, or null once the other side is done;
  `await socket.write(data)`; `socket.close()`. From `"websocket"`,
  `await WebSocket.connect("wss://…", { headers })` gives one whose
  `await ws.read()` is the next message, text or bytes, with
  `await ws.write(data)` and `await ws.close()`. A mod holds 16 sockets at
  most, and they close when it reloads.
- `notify({ title, body })`, `cx.open_url(url)`, `cx.write_to_clipboard(text)`,
  `cx.read_from_clipboard()`.
- `openOverlay({ mod, props, kind, width, height })` and `closeOverlay(id)`:
  a mod over the window.

## What the person allows

A mod is a program, so Swiftr reads its files before it runs and shows the
person what they ask for:

- Runs programs (`exec`, `hc`, `process.run`)
- Writes files outside its own folder
- Reads files outside its own folder
- Reaches the network (`fetch`, `net`, `websocket`)
- Runs Swiftr commands (`run`)

Swiftr then holds the mod to that list. A mod that only draws, reads the
lists above and keeps its own storage asks for nothing.

Your part: ask for as little as the job needs, name programs and sites as
plain text (`exec("git", […])`, not a variable) so the list shows them, and
tell the person in one or two lines what the mod will run, read and reach.
Never write to Swiftr's own settings to allow a mod, and never work around
a refusal: the person decides.

## mod.json

```json
{ "title": "Pull requests", "overlay": { "kind": "dialog", "width": 560, "height": 420 } }
```

`title` is the name shown in the sidebar; without it Swiftr uses the folder's
name. `overlay` is how the mod opens over the window when a key or another
mod runs `mod.open {"mod": "<name>"}`.

## Layouts and keys

Without a layout file, Swiftr shows every mod in a sidebar on the window's
right, one at a time, with their names at its top. The person can pick a
layout file instead, in herdr-app's format: a tree of rows, columns and
stacks. The block `{"tab": "active"}` is the shown tab, and blocks with
`{"mod": "<name>"}` are mods around it. herdr-app's own blocks (`spaces`,
`agents`, `tabs`…) are left out: Swiftr keeps its own sidebar and tabs.

```json
{
  "type": "row",
  "children": [
    { "type": "block", "id": "main", "content": { "tab": "active" } },
    { "type": "column", "id": "panel", "size": { "px": 360 }, "min": 280, "max": 900,
      "children": [
        { "type": "block", "id": "hello", "content": { "mod": "hello" } }
      ] }
  ]
}
```

`keys.json` maps a chord to a command:

```json
{ "cmd-shift-p": { "command": "layout.toggle", "args": { "id": "panel" } } }
```

## Add a mod or a layout someone shared

```
{{home}}/bin/swiftr-mod add herdr.dev/mods/<owner>/<name>
{{home}}/bin/swiftr-mod add github.com/<owner>/<repo>/tree/<branch>/<folder>
```

It copies the mods and layouts the link holds, replaces nothing the person
has, and prints what each mod asks for. Then:

1. Read every file it added. It is somebody else's program, and nothing of
   it has run.
2. Tell the person what it does and what it asks for. Many herdr-app mods
   call builders Swiftr does not have: compare the names it calls with
   `API.md` and say which are missing.
3. A check runs the mod's script, so `swiftr-mod check` refuses a mod that
   came from a link. Once the person agrees, pass `--reviewed`. Rewrite the
   missing parts only if they want it.
4. They allow each mod in Swiftr.

Never copy a shared mod over one the person has, and never add one by hand
to skip these steps.

## Share one

Put the mod's folder in a public GitHub repository. Anyone adds it with
`swiftr-mod add github.com/<you>/<repo>`, or in Swiftr with Settings › Mods ›
Add from Link. A picture helps: `swiftr-mod shot` makes one.

herdr.dev's gallery lists repositories that carry the topic `herdr-mod` or
`herdr-layout`, with a `RECIPE.md` and a `preview.png`. Add the topic only
to a mod that also runs in herdr-app.

## What is not there yet

- `DockArea`, `DatePicker` and `OtpInput`; tokens inside a field.
- `on_pinch` never fires. `drag_paths` with files on another machine drags
  nothing.
- A scrolling list has no rubber band and no thumb to drag.
- herdr-app's Files panel. A block named `changes` gets Swiftr's own Changes
  panel.
- Node's `fs` and `child_process`, which herdr-app lacks too: import
  `fs/promises` for files and call `exec` from `"herdr"` for programs.
- A listening socket (`createServer`), and the browser's `new WebSocket()`.
