# Mods and layouts

A mod is a small JavaScript program that draws a panel in Swiftr's window. A layout is a JSON file that says where the panels go. Both use herdr-app's format. A mod written for herdr-app runs in Swiftr when it calls only the builders Swiftr knows, and a mod written for Swiftr should run in herdr-app.

Every mod is JavaScript: there are no mods written in Swift. What is native is the drawing. Swiftr does not embed a browser. It runs the mod's script in JavaScriptCore, which ships with macOS, and draws what the script describes itself: flex layout by Yoga, text by Core Text, paint by Core Graphics. A full pass of a 50-element panel (the script's render, layout, paint) takes about 2 ms, and a mod draws again only when something it reads changes and while it shows.

## Where things live

```
~/.config/swiftr/
  AGENTS.md               the guide for a coding agent; Swiftr rewrites it
  API.md                  every name a mod can call; Swiftr rewrites it
  bin/swiftr-mod          checks a mod and takes its picture
  mods/<name>/main.js     the mod
  mods/<name>/mod.json    its title, and how it opens over the window
  layouts/<name>.json     a layout
  data/                   what mods store; Swiftr writes it
  keys.json               keys that run commands
```

Settings › Mods lists the mods, adds a folder, a link or a layout file, and copies mods over from `~/.config/herdr-app`. Save a mod's file and Swiftr loads it again.

## Ask your agent for one

Swiftr writes three files into `~/.config/swiftr` each time it starts: `AGENTS.md`, a guide for coding agents; `API.md`, the names a mod can call, read from the app that runs; and `bin/swiftr-mod`, which runs the app's own checker. With them an agent can write a mod, check it and look at its picture. In any tab:

```
Read ~/.config/swiftr/AGENTS.md, then make me a mod that shows this folder's branch and its last CI run.
```

The mod shows in the sidebar, off, with what it asks for. The agent cannot allow it for you.

## Add one someone shared

In Settings › Mods, **Add from Link…** takes a page of [herdr.dev](https://herdr.dev/mods)'s gallery or a folder on GitHub:

```
herdr.dev/mods/<owner>/<name>
github.com/<owner>/<repo>/tree/<branch>/<folder>
```

Swiftr downloads the folder and copies its mods and layouts. It runs nothing, replaces nothing you have (a mod or layout of the same name is left out), and leaves `keys.json` for you to merge. Each mod then waits in the list with what it asks for. `swiftr-mod add <link>` does the same from a terminal.

Many herdr-app mods call builders Swiftr does not have yet. Once such a mod has run, its row in Settings names them, and so does `swiftr-mod check`. A check runs the mod's script, so it refuses a mod that came from a link until you pass `--reviewed`.

To share yours, put its folder in a public GitHub repository. herdr.dev's gallery lists the repositories that carry the topic `herdr-mod` or `herdr-layout`.

## A mod runs only once you allow it

A mod is a program. It can ask to run other programs, read and write your files, and reach the network. Before a mod runs, Swiftr reads its files and tells you what they ask for:

- Runs programs on your Mac and your machines
- Writes files anywhere you can, which lets it run programs too
- Reads files outside its own folder
- Reaches the network, and this Mac's own ports (web requests, and sockets to any host and port)
- Runs Swiftr commands: tabs, panes, spaces

It also names the programs and the sites it found. The mod stays off until you press Allow. Swiftr then holds the mod to that list: a mod allowed only to draw is refused when it tries to run a program. If the mod's files change and ask for more, it stops until you allow it again. Your OK covers kinds of action, not the exact code: a mod you allowed to run programs may run others after its files change. A mod added from a link asks again each time it is added.

Read a mod before you allow it, as you would a shell script. The list tells you what a mod can do, not what it will do.

Without asking, a mod can read and write its own folder and its own storage, and read what Swiftr shows: spaces, tabs, panes, agents and their state, the theme.

## Write a mod

```js
// ~/.config/swiftr/mods/hello/main.js
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

`render` gives back a tree of elements. Call `cx.notify()` when what you show changed. The builders (`div`, `v_flex`, `h_flex`, `p`, `gap`, `bg`, `rounded`, `on_click`, `hover`…) are herdr-app's. `~/.config/swiftr/API.md` lists the ones Swiftr knows, and `AGENTS.md` beside it says what a mod can read and do.

Without a layout file, Swiftr shows its own Changes panel and every mod you have in a sidebar on the window's right, one at a time, with their names at its top. The last button of the top row shows and hides it, and so does View › Show Mods Sidebar (⌥⌘B). Settings › Appearance picks its style: Floating, a panel on the terminals' card, which the tab makes room for, or Card, a column of the window with the mods on a card of their own (its button is then in it once shown, as the left sidebar's is). A right click on the button, or in the sidebar where a mod does nothing with one, picks the style too. Drag its edge to size it; a mod's menu in Settings › Mods takes that mod out of it. There a mod draws on the sidebar's surface: its outer box loses its fill, border and rounded corners, and `herdr.theme()` gives the terminals' colors, a shade lighter on a dark floating panel. To put the mod elsewhere, name it in a layout, or open it over the window: `{"overlay": {"kind": "dialog", "width": 560}}` in `mod.json`, then the command `mod.open` with `{"mod": "hello"}`.

Text in a panel can be selected with a drag and copied with ⌘C. A markdown block is taken whole.

### Controls, menus and motion

herdr-app's ready-made parts (`Button`, `Checkbox`, `Switch`, `Radio`, `Toggle`, `Link`, `Slider`, `NumberInput`, `Popover`, `HoverCard`, `Popup`, `Select`…) draw nothing of their own, there as here: the mod gives each its look, and the app gives it its behavior. In Swiftr that behavior is the Mac's:

- A press on a `Checkbox`, a `Switch` or a `Toggle` reports the new value to `on_change`; a `Link` opens its page; a slider follows the pointer; `disabled(true)` turns a part off.
- Tab and ⇧Tab go from part to part and from field to field. Space and Return press the part that has the keyboard, and the arrows move a slider. A part reached by Tab gets the Mac's focus ring unless the mod styles `focus(…)` itself.
- A `Popover` opens on a press and shuts on Escape or a press outside; a `HoverCard` opens when the pointer rests on its trigger. Both show in a layer over the window, so a menu can be wider than the sidebar that holds its button.
- `transition`, `spring`, `loop` and `frames` move `opacity`, `width`, `height`, `left` and `top` with no timer in the mod.
- `on_drop` takes files dropped from the Finder, and `drag_paths` lets you drag files out. A mod needs your leave to read files before it can hand over one from outside its own folder.
- VoiceOver reads each part by its role and its text, and presses it.

`AGENTS.md` has an example with a checkbox and a menu.

### Bytes, sums and sockets

herdr-app's Node-style modules are there: `buffer` (`Buffer`), `crypto` (`createHash`, `randomBytes`, `randomUUID`), `zlib` (`gzipSync`, `deflateSync` and their reverses), `net` (`connect(host, port)`) and `websocket` (`WebSocket.connect(url)`). `readFile(path)` with no encoding gives a file's bytes, and `writeFile` takes bytes. Sockets need the leave to reach the network; a mod holds 16 at most, and they close when it reloads or loses that leave.

## Check a mod without the app

```
~/.config/swiftr/bin/swiftr-mod check ~/.config/swiftr/mods/hello --json
~/.config/swiftr/bin/swiftr-mod shot  ~/.config/swiftr/mods/hello hello.png --width 360 --height 480
```

The tool is part of the app (`Swiftr --mod …`); from the source, `cd ModKit && swift build -c release` builds the same one as `.build/release/swiftr-mod`. `check` loads the mod, draws it once, and prints its errors, what it asked the app for, and the builder methods Swiftr doesn't know. `shot` also writes a picture of the panel. `--do "click:Add; type:name=text"` presses and types before the picture; `key:tab`, `hover:Text` and `drop:Text=/a/file` are steps too. `--data file.json` feeds it spaces, agents and a theme.

A mod checked this way never runs a program or reaches the network, and reads no file outside the folders you give it.

## Layouts

A layout is herdr-app's tree of rows, columns, stacks and blocks. Swiftr keeps its own sidebar, tab strip and terminals: herdr-app's own blocks (`spaces`, `agents`, `tabs`, `workspace-status`…) are left out, the block with `{"tab": "active"}` is the shown tab, and blocks with `{"mod": "<name>"}` are your mods around it.

```json
{
  "type": "row",
  "children": [
    { "type": "block", "id": "main", "content": { "tab": "active" } },
    { "type": "column", "id": "panel", "size": { "px": 360 }, "min": 280, "max": 900,
      "children": [
        { "type": "stack", "id": "panel-body", "active": "hello", "children": [
          { "type": "block", "id": "hello", "content": { "mod": "hello" } }
        ] }
      ] }
  ]
}
```

A part with a `px` size can be dragged by its edge. Mods and keys change the layout with `layout.show`, `layout.hide`, `layout.toggle`, `layout.select`, `layout.resize` and `layout.switch`. What you hide, pick or resize is kept in `data/`, so the layout file stays as it was shared.

A stack that would open on a mod you don't have opens on the first one you have.

Swiftr's own layout, used when you pick no file, is a row of the tab and a column named `panel` that holds a stack named `panel-body`, one block per mod, each block named after its mod: the names herdr-app's main layout uses, so `layout.toggle {"id": "panel"}` and `layout.select {"stack": "panel-body", "child": "<mod>"}` work in both.

To share a layout, send its JSON file and the folders of the mods it names.

## Keys

`keys.json` maps a chord to a command:

```json
{ "cmd-shift-p": { "command": "layout.toggle", "args": { "id": "panel" } } }
```

## What is not there yet

- herdr-app's Files panel: a layout that shows it gets a note in its place. A block that names `changes` gets Swiftr's own Changes panel: the uncommitted changes of the focused terminal's folder, read with `git` and never written.
- A few parts: `DockArea`, `DatePicker`, `OtpInput`, and tokens inside a field. `swiftr-mod check` lists the builders a mod uses that Swiftr doesn't know.
- `on_pinch` never fires, and `drag_paths` drags nothing when its files are on another machine.
- Scrolling has no rubber band and no thumb to drag.
- Node's `fs` and `child_process`, which herdr-app lacks too. A mod reads files through `fs/promises` and runs programs through `exec` from `"herdr"`.
- A listening socket (`createServer`), and the browser's `new WebSocket()`.
