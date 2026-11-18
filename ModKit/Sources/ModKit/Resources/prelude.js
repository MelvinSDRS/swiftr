// What a mod's script runs on: the modules a mod imports ("gpui-kit",
// "gpui-base", "herdr", ...), written against herdr-app's API so its mods run
// here unchanged.
//
// A mod describes its panel with chained builders (`div().flex().child(…)`).
// Here a builder only records what was asked: `render` ends as one JSON
// string, which Swiftr lays out and draws itself. Nothing in this file draws.
//
// `__native` is Swiftr's side (ModRuntime.swift).
(function (global) {
  "use strict";

  var native = global.__native;
  var REM = 16;

  // ---- The copies of the mod (one View instance each) -------------------------------------

  var views = new Map();     // id -> record
  var current = null;        // the record whose code is running
  var inRender = false;

  // Runs a copy's code. What it awaits goes on after this returns, before
  // Swiftr gets the hand back: so a call from Swiftr (no copy running yet)
  // leaves its copy as the current one, for that code to find.
  function enter(record, body) {
    var before = current;
    current = record;
    try { return body(); } catch (e) { report(record, e); return undefined; } finally { if (before) current = before; }
  }

  function report(record, error) {
    var text = error && error.stack ? String(error) + "\n" + error.stack : String(error);
    native.error(record ? record.id : 0, text);
  }

  // ---- Lengths and colors -----------------------------------------------------------------

  // A length as the layout takes it: px as a number, "50%", or "auto".
  function len(v) {
    if (typeof v === "number") return v;
    if (typeof v !== "string") return v == null ? undefined : Number(v) || 0;
    if (v === "auto") return v;
    var n = parseFloat(v);
    if (isNaN(n)) return undefined;
    if (v.charCodeAt(v.length - 1) === 37) return n + "%";
    if (v.length > 3 && v.slice(-3) === "rem") return n * REM;
    return n;
  }

  // Tailwind's suffixes: p_2 is 8px, w_full is 100%, w_1_2 is 50%, h_px is 1px, p_0p5 is 2px.
  function suffixLength(s) {
    if (s === "full") return "100%";
    if (s === "auto") return "auto";
    if (s === "px") return 1;
    var frac = /^(\d+)_(\d+)$/.exec(s);
    if (frac) return (Number(frac[1]) / Number(frac[2]) * 100) + "%";
    var num = /^(\d+)(?:p(\d+))?$/.exec(s);
    if (num) return Number(num[1] + (num[2] ? "." + num[2] : "")) * 4;
    return undefined;
  }

  // ---- Elements ---------------------------------------------------------------------------

  function El(kind) {
    this.k = kind;
    this.s = {};
    this.c = undefined;
  }
  var P = El.prototype;

  function isChild(x) { return x !== null && x !== undefined && x !== false && x !== true; }

  // What a child becomes in the tree: an element, a string, or a nested view's own tree.
  function childNode(x) {
    if (x instanceof El) return x;
    if (x instanceof Entity) return x.render();
    if (typeof x === "string") return x;
    if (typeof x === "number") return String(x);
    if (Array.isArray(x)) { var g = new El("frag"); g.children(x); return g; }
    if (x && typeof x.render === "function" && x instanceof View) return renderInline(x);
    return String(x);
  }

  P.child = function (x) {
    if (isChild(x)) (this.c || (this.c = [])).push(childNode(x));
    return this;
  };
  P.children = function (xs) {
    if (xs == null) return this;
    if (typeof xs[Symbol.iterator] !== "function") return this.child(xs);
    for (var x of xs) if (isChild(x)) (this.c || (this.c = [])).push(childNode(x));
    return this;
  };
  P.when = function (cond, then) { if (cond) { var r = then(this); return r instanceof El ? r : this; } return this; };
  P.when_some = function (value, then) { if (value != null) { var r = then(this, value); return r instanceof El ? r : this; } return this; };
  P.when_else = function (cond, then, otherwise) { var r = cond ? then(this) : otherwise(this); return r instanceof El ? r : this; };
  P.map = function (f) { var r = f(this); return r instanceof El ? r : this; };
  P.id = function (v) { this.i = String(v); return this; };
  // JSON.stringify writes an element's own fields as they are. (Looked up on every element:
  // defined here so the lookup stops before the catch-all below.)
  P.toJSON = undefined;
  // Fields an element may hold, named here so that reading one that isn't
  // set stops before the catch-all too.
  P.hs = undefined; P.st = undefined; P.loops = undefined; P.anim = undefined; P.i = undefined;
  P.slots = undefined; P.pop = undefined; P.mo = undefined; P.a = undefined;
  P.toString = function () { return "[element " + this.k + "]"; };
  P.valueOf = function () { return this; };

  function set(name, key, value) { P[name] = function () { this.s[key] = value; return this; }; }
  function arg(name, key, convert) {
    P[name] = function (v) { var x = convert ? convert(v) : v; if (x !== undefined) this.s[key] = x; return this; };
  }

  // Sizes and spacing: `.w(240)`, `.w("50%")`, and the suffixed forms through `fallback` below.
  var LENGTHS = {
    w: ["w"], h: ["h"], size: ["w", "h"], min_w: ["minw"], min_h: ["minh"], max_w: ["maxw"], max_h: ["maxh"],
    min_size: ["minw", "minh"], max_size: ["maxw", "maxh"],
    p: ["pt", "pr", "pb", "pl"], px: ["pl", "pr"], py: ["pt", "pb"], pt: ["pt"], pr: ["pr"], pb: ["pb"], pl: ["pl"],
    m: ["mt", "mr", "mb", "ml"], mx: ["ml", "mr"], my: ["mt", "mb"], mt: ["mt"], mr: ["mr"], mb: ["mb"], ml: ["ml"],
    gap: ["gx", "gy"], gap_x: ["gx"], gap_y: ["gy"],
    top: ["top"], right: ["right"], bottom: ["bottom"], left: ["left"],
    inset: ["top", "right", "bottom", "left"], inset_x: ["left", "right"], inset_y: ["top", "bottom"],
    flex_basis: ["fb"], basis: ["fb"],
  };
  Object.keys(LENGTHS).forEach(function (name) {
    var keys = LENGTHS[name];
    P[name] = function (v) {
      var x = len(v);
      if (x === undefined) return this;
      for (var i = 0; i < keys.length; i++) this.s[keys[i]] = x;
      return this;
    };
  });
  P.size_full = function () { this.s.w = "100%"; this.s.h = "100%"; return this; };

  set("flex", "d", "flex"); set("block", "d", "block"); set("hidden", "d", "none"); set("grid", "d", "flex");
  set("invisible", "vis", 0); set("visible", "vis", 1);
  set("flex_row", "fd", "row"); set("flex_col", "fd", "column");
  set("flex_row_reverse", "fd", "row-reverse"); set("flex_col_reverse", "fd", "column-reverse");
  set("flex_wrap", "fw", 1); set("flex_wrap_reverse", "fw", 2); set("flex_nowrap", "fw", 0);
  P.flex_1 = function () { this.s.fg = 1; this.s.fs = 1; this.s.fb = "0%"; return this; };
  P.flex_auto = function () { this.s.fg = 1; this.s.fs = 1; this.s.fb = "auto"; return this; };
  P.flex_initial = function () { this.s.fg = 0; this.s.fs = 1; this.s.fb = "auto"; return this; };
  P.flex_none = function () { this.s.fg = 0; this.s.fs = 0; return this; };
  P.flex_grow = function (v) { this.s.fg = v === undefined ? 1 : Number(v); return this; };
  P.flex_shrink = function (v) { this.s.fs = v === undefined ? 1 : Number(v); return this; };
  set("flex_grow_0", "fg", 0); set("flex_shrink_0", "fs", 0); set("flex_shrink_1", "fs", 1); set("flex_grow_1", "fg", 1);
  ["start", "center", "end", "baseline", "stretch"].forEach(function (v) {
    set("items_" + v, "ai", v); set("self_" + v, "as", v);
  });
  set("self_flex_start", "as", "start"); set("self_flex_end", "as", "end"); set("self_auto", "as", "auto");
  ["start", "center", "end", "between", "around", "evenly"].forEach(function (v) {
    set("justify_" + v, "jc", v); set("content_" + v, "ac", v);
  });
  set("content_stretch", "ac", "stretch");
  set("relative", "pos", "relative"); set("absolute", "pos", "absolute");
  P.aspect_ratio = function (v) { this.s.ar = Number(v); return this; };
  set("aspect_square", "ar", 1);

  // Overflow. The scrollbar forms differ only by the bar, which the Mac draws itself.
  set("overflow_hidden", "ov", "hidden"); P.overflow_visible = function () { delete this.s.ov; delete this.s.ovx; delete this.s.ovy; return this; };
  set("overflow_x_hidden", "ovx", "hidden"); set("overflow_y_hidden", "ovy", "hidden");
  ["overflow_scroll", "overflow_scrollbar", "scrollable"].forEach(function (n) { set(n, "ov", "scroll"); });
  ["overflow_x_scroll", "overflow_x_scrollbar"].forEach(function (n) { set(n, "ovx", "scroll"); });
  ["overflow_y_scroll", "overflow_y_scrollbar"].forEach(function (n) { set(n, "ovy", "scroll"); });

  // Paint.
  P.bg = function (v) { if (v != null) this.s.bg = v instanceof Background ? v.spec : v; return this; };
  arg("border_color", "bc"); arg("opacity", "op", Number);
  function borders(name, keys) {
    P[name] = function (v) { var x = v === undefined ? 1 : Number(v); for (var i = 0; i < keys.length; i++) this.s[keys[i]] = x; return this; };
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 16, 20, 24, 32].forEach(function (n) {
      P[name + "_" + n] = function () { for (var i = 0; i < keys.length; i++) this.s[keys[i]] = n; return this; };
    });
  }
  borders("border", ["bt", "br", "bb", "bl"]); borders("border_t", ["bt"]); borders("border_r", ["br"]);
  borders("border_b", ["bb"]); borders("border_l", ["bl"]); borders("border_x", ["bl", "br"]); borders("border_y", ["bt", "bb"]);
  set("border_dashed", "bs", "dashed"); set("border_solid", "bs", "solid");
  // A line around a box, to see where it is while writing a mod.
  var DEBUG = { red: "#ef4444", green: "#22c55e", blue: "#3b82f6", yellow: "#eab308", pink: "#ec4899" };
  Object.keys(DEBUG).forEach(function (c) {
    P["debug_" + c] = function () { this.s.bt = this.s.br = this.s.bb = this.s.bl = 1; this.s.bc = DEBUG[c]; return this; };
  });
  var RADII = { none: 0, xs: 2, sm: 2, md: 6, lg: 8, xl: 12, "2xl": 16, "3xl": 24, full: 9999 };
  function radius(name, keys) {
    P[name] = function (v) { var x = v === undefined ? 4 : len(v); for (var i = 0; i < keys.length; i++) this.s[keys[i]] = x; return this; };
    Object.keys(RADII).forEach(function (r) {
      P[name + "_" + r] = function () { for (var i = 0; i < keys.length; i++) this.s[keys[i]] = RADII[r]; return this; };
    });
  }
  radius("rounded", ["rtl", "rtr", "rbr", "rbl"]); radius("rounded_t", ["rtl", "rtr"]); radius("rounded_b", ["rbl", "rbr"]);
  radius("rounded_l", ["rtl", "rbl"]); radius("rounded_r", ["rtr", "rbr"]);
  radius("rounded_tl", ["rtl"]); radius("rounded_tr", ["rtr"]); radius("rounded_bl", ["rbl"]); radius("rounded_br", ["rbr"]);
  ["2xs", "xs", "sm", "md", "lg", "xl", "2xl"].forEach(function (v) { set("shadow_" + v, "sh", v); });
  set("shadow", "sh", "md"); set("shadow_none", "sh", "none");

  // Text. A node's text style reaches the text under it.
  arg("text_color", "tc"); arg("font_family", "ff"); arg("text_size", "ts", len);
  var SIZES = { xs: 12, sm: 14, base: 16, lg: 18, xl: 20, "2xl": 24, "3xl": 30 };
  Object.keys(SIZES).forEach(function (k) { set("text_" + k, "ts", SIZES[k]); });
  var WEIGHTS = { thin: 100, extralight: 200, light: 300, normal: 400, medium: 500, semibold: 600, bold: 700, extrabold: 800, black: 900 };
  Object.keys(WEIGHTS).forEach(function (k) { set("font_" + k, "wt", WEIGHTS[k]); });
  P.font_weight = function (v) { this.s.wt = typeof v === "number" ? v : (WEIGHTS[String(v).toLowerCase()] || 400); return this; };
  // A number is a multiple of the text size ("1.5"), a string a length ("18px").
  P.line_height = function (v) { this.s.lh = typeof v === "number" ? (v <= 4 ? "x" + v : v) : len(v); return this; };
  var LEADING = { none: 1, tight: 1.25, snug: 1.375, normal: 1.5, relaxed: 1.625, loose: 2 };
  Object.keys(LEADING).forEach(function (k) { set("leading_" + k, "lh", "x" + LEADING[k]); });
  set("italic", "it", 1); set("not_italic", "it", 0); set("underline", "ul", 1); set("line_through", "st", 1);
  set("text_left", "ta", "left"); set("text_center", "ta", "center"); set("text_right", "ta", "right");
  set("whitespace_nowrap", "ws", "nowrap"); set("whitespace_normal", "ws", "normal");
  P.truncate = function () { this.s.ws = "nowrap"; this.s.el = 1; this.s.ov = "hidden"; return this; };
  set("text_ellipsis", "el", 1);
  P.line_clamp = function (n) { this.s.lc = Number(n); this.s.ov = "hidden"; return this; };
  ["pointer", "text", "default", "grab", "grabbing", "crosshair", "not_allowed", "move", "col_resize", "row_resize", "ew_resize", "ns_resize",
   "alias", "copy", "context_menu", "e_resize", "w_resize", "n_resize", "s_resize", "nesw_resize", "nwse_resize", "vertical_text"].forEach(function (c) {
    set("cursor_" + c, "cur", c);
  });
  P.cursor = function (v) { this.s.cur = String(v); return this; };
  set("cursor_no_drop", "cur", "not_allowed");
  set("text_ellipsis_middle", "el", 1); set("text_ellipsis_start", "el", 1);
  // The line under text: how thick, and its shape. A thickness draws the line.
  [0, 1, 2, 4, 8].forEach(function (n) {
    P["text_decoration_" + n] = function () { this.s.ul = n > 0 ? 1 : 0; this.s.ulw = n; return this; };
  });
  set("text_decoration_none", "ul", 0); set("text_decoration_solid", "uls", "solid"); set("text_decoration_wavy", "uls", "wavy");
  arg("text_bg", "tbg");
  set("content_normal", "ac", "stretch");
  // `grid()` lays out as a wrapping row here: a cell that spans the grid is a full row of it.
  set("col_span_full", "w", "100%");
  ["col_start_auto", "col_end_auto", "row_span_full", "row_start_auto", "row_end_auto"].forEach(function (n) { P[n] = function () { return this; }; });

  // What a screen reader is told. Nothing here changes what is drawn.
  function told(name, key, convert) {
    P[name] = function (v) { (this.a || (this.a = {}))[key] = convert ? convert(v) : v; return this; };
  }
  var flag = function (v) { return v === undefined ? true : Boolean(v); };
  told("role", "role", String); told("aria_label", "label", String); told("accessibility_label", "label", String);
  told("aria_selected", "selected", flag); told("aria_expanded", "expanded", flag); told("aria_checked", "checked", flag);
  told("aria_active_descendant", "active", flag); told("aria_level", "level", Number); told("axis", "axis", String);
  told("row_count", "rows", Number); told("column_count", "columns", Number);
  P.set_position = function (position, size) { (this.a || (this.a = {})).position = [Number(position), Number(size)]; return this; };
  // A `Progress` announces this; a field's state has its own `value()`.
  P.value = function (percent) { (this.a || (this.a = {})).value = Math.max(0, Math.min(100, Number(percent) || 0)); return this; };

  // Looks that depend on the pointer: the callback styles a blank element, which becomes the difference.
  function refinement(key) {
    return function (a, b) {
      var f = typeof a === "function" ? a : b;
      if (typeof f !== "function") return this;
      var probe = new El("style");
      f(probe);
      this.s[key] = probe.s;
      if (typeof a === "string") this.s[key + "g"] = a;
      return this;
    };
  }
  P.hover = refinement("hover"); P.active = refinement("active"); P.focus = refinement("focus");
  P.focus_visible = refinement("focus"); P.in_focus = refinement("focus");
  P.group = function (name) { this.s.group = String(name); return this; };
  P.group_hover = refinement("ghover"); P.group_active = refinement("gactive");
  P.tooltip = function (v) { if (typeof v === "string" && v) this.tip = v; return this; };
  P.occlude = function () { this.s.block = 1; return this; };
  P.block_mouse_except_scroll = P.occlude;

  // Motion Swiftr runs by itself: no script, no timer.
  P.spin = function (ms) { this.anim = Object.assign(this.anim || {}, { spin: Math.max(100, Number(ms) || 1000) }); return this; };
  P.frames = function (list, ms) { this.anim = Object.assign(this.anim || {}, { frames: (list || []).map(String), ms: Math.max(16, Number(ms) || 100) }); return this; };
  P.loop = function (property, policy) { (this.loops || (this.loops = [])).push(Object.assign({ p: String(property) }, policy)); return this; };
  // A property that moves to its new value when a later render changes it.
  P.transition = function (property, policy) {
    var p = typeof policy === "number" ? { duration: policy } : policy || {};
    (this.mo || (this.mo = {}))[String(property)] = { ms: Number(p.duration) || 0, delay: Number(p.delay) || 0, easing: p.easing || "ease-in-out" };
    return this;
  };
  P.spring = function (property, policy) {
    var p = policy || {};
    (this.mo || (this.mo = {}))[String(property)] = { spring: 1, response: Number(p.response) || 300, damping: p.damping == null ? 1 : Number(p.damping), epsilon: Number(p.epsilon) || 0 };
    return this;
  };

  // ---- Handlers ---------------------------------------------------------------------------

  // A handler becomes its index in its copy's table for this render.
  function handler(f) {
    var table = current ? current.handlers : null;
    if (!table || typeof f !== "function") return undefined;
    table.push(f);
    return table.length - 1;
  }
  function on(name, key) {
    P[name] = function (f) { var h = handler(f); if (h !== undefined) (this.hs || (this.hs = {}))[key] = h; return this; };
  }
  on("on_click", "click"); on("on_double_click", "dbl"); on("on_mouse_move", "move"); on("on_hover", "hover");
  on("on_scroll_wheel", "wheel"); on("on_key_down", "keydown"); on("on_key_up", "keyup"); on("on_drop", "drop");
  on("on_size_change", "size"); on("on_mouse_down_out", "downout"); on("on_any_mouse_down", "down_any");
  on("on_change", "change"); on("on_link_click", "link"); on("on_modifiers_changed", "mods");
  on("on_item_click", "item"); on("on_item_secondary_click", "item2"); on("on_open_change", "open");
  function onButton(name, key) {
    P[name] = function (button, f) {
      if (typeof button === "function") { f = button; button = "left"; }
      var h = handler(f);
      if (h !== undefined) (this.hs || (this.hs = {}))[key + "_" + button] = h;
      return this;
    };
  }
  onButton("on_mouse_down", "down"); onButton("on_mouse_up", "up");
  P.on_action = function (name, f) {
    var h = handler(f);
    if (h !== undefined) ((this.hs || (this.hs = {})).actions || (this.hs.actions = {}))[String(name)] = h;
    return this;
  };
  P.key_context = function (v) { this.kc = String(v); return this; };
  P.track_focus = function (handle) { if (handle && handle.id) this.fh = handle.id; return this; };
  P.track_scroll = function (handle) { if (handle && handle.id) this.sc = handle.id; return this; };
  // Where Tab lands: `tab_index` makes a stop and places it, `tab_stop(false)` takes one out.
  P.tab_index = function (n) { this.ti = Number(n) || 0; return this; };
  P.tab_stop = function (v) { this.tstop = v === undefined || v ? 1 : 0; return this; };
  P.content_focus_handle = function (handle) { if (handle && handle.id) this.cfh = handle.id; return this; };
  on("on_confirm", "confirm"); on("on_dismiss", "dismiss"); on("on_step", "step"); on("on_resize", "resize"); on("on_pinch", "pinch");

  // Controls' own state, for the ones the script styles (Checkbox, Switch, Button…).
  ["disabled", "checked", "selected", "loading", "active_state", "open", "readonly", "pressed", "indeterminate", "keep_mounted", "start", "controls_right"].forEach(function (name) {
    P[name] = function (v) { (this.st || (this.st = {}))[name] = v === undefined ? true : Boolean(v); return this; };
  });
  P.selectable = function (v) { this.sel = v === undefined ? 1 : (v ? 1 : 0); return this; };
  P.label = function (v) { return this.child(v); };
  P.href = function (url) { this.url = String(url); return this; };
  P.drag_paths = function (paths, options) {
    this.drag = { paths: (paths || []).map(String), on: options && options.on != null ? String(options.on) : null };
    return this;
  };

  // A part's named places: the element is used there, and isn't also a child.
  ["content", "trigger", "header", "footer", "panel", "fallback", "image", "input", "decrement_button", "increment_button"].forEach(function (name) {
    P[name] = function (x) { if (isChild(x)) (this.slots || (this.slots = {}))[name] = childNode(x); return this; };
  });
  // A surface that opens from its trigger (`Popup`, `Popover`, `HoverCard`): where it sits, what opens and shuts it.
  function surface(name, key, convert) {
    P[name] = function (v) { (this.pop || (this.pop = {}))[key] = convert ? convert(v) : v; return this; };
  }
  surface("anchor", "anchor", String); surface("default_open", "default_open", Boolean); surface("overlay_closable", "closable", Boolean);
  surface("mouse_button", "button", String); surface("open_delay", "open_delay", Number); surface("close_delay", "close_delay", Number);
  P.range_style = refinement("range");
  // herdr-app's placed scroll bar: Swiftr draws its own over what scrolls.
  ["mode", "scroll_size", "viewport_from_layout", "with_item_to_measure_index", "frame_budget"].forEach(function (n) { P[n] = function () { return this; }; });

  // Anything else a mod calls: a suffixed length (`p_2`, `w_full`, `gap_1p5`), else a method
  // Swiftr doesn't have yet. That one is noted, and does nothing, so the rest of the panel shows.
  function fallback(name) {
    var cut = name.indexOf("_");
    while (cut > 0) {
      var base = name.slice(0, cut), keys = LENGTHS[base];
      if (keys) {
        var x = suffixLength(name.slice(cut + 1));
        if (x !== undefined) {
          return function () { for (var i = 0; i < keys.length; i++) this.s[keys[i]] = x; return this; };
        }
        if (name.slice(cut + 1, cut + 5) === "neg_") {
          var y = suffixLength(name.slice(cut + 5));
          if (typeof y === "number") return function () { for (var i = 0; i < keys.length; i++) this.s[keys[i]] = -y; return this; };
        }
      }
      cut = name.indexOf("_", cut + 1);
    }
    native.unsupported(name);
    return function () { return this; };
  }
  Object.setPrototypeOf(P, new Proxy(Object.create(null), {
    get: function (_target, name) {
      if (typeof name !== "string" || name === "then") return undefined;
      var f = fallback(name);
      P[name] = f;
      return f;
    },
    has: function () { return false; },
  }));

  function div() { return new El("div"); }
  function h_flex() { var e = new El("div"); e.s.d = "flex"; e.s.fd = "row"; e.s.ai = "center"; return e; }
  function v_flex() { var e = new El("div"); e.s.d = "flex"; e.s.fd = "column"; return e; }
  function svg(path) { var e = new El("svg"); e.src = String(path); return e; }
  function image(path) { var e = new El("img"); e.src = String(path); return e; }
  // A ready-made part: a box that draws nothing of its own and knows what it is, so Swiftr
  // answers a press or a key on it (a `Checkbox` reports its change, a `Link` opens its page).
  function part(kind) {
    return { new: function (id, index) {
      var e = new El("div");
      e.part = kind;
      if (id !== undefined && typeof id !== "object") e.i = String(id);
      // A table's row or cell: its place, counted from 1, for a screen reader.
      if (typeof index === "number") e.a = { index: index };
      return e;
    } };
  }

  // ---- Backgrounds and paths --------------------------------------------------------------

  function Background(spec) { this.spec = spec; }
  Background.prototype.opacity = function (f) { return new Background(Object.assign({}, this.spec, { opacity: Number(f) })); };
  Background.prototype.color_space = function () { return this; };
  var BackgroundModule = {
    solid: function (color) { return new Background({ solid: color }); },
    stop: function (color, percentage) { return { color: color, at: percentage }; },
    linear_gradient: function (angle, from, to) {
      var stop = function (x, at) { return typeof x === "string" ? { color: x, at: at } : x; };
      return new Background({ gradient: [stop(from, 0), stop(to, 1)], angle: Number(angle) });
    },
    pattern_slash: function (color, width, interval) { return new Background({ slash: color, width: width, interval: interval }); },
    checkerboard: function (color, size) { return new Background({ checker: color, size: size }); },
  };

  function PathB(mode, width) { this.ops = []; this.mode = mode; this.width = width; }
  var PB = PathB.prototype;
  PB.move_to = function (x, y) { this.ops.push(["M", x, y]); return this; };
  PB.line_to = function (x, y) { this.ops.push(["L", x, y]); return this; };
  PB.curve_to = function (x, y, cx, cy) { this.ops.push(["Q", cx, cy, x, y]); return this; };
  PB.cubic_bezier_to = function (x, y, ax, ay, bx, by) { this.ops.push(["C", ax, ay, bx, by, x, y]); return this; };
  PB.arc_to = function (rx, ry, rotation, large, sweep, x, y) { this.ops.push(["A", rx, ry, rotation, large ? 1 : 0, sweep ? 1 : 0, x, y]); return this; };
  PB.add_polygon = function (points, closed) {
    for (var i = 0; i < points.length; i++) this.ops.push([i === 0 ? "M" : "L", points[i][0], points[i][1]]);
    if (closed !== false) this.ops.push(["Z"]);
    return this;
  };
  PB.close = function () { this.ops.push(["Z"]); return this; };
  PB.dash_array = function (values) { this.dash = values; return this; };
  PB.build = function () { return this; };
  var PathBuilder = {
    fill: function () { return new PathB("fill", 0); },
    stroke: function (width) { return new PathB("stroke", Number(width) || 1); },
  };
  function paint_path(path, background) {
    var e = new El("path");
    e.path = { ops: path.ops, mode: path.mode, width: path.width, dash: path.dash };
    e.s.bg = background instanceof Background ? background.spec : background;
    return e;
  }

  // ---- Views ------------------------------------------------------------------------------

  function View(props) { this.props = props; }

  // A nested view a mod made with `cx.new(Class, props)`: drawn where it is used as a child.
  function Entity(owner, Class, props) {
    this.owner = owner;
    this.view = new Class(props);
    this.props = props;
    if (typeof this.view.init === "function") this.view.init(props, owner.cx);
  }
  Entity.prototype.set_props = function (props) {
    this.props = props;
    if (typeof this.view.update === "function") this.view.update(props);
    native.invalidate(this.owner.id);
  };
  Entity.prototype.release = function () { return true; };
  Entity.prototype.render = function () { return renderInline(this.view); };

  function renderInline(view) {
    var out = view.render(current ? current.cx : null);
    return out instanceof Entity ? out.render() : out instanceof El ? out : String(out == null ? "" : out);
  }

  var nextTimer = 1, timers = new Map();   // id -> { record, f, every }
  var nextHandle = 1;

  function Task(cancel) { this.done = false; this._cancel = cancel; }
  Task.prototype.cancel = function () { if (!this.done) { this.done = true; if (this._cancel) this._cancel(); } };
  Task.prototype.is_done = function () { return this.done; };

  function makeContext(record) {
    var startTimer = function (ms, f, every) {
      var id = nextTimer++;
      timers.set(id, { record: record, f: f, every: every });
      record.timers.add(id);
      native.timer(id, Math.max(0, Number(ms) || 0), every);
      return new Task(function () { timers.delete(id); record.timers.delete(id); native.cancelTimer(id); });
    };
    var cx = {
      notify: function () { if (!inRender) native.invalidate(record.id); },
      spawn: function (body) {
        var task = new Task(null);
        var result;
        try { result = enter(record, function () { return body(cx); }); } catch (e) { report(record, e); }
        if (result && typeof result.then === "function") {
          result.then(function () { task.done = true; }, function (e) { task.done = true; report(record, e); });
        } else { task.done = true; }
        return task;
      },
      sleep: function (ms) { return new Promise(function (resolve) { startTimer(ms, resolve, false); }); },
      timer: {
        after: function (ms, f) { return startTimer(ms, f, false); },
        every: function (ms, f) { return startTimer(ms, f, true); },
      },
      focus_handle: function () {
        var id = "f" + (nextHandle++);
        return {
          id: id,
          focus: function () { native.focus(record.id, id); },
          is_focused: function () { return record.focused === id; },
          release: function () { return true; },
        };
      },
      new: function (Class, props) { return new Entity(record, Class, props); },
      stop_propagation: function () { record.stopped = true; },
      propagate: function () { record.stopped = false; },
      phase: function () { return inRender ? "render" : "event"; },
      theme: function () { return baseTheme(); },
      open_url: function (url) { if (/^https?:\/\//i.test(String(url))) native.sync("open_url", JSON.stringify(String(url))); },
      read_from_clipboard: function () { var s = JSON.parse(native.sync("clipboard.read", "null")); return s == null ? undefined : s; },
      write_to_clipboard: function (text) { native.sync("clipboard.write", JSON.stringify(String(text))); },
      bind_keys: function (bindings) { (record.bindings || (record.bindings = [])).push.apply(record.bindings, bindings || []); native.invalidate(record.id); return (bindings || []).length; },
      window: null,
    };
    cx.window = makeWindow(record);
    return cx;
  }

  function makeWindow(record) {
    return {
      paint_path: paint_path,
      localStorage: storage(false), sessionStorage: storage(true),
      rem_size: function () { return REM; }, line_height: function () { return Math.round(REM * 1.618); },
      viewport_size: function () { var w = data("window") || {}; return { width: w.width || 0, height: w.height || 0 }; },
      bounds: function () { var w = data("window") || {}; return { x: 0, y: 0, width: w.width || 0, height: w.height || 0 }; },
      mouse_position: function () { return { x: 0, y: 0 }; },
      appearance: function () { return (data("settings") || {}).dark === false ? "light" : "dark"; },
      is_window_active: function () { return (data("window") || {}).active !== false; },
      is_fullscreen: function () { return Boolean((data("window") || {}).fullscreen); },
      is_maximized: function () { return Boolean((data("window") || {}).maximized); },
      refresh: function () { native.invalidate(record.id); },
      has_active_dialog: function () { return false; }, has_active_sheet: function () { return false; },
      dispatch_action: function (name) { native.sync("action", JSON.stringify({ view: record.id, action: String(name) })); },
      push_toast: function (o) { return herdr.notify({ title: o.title, body: o.description, level: o.level, timeout: o.timeout }); },
      focus_next: function () { native.sync("focus.move", JSON.stringify({ view: record.id, by: 1 })); },
      focus_prev: function () { native.sync("focus.move", JSON.stringify({ view: record.id, by: -1 })); },
      activate_window: function () {},
      minimize_window: function () { herdr.run("window.minimize"); }, zoom_window: function () { herdr.run("window.maximize"); },
      toggle_fullscreen: function () {}, set_rem_size: function () {},
    };
  }

  // ---- Controls with their own state ------------------------------------------------------

  var nextState = 1, states = new Map();

  function FieldState(kind, options) {
    options = options || {};
    this.id = "i" + (nextState++);
    this.kind = kind;
    this.owner = current;
    this.v = options.value == null ? "" : String(options.value);
    this.o = Object.assign({}, options);
    delete this.o.value;
    this.rev = 0;            // counts the script's own changes, so the field takes them
    this.listeners = {};
    states.set(this.id, this);
  }
  var FS = FieldState.prototype;
  FS.value = function () { return this.v; };
  FS.content = function () { return { text: this.v, tokens: [] }; };
  FS.tokens = function () { return []; };
  FS.set_value = function (next) {
    this.v = next == null ? "" : typeof next === "object" ? String(next.text || "") : String(next);
    this.rev++;
    if (this.owner) native.invalidate(this.owner.id);
  };
  FS.replace = function (text) { native.sync("field.replace", JSON.stringify({ id: this.id, text: String(text) })); };
  FS.replace_with_token = function (token) { this.replace(token && token.text || ""); };
  FS.replace_range_with_token = function (_range, token) { this.replace(token && token.text || ""); };
  FS.set_selected_range = function (range) { native.sync("field.select", JSON.stringify({ id: this.id, start: range.start, end: range.end })); };
  FS.on = function (event, f) { (this.listeners[event] || (this.listeners[event] = [])).push(f); return true; };
  FS.focus = function () { native.sync("field.focus", JSON.stringify({ id: this.id, view: this.owner ? this.owner.id : 0 })); };
  FS.release = function () { states.delete(this.id); return true; };
  ["masked", "loading", "step", "min", "max", "rows", "soft_wrap"].forEach(function (k) {
    FS["set_" + k] = function (v) { this.o[k] = v; if (this.owner) native.invalidate(this.owner.id); };
  });
  FS.set_auto_grow = function (min, max) { this.o.grow = [min, max]; if (this.owner) native.invalidate(this.owner.id); };

  function fieldElement(kind) {
    return function (state) {
      var e = new El(kind);
      // A field takes the room its row has left.
      e.s.fg = 1; e.s.fs = 1; e.s.fb = "0%"; e.s.minw = 0;
      if (state) { e.f = state.id; e.v = state.v; e.rev = state.rev; e.o = state.o; }
      return e;
    };
  }
  function stateType(kind) { return { new: function (options) { return new FieldState(kind, options); } }; }

  function SliderStateC(options) {
    options = options || {};
    FieldState.call(this, "slider", {});
    this.min = options.min == null ? 0 : options.min; this.max = options.max == null ? 100 : options.max;
    this.step = options.step == null ? 1 : options.step;
    this.scale = options.scale === "logarithmic" ? "logarithmic" : "linear";
    this.v = options.value == null ? this.min : options.value;
  }
  SliderStateC.prototype = Object.create(FS);
  SliderStateC.prototype.value = function () { return this.v; };
  SliderStateC.prototype.set_value = function (next) { this.v = next; this.rev++; if (this.owner) native.invalidate(this.owner.id); };
  SliderStateC.prototype.min_value = function () { return this.min; };
  SliderStateC.prototype.max_value = function () { return this.max; };
  SliderStateC.prototype.step_value = function () { return this.step; };
  // The four parts of a slider read one state: Swiftr places the fill and the thumb from it,
  // and a drag writes it without asking the script to describe the panel again.
  function sliderPart(kind) {
    return { new: function (state) {
      var e = new El("div");
      e.part = kind;
      if (state) { e.sl = state.id; e.v = state.v; e.o = { min: state.min, max: state.max, step: state.step, scale: state.scale }; }
      return e;
    } };
  }
  // A field with steps: the frame around the editor and its two buttons.
  function numberInput(state) {
    var e = new El("div");
    e.part = "number";
    e.s.d = "flex"; e.s.fd = "row"; e.s.ai = "center";
    if (state) { e.num = state.id; e.editor = fieldElement("input")(state); }
    return e;
  }
  function stepped(state, action) {
    var step = state.o.step == null ? 1 : Number(state.o.step);
    if (!step) return;
    var now = parseFloat(state.v);
    if (isNaN(now)) now = 0;
    var next = now + (action === "increment" ? step : -step);
    if (state.o.min != null) next = Math.max(Number(state.o.min), next);
    if (state.o.max != null) next = Math.min(Number(state.o.max), next);
    // No stray digits from the sum of two fractions.
    state.set_value(String(Math.round(next * 1e9) / 1e9));
  }

  var nextScroll = 1;
  function scrollHandle() {
    var id = "s" + (nextScroll++), owner = current;
    return {
      id: id,
      scroll_to_item: function (index, strategy) { native.sync("scroll.item", JSON.stringify({ view: owner ? owner.id : 0, id: id, index: index, strategy: strategy || null })); },
      scroll_to_bottom: function () { native.sync("scroll.item", JSON.stringify({ view: owner ? owner.id : 0, id: id, index: -1 })); },
      release: function () { return true; },
    };
  }

  // A long list: only the rows near what shows are described. Swiftr says which.
  function virtualList(kind) {
    return function (id, count, sizes, get_key, render) {
      if (kind === "ulist" || kind === "list") { render = get_key; get_key = sizes; sizes = null; }
      var e = new El(kind === "hlist" ? "hlist" : "vlist");
      e.i = String(id);
      count = Math.max(0, Number(count) || 0);
      e.n = count;
      if (sizes != null) e.sizes = sizes;
      var range = JSON.parse(native.sync("list.range", JSON.stringify({ view: current ? current.id : 0, id: e.i, count: count })));
      var start = Math.max(0, Math.min(count, range[0])), end = Math.max(start, Math.min(count, range[1]));
      e.from = start;
      var rows;
      if (kind === "list") { rows = []; for (var k = start; k < end; k++) rows.push(render(k, current ? current.cx : null)); }
      else rows = render({ start: start, end: end }, current ? current.cx : null) || [];
      e.c = [];
      // Each row's key, for the list's own `on_item_click`.
      var keys = typeof get_key === "function" ? [] : null;
      for (var j = 0; j < rows.length; j++) {
        if (!isChild(rows[j])) continue;
        e.c.push(childNode(rows[j]));
        if (keys) { try { keys.push(get_key(start + j)); } catch (error) { keys = null; } }
      }
      if (keys) e.keys = keys;
      return e;
    };
  }

  var TextView = {
    markdown: function (id, text) { var e = new El("md"); e.i = String(id); e.text = String(text == null ? "" : text); return e; },
    html: function (id, text) { var e = new El("md"); e.i = String(id); e.text = String(text == null ? "" : text).replace(/<[^>]+>/g, ""); return e; },
  };
  var Scrollbar = {
    new: function () { var e = new El("div"); e.s.d = "none"; return e; },
    vertical: function () { var e = new El("div"); e.s.d = "none"; return e; },
    horizontal: function () { var e = new El("div"); e.s.d = "none"; return e; },
  };
  // A surface that opens from its trigger. A `Popup` is a box around its trigger and shows
  // what its `content` holds; a `Popover` and a `HoverCard` are their trigger, and Swiftr
  // opens and shuts them.
  function popup(kind) {
    return { new: function (id, trigger) {
      var e = new El("div");
      e.part = kind;
      if (id !== undefined && typeof id !== "object") e.i = String(id);
      if (kind === "popup" && isChild(trigger)) e.slots = { trigger: childNode(trigger) };
      return e;
    } };
  }
  // Panes with a divider to drag between them. A pane's `size` is its first size along the
  // row or the column, and `visible` whether it shows: the two names mean that on a pane only.
  function resizable(axis) {
    return function (id) {
      var e = new El("div");
      e.part = "resizable";
      e.s.d = "flex"; e.s.fd = axis === "h" ? "row" : "column"; e.s.ai = "stretch"; e.s.w = "100%"; e.s.h = "100%";
      e.i = String(id);
      return e;
    };
  }
  function resizable_panel() {
    var e = new El("div");
    e.part = "pane";
    e.pane = {};
    e.size = function (px) { this.pane.size = Number(px); return this; };
    e.size_range = function (min, max) { this.pane.min = Number(min); if (max != null) this.pane.max = Number(max); return this; };
    e.visible = function (v) { this.pane.hidden = v === false ? 1 : 0; return this; };
    return e;
  }

  // ---- Data from Swiftr -------------------------------------------------------------------

  var raw = {}, parsed = {}, used = {};
  function data(key) {
    // What this mod reads: a change to the rest doesn't draw it again.
    used[key] = true;
    if (key in parsed) return parsed[key];
    var text = raw[key];
    var value = text === undefined ? null : JSON.parse(text);
    parsed[key] = value;
    return value;
  }
  // Lists are handed out as copies: a mod may sort the one it got.
  function list(key) { var v = data(key); return Array.isArray(v) ? v.slice() : []; }

  function baseTheme() {
    var t = data("theme") || {};
    var colors = {
      background: t.background, foreground: t.foreground, surface: t.surface, surface_foreground: t.foreground,
      primary: t.solid, primary_foreground: t.solid_foreground, secondary: t.raised, secondary_foreground: t.foreground,
      muted: t.raised, muted_foreground: t.muted, accent: t.accent, accent_foreground: t.accent_foreground,
      destructive: t.ansi1, destructive_foreground: t.background, border: t.border, input: t.input, ring: t.accent, selection: t.selection,
    };
    var dark = (data("settings") || {}).dark !== false;
    return Object.assign({ colors: colors, appearance: dark ? "dark" : "light", is_dark: dark,
      spacing: { xxs: 2, xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 },
      radius: { none: 0, sm: 4, md: 6, lg: 8, xl: 12, full: 9999 },
      typography: { sans: "system-ui", mono: "JetBrains Mono" } }, colors);
  }

  var nextCall = 1, calls = new Map();
  // A host call that answers later (a program run, a file read).
  function ask(name, args) {
    var id = nextCall++, owner = current;
    return new Promise(function (resolve, reject) {
      calls.set(id, { resolve: resolve, reject: reject, owner: owner });
      native.call(name, JSON.stringify(args === undefined ? null : args), id, owner ? owner.id : 0);
    });
  }
  function tell(name, args) {
    var out = native.sync(name, JSON.stringify(args === undefined ? null : args));
    return out === undefined || out === "" ? null : JSON.parse(out);
  }

  var herdr = {
    exec: function (command, args, options) { return ask("exec", { command: String(command), args: (args || []).map(String), options: options || {} }); },
    hc: function (args) { return ask("hc", { args: (args || []).map(String) }); },
    home: function () { return data("home") || ""; },
    appHome: function () { return data("appHome") || ""; },
    readTextFile: function (path, options) { return ask("readTextFile", { path: String(path), options: options || {} }); },
    writeTextFile: function (path, text, expected) { return ask("writeTextFile", { path: String(path), text: String(text), expected: expected == null ? null : String(expected) }); },
    knownAgents: function (options) { return ask("knownAgents", { options: options || {} }); },
    pickFolder: function (options) { return ask("pickFolder", { options: options || {} }); },
    playSound: function (sound) { tell("playSound", String(sound)); return null; },
    run: function (name, args) { tell("run", { name: String(name), args: args || {}, view: current ? current.id : 0 }); return null; },
    machines: function () { return list("machines"); },
    spaces: function () { return list("spaces"); },
    agents: function () { return list("agents"); },
    panes: function () { return list("panes"); },
    terminals: function () { return list("terminals"); },
    setAgentOrder: function (addresses) { tell("setAgentOrder", addresses || []); return null; },
    focused: function () { return data("focused"); },
    layout: function () { return data("layout"); },
    layouts: function () { return list("layouts"); },
    commands: function () { return list("commands"); },
    window: function () { return data("window") || { platform: "macos", titlebar: "system", buttons: false, maximized: false, fullscreen: false, active: true }; },
    placement: function () { return current && current.placement || null; },
    theme: function () { return data("theme") || {}; },
    themes: function () { return list("themes"); },
    fonts: function () { return list("fonts"); },
    updates: function () { return data("updates") || { app: { version: "", ready: null, updates: false }, notes: [], core: { version: null, managed: null, ready: null, updating: false, error: null }, checked: null, checks: false, checking: false }; },
    presentUpdateNotes: function () { return null; },
    telemetry: function () { return null; },
    settings: function () { return data("settings") || {}; },
    keys: function () { return list("keys"); },
    openOverlay: function (spec) { return tell("openOverlay", { spec: spec || {}, view: current ? current.id : 0 }); },
    closeOverlay: function (id) { tell("closeOverlay", id == null ? null : String(id)); return null; },
    notify: function (n) { return tell("notify", n || {}); },
    props: function () { return current ? current.props : {}; },
    shared: function (key) { var all = data("shared") || {}; var v = all[key]; return v === undefined ? null : v; },
    setShared: function (key, value) {
      var all = data("shared") || {};
      if (value === undefined || value === null) delete all[key]; else all[key] = value;
      tell("setShared", { key: String(key), value: value === undefined ? null : value });
      return null;
    },
    nextCommand: function () {
      var record = current;
      return new Promise(function (resolve) { if (record) record.commandWaiters.push(resolve); });
    },
    watchFolder: function (path) { return ask("watchFolder", { path: String(path) }); },
    feedbackPreview: function () { return { body: null, available: false }; },
    feedbackPasteImage: function () { return null; },
    feedbackPickImages: function () { return Promise.resolve([]); },
    feedbackAttachImages: function () { return []; },
    feedbackClearImages: function () { return null; },
    sendFeedback: function () { return Promise.resolve(null); },
  };

  // ---- Other built-ins --------------------------------------------------------------------

  function storage(session) {
    var memory = {};
    var read = function () {
      if (session) return memory;
      return tell("storage.read", { view: current ? current.id : 0 }) || {};
    };
    var write = function (all) { if (!session) tell("storage.write", { view: current ? current.id : 0, all: all }); };
    return {
      get length() { return Object.keys(read()).length; },
      key: function (index) { var k = Object.keys(read())[index]; return k === undefined ? null : k; },
      getItem: function (key) { var v = read()[key]; return v === undefined ? null : v; },
      setItem: function (key, value) { var all = read(); all[key] = String(value); write(all); },
      removeItem: function (key) { var all = read(); delete all[key]; write(all); },
      clear: function () { memory = {}; write({}); },
      flush: function () { return Promise.resolve(); },
    };
  }
  global.localStorage = storage(false);
  global.sessionStorage = storage(true);

  var say = function (level) {
    return function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) {
        var a = arguments[i];
        if (typeof a === "string") parts.push(a);
        else { try { parts.push(a instanceof Error ? String(a) : JSON.stringify(a)); } catch (e) { parts.push(String(a)); } }
      }
      native.log(level, parts.join(" "));
    };
  };
  global.console = { log: say("log"), info: say("info"), debug: say("debug"), warn: say("warn"), error: say("error") };

  function Headers(map) { this.map = map || {}; }
  Headers.prototype.get = function (name) { var v = this.map[String(name).toLowerCase()]; return v === undefined ? null : v; };
  Headers.prototype.has = function (name) { return String(name).toLowerCase() in this.map; };
  Headers.prototype.forEach = function (f) { for (var k in this.map) f(this.map[k], k); };
  global.fetch = function (url, options) {
    options = options || {};
    var headers = {};
    var h = options.headers || {};
    if (h instanceof Headers) h = h.map;
    for (var k in h) headers[k] = String(h[k]);
    var request = { url: String(url), method: options.method || "GET", headers: headers, body: null };
    if (isBytes(options.body)) request.bodyBytes = base64Of(bytesOf(options.body));
    else if (options.body != null) request.body = String(options.body);
    return ask("fetch", request).then(function (r) {
      return {
        ok: r.status >= 200 && r.status < 300, status: r.status, statusText: r.statusText || "", url: r.url || String(url),
        headers: new Headers(r.headers),
        text: function () { return Promise.resolve(r.body); },
        json: function () { return Promise.resolve(JSON.parse(r.body)); },
      };
    });
  };
  if (typeof global.queueMicrotask !== "function") global.queueMicrotask = function (f) { Promise.resolve().then(f); };
  if (typeof global.structuredClone !== "function") global.structuredClone = function (v) { return v === undefined ? undefined : JSON.parse(JSON.stringify(v)); };
  var B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  if (typeof global.btoa !== "function") global.btoa = function (s) {
    s = String(s); var out = "";
    for (var i = 0; i < s.length; i += 3) {
      var a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
      out += B64[a >> 2] + B64[((a & 3) << 4) | (b >> 4 || 0)] + (isNaN(b) ? "=" : B64[((b & 15) << 2) | (c >> 6 || 0)]) + (isNaN(c) ? "=" : B64[c & 63]);
    }
    return out;
  };
  if (typeof global.atob !== "function") global.atob = function (s) {
    s = String(s).replace(/[^A-Za-z0-9+/]/g, ""); var out = "";
    for (var i = 0; i < s.length; i += 4) {
      var n = (B64.indexOf(s[i]) << 18) | (B64.indexOf(s[i + 1]) << 12) | ((B64.indexOf(s[i + 2]) & 63) << 6) | (B64.indexOf(s[i + 3]) & 63);
      out += String.fromCharCode((n >> 16) & 255);
      if (s[i + 2] !== undefined) out += String.fromCharCode((n >> 8) & 255);
      if (s[i + 3] !== undefined) out += String.fromCharCode(n & 255);
    }
    return out;
  };

  // ---- Bytes: text coding, base64, Buffer ---------------------------------------------------

  function utf8Bytes(text) {
    text = String(text);
    var out = new Uint8Array(text.length * 3), n = 0;
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff && i + 1 < text.length) {
        var d = text.charCodeAt(i + 1);
        if (d >= 0xdc00 && d <= 0xdfff) { c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00); i++; }
      }
      // Half a pair by itself has no bytes of its own.
      if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
      if (c < 0x80) out[n++] = c;
      else if (c < 0x800) { out[n++] = 0xc0 | (c >> 6); out[n++] = 0x80 | (c & 63); }
      else if (c < 0x10000) { out[n++] = 0xe0 | (c >> 12); out[n++] = 0x80 | ((c >> 6) & 63); out[n++] = 0x80 | (c & 63); }
      else { out[n++] = 0xf0 | (c >> 18); out[n++] = 0x80 | ((c >> 12) & 63); out[n++] = 0x80 | ((c >> 6) & 63); out[n++] = 0x80 | (c & 63); }
    }
    return out.slice(0, n);
  }
  function charsText(codes) {
    var out = "";
    for (var i = 0; i < codes.length; i += 8192) out += String.fromCharCode.apply(null, codes.slice(i, i + 8192));
    return out;
  }
  function utf8Text(b, start, end) {
    var codes = [], i = start;
    while (i < end) {
      var c = b[i++], more = c < 0x80 ? 0 : c >= 0xc2 && c < 0xe0 ? 1 : c >= 0xe0 && c < 0xf0 ? 2 : c >= 0xf0 && c < 0xf5 ? 3 : -1;
      var p = more < 0 ? 0xfffd : more === 0 ? c : c & (0x3f >> more);
      for (var k = 0; k < more; k++) {
        if (i < end && (b[i] & 0xc0) === 0x80) p = (p << 6) | (b[i++] & 63); else { p = 0xfffd; more = -1; break; }
      }
      // A longer form than needed, or half a pair: not text.
      if ((more === 2 && p < 0x800) || (more === 3 && (p < 0x10000 || p > 0x10ffff)) || (p >= 0xd800 && p <= 0xdfff)) p = 0xfffd;
      if (p > 0xffff) { p -= 0x10000; codes.push(0xd800 + (p >> 10), 0xdc00 + (p & 0x3ff)); } else codes.push(p);
    }
    return charsText(codes);
  }
  // Base64 is Swiftr's work: over megabytes a loop here would take seconds.
  // `b` is a Uint8Array; the bytes come back in a new one. The address-safe
  // letters, line breaks and missing padding are all read.
  function base64Of(b) { return b.length ? native.b64(b) : ""; }
  function base64Bytes(text) { return native.unb64(String(text)); }
  function hexBytes(text) {
    text = String(text);
    var out = new Uint8Array(text.length >> 1), n = 0;
    for (; n < out.length; n++) {
      var v = parseInt(text.substr(n * 2, 2), 16);
      // As Node does: what comes before the first wrong digit.
      if (isNaN(v) || !/^[0-9a-fA-F]{2}$/.test(text.substr(n * 2, 2))) break;
      out[n] = v;
    }
    return out.slice(0, n);
  }
  function encodingName(encoding) {
    var name = String(encoding === undefined || encoding === null ? "utf8" : encoding).toLowerCase();
    return { "utf-8": "utf8", "binary": "latin1", "ucs2": "utf16le", "ucs-2": "utf16le", "utf-16le": "utf16le" }[name] || name;
  }
  var ENCODINGS = ["utf8", "hex", "base64", "base64url", "latin1", "ascii", "utf16le"];
  function encode(text, encoding) {
    text = String(text);
    var out, i;
    switch (encodingName(encoding)) {
    case "utf8": return utf8Bytes(text);
    case "hex": return hexBytes(text);
    case "base64": case "base64url": return base64Bytes(text);
    case "latin1": case "ascii":
      out = new Uint8Array(text.length);
      for (i = 0; i < text.length; i++) out[i] = text.charCodeAt(i) & 255;
      return out;
    case "utf16le":
      out = new Uint8Array(text.length * 2);
      for (i = 0; i < text.length; i++) { out[i * 2] = text.charCodeAt(i) & 255; out[i * 2 + 1] = text.charCodeAt(i) >> 8; }
      return out;
    default: throw new TypeError("Unknown encoding: " + encoding);
    }
  }
  function decode(b, encoding, start, end) {
    start = Math.max(0, start === undefined ? 0 : start | 0);
    end = Math.min(b.length, end === undefined ? b.length : end | 0);
    if (end <= start) return "";
    var codes = [], i, text;
    switch (encodingName(encoding)) {
    case "utf8": return utf8Text(b, start, end);
    case "hex":
      for (text = "", i = start; i < end; i++) text += (b[i] < 16 ? "0" : "") + b[i].toString(16);
      return text;
    case "base64": return base64Of(b.subarray(start, end));
    case "base64url": return base64Of(b.subarray(start, end)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    case "latin1": for (i = start; i < end; i++) codes.push(b[i]); return charsText(codes);
    case "ascii": for (i = start; i < end; i++) codes.push(b[i] & 127); return charsText(codes);
    case "utf16le": for (i = start; i + 1 < end; i += 2) codes.push(b[i] | (b[i + 1] << 8)); return charsText(codes);
    default: throw new TypeError("Unknown encoding: " + encoding);
    }
  }
  // Whatever a mod hands over as bytes, as one Uint8Array (not copied when
  // it is one already).
  function bytesOf(value, encoding) {
    if (typeof value === "string") return encode(value, encoding);
    if (value instanceof Uint8Array) return value;
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    if (value && value.type === "Buffer" && Array.isArray(value.data)) return Uint8Array.from(value.data);
    if (value && typeof value.length === "number") return Uint8Array.from(value);
    throw new TypeError("Expected a string or bytes");
  }
  function isBytes(value) { return value instanceof ArrayBuffer || ArrayBuffer.isView(value); }

  class Buffer extends Uint8Array {
    static from(value, encodingOrOffset, length) {
      if (typeof value === "string") return asBuffer(encode(value, encodingOrOffset));
      // Over an ArrayBuffer a Buffer shares the memory, as in Node.
      if (value instanceof ArrayBuffer) {
        var offset = encodingOrOffset || 0;
        return new Buffer(value, offset, length === undefined ? value.byteLength - offset : length);
      }
      return asBuffer(new Uint8Array(bytesOf(value)));
    }
    static alloc(size, fill, encoding) {
      var out = new Buffer(size);
      if (typeof fill === "number") out.fill(fill);
      else if (fill !== undefined && fill !== null) {
        var pattern = bytesOf(fill, encoding);
        for (var i = 0; pattern.length && i < size; i++) out[i] = pattern[i % pattern.length];
      }
      return out;
    }
    static allocUnsafe(size) { return new Buffer(size); }
    static isBuffer(value) { return value instanceof Buffer; }
    static isEncoding(encoding) { return ENCODINGS.indexOf(encodingName(encoding)) >= 0; }
    static byteLength(value, encoding) { return bytesOf(value, encoding).length; }
    static concat(list, total) {
      var parts = Array.prototype.map.call(list, function (item) { return bytesOf(item); });
      if (total === undefined) total = parts.reduce(function (sum, part) { return sum + part.length; }, 0);
      var out = new Buffer(total), at = 0;
      for (var i = 0; i < parts.length && at < total; i++) {
        var part = parts[i].length > total - at ? parts[i].subarray(0, total - at) : parts[i];
        out.set(part, at);
        at += part.length;
      }
      return out;
    }
    static compare(a, b) {
      a = bytesOf(a); b = bytesOf(b);
      for (var i = 0, n = Math.min(a.length, b.length); i < n; i++) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
      return a.length === b.length ? 0 : a.length < b.length ? -1 : 1;
    }
    toString(encoding, start, end) { return decode(this, encoding, start, end); }
    toJSON() { return { type: "Buffer", data: Array.prototype.slice.call(this) }; }
    equals(other) { return Buffer.compare(this, other) === 0; }
    compare(other) { return Buffer.compare(this, other); }
    // As in Node: the same memory, not a copy.
    slice(start, end) { return this.subarray(start, end); }
    write(text, offset, length, encoding) {
      if (typeof offset === "string") { encoding = offset; offset = 0; length = undefined; }
      else if (typeof length === "string") { encoding = length; length = undefined; }
      offset = offset || 0;
      var bytes = encode(text, encoding), room = Math.min(bytes.length, this.length - offset, length === undefined ? Infinity : length);
      this.set(bytes.subarray(0, Math.max(0, room)), offset);
      return Math.max(0, room);
    }
    copy(target, targetStart, sourceStart, sourceEnd) {
      targetStart = targetStart || 0; sourceStart = sourceStart || 0;
      sourceEnd = Math.min(sourceEnd === undefined ? this.length : sourceEnd, sourceStart + target.length - targetStart);
      if (sourceEnd <= sourceStart) return 0;
      target.set(this.subarray(sourceStart, sourceEnd), targetStart);
      return sourceEnd - sourceStart;
    }
  }
  function asBuffer(bytes) { return new Buffer(bytes.buffer, bytes.byteOffset, bytes.byteLength); }
  [["UInt8", 1, "Uint8"], ["Int8", 1, "Int8"], ["UInt16", 2, "Uint16"], ["Int16", 2, "Int16"], ["UInt32", 4, "Uint32"], ["Int32", 4, "Int32"],
   ["Float", 4, "Float32"], ["Double", 8, "Float64"]].forEach(function (kind) {
    (kind[1] === 1 ? [""] : ["BE", "LE"]).forEach(function (order) {
      var read = function (offset) { return new DataView(this.buffer, this.byteOffset, this.byteLength)["get" + kind[2]](offset || 0, order === "LE"); };
      var write = function (value, offset) { new DataView(this.buffer, this.byteOffset, this.byteLength)["set" + kind[2]](offset || 0, value, order === "LE"); return (offset || 0) + kind[1]; };
      [kind[0], kind[0].replace("UInt", "Uint")].forEach(function (name) {
        Buffer.prototype["read" + name + order] = read;
        Buffer.prototype["write" + name + order] = write;
      });
    });
  });
  var bufferModule = { Buffer: Buffer };
  bufferModule.default = bufferModule;
  if (typeof global.Buffer === "undefined") global.Buffer = Buffer;

  // ---- crypto, zlib -----------------------------------------------------------------------

  // Sums Swiftr works out at once on bytes the script already has.
  function hashOf(algorithm, bytes) {
    var sum = native.hash(algorithm, bytes);
    if (!sum) throw new Error("Digest method not supported: " + algorithm);
    return asBuffer(sum);
  }
  var HASHES = ["md5", "sha1", "sha256", "sha384", "sha512"];
  function hashName(algorithm) { return String(algorithm && algorithm.name !== undefined ? algorithm.name : algorithm).toLowerCase().replace(/-/g, ""); }
  function Hash(algorithm) { this.algorithm = algorithm; this.parts = []; this.done = false; }
  Hash.prototype.update = function (data, encoding) {
    if (this.done) throw new Error("Digest already called");
    this.parts.push(typeof data === "string" ? encode(data, encoding) : bytesOf(data));
    return this;
  };
  Hash.prototype.digest = function (encoding) {
    if (this.done) throw new Error("Digest already called");
    this.done = true;
    var out = hashOf(this.algorithm, this.parts.length === 1 ? this.parts[0] : Buffer.concat(this.parts));
    return encoding ? out.toString(encoding) : out;
  };
  Hash.prototype.copy = function () { var twin = new Hash(this.algorithm); twin.parts = this.parts.slice(); return twin; };
  function randomBytes(size) {
    size = Number(size);
    if (!(size >= 0) || size > 1048576 || Math.floor(size) !== size) throw new RangeError("randomBytes takes a whole number up to 1048576");
    return asBuffer(native.random(size));
  }
  function randomUUID() {
    var b = randomBytes(16), hex = "";
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    for (var i = 0; i < 16; i++) hex += (b[i] < 16 ? "0" : "") + b[i].toString(16);
    return hex.slice(0, 8) + "-" + hex.slice(8, 12) + "-" + hex.slice(12, 16) + "-" + hex.slice(16, 20) + "-" + hex.slice(20);
  }
  var webcrypto = {
    getRandomValues: function (array) {
      if (!ArrayBuffer.isView(array) || array.byteLength > 65536) throw new Error("getRandomValues takes a typed array of at most 65536 bytes");
      new Uint8Array(array.buffer, array.byteOffset, array.byteLength).set(randomBytes(array.byteLength));
      return array;
    },
    randomUUID: randomUUID,
    subtle: {
      digest: function (algorithm, data) {
        return new Promise(function (resolve) {
          var name = hashName(algorithm);
          if (name === "md5" || HASHES.indexOf(name) < 0) throw new Error("Unrecognized algorithm name");
          var out = hashOf(name, bytesOf(data));
          resolve(out.buffer.slice(out.byteOffset, out.byteOffset + out.byteLength));
        });
      },
    },
  };
  var cryptoModule = {
    createHash: function (algorithm) {
      var name = hashName(algorithm);
      if (HASHES.indexOf(name) < 0) throw new Error("Digest method not supported: " + algorithm);
      return new Hash(name);
    },
    randomBytes: randomBytes, randomUUID: randomUUID, webcrypto: webcrypto,
  };
  cryptoModule.default = cryptoModule;
  if (typeof global.crypto === "undefined") global.crypto = webcrypto;

  function zip(op) {
    return function (data) {
      var out = native.zip(op, bytesOf(data));
      // Text back is the reason it failed.
      if (!(out instanceof Uint8Array)) throw new Error(typeof out === "string" ? out : "zlib failed");
      return asBuffer(out);
    };
  }
  var zlibModule = { deflateSync: zip("deflate"), inflateSync: zip("inflate"), gzipSync: zip("gzip"), gunzipSync: zip("gunzip") };
  zlibModule.default = zlibModule;

  // ---- net, websocket: client sockets, under the leave to reach the network ---------------

  function NetSocket(id) { this.id = id; }
  NetSocket.prototype.write = function (data) { return ask("net.write", { id: this.id, data: base64Of(bytesOf(data)) }).then(function () {}); };
  // The next bytes, or null once the other side is done.
  NetSocket.prototype.read = function (maxBytes) {
    var most = Math.floor(Number(maxBytes));
    return ask("net.read", { id: this.id, max: most > 0 ? most : 65536 }).then(function (data) { return data === null ? null : base64Bytes(data); });
  };
  NetSocket.prototype.close = function () { tell("socket.close", { id: this.id }); };
  var netModule = {
    connect: function (host, port) {
      return ask("net.connect", { host: String(host), port: Math.floor(Number(port)) || 0 }).then(function (answer) { return new NetSocket(answer.id); });
    },
  };
  netModule.default = netModule;

  function WebSocketSocket(id) { this.id = id; }
  WebSocketSocket.prototype.read = function () {
    return ask("ws.read", { id: this.id }).then(function (message) { return typeof message.text === "string" ? message.text : base64Bytes(message.data); });
  };
  WebSocketSocket.prototype.write = function (data) {
    var message = typeof data === "string" ? { id: this.id, text: data } : { id: this.id, data: base64Of(bytesOf(data)) };
    return ask("ws.write", message).then(function () {});
  };
  WebSocketSocket.prototype.close = function () { return ask("ws.close", { id: this.id }).then(function () {}); };
  var websocketModule = {
    WebSocket: {
      connect: function (url, options) {
        var headers = {}, given = (options && options.headers) || {};
        for (var k in given) headers[k] = String(given[k]);
        return ask("ws.connect", { url: String(url), headers: headers }).then(function (answer) { return new WebSocketSocket(answer.id); });
      },
    },
  };

  var pathModule = {
    join: function () { return pathModule.normalize(Array.prototype.filter.call(arguments, Boolean).join("/")); },
    resolve: function () {
      var out = "";
      for (var i = arguments.length - 1; i >= 0 && out[0] !== "/"; i--) if (arguments[i]) out = arguments[i] + (out ? "/" + out : "");
      return pathModule.normalize(out[0] === "/" ? out : herdr.home() + "/" + out);
    },
    normalize: function (p) {
      var absolute = p[0] === "/", parts = [];
      p.split("/").forEach(function (x) { if (x === "..") { if (parts.length && parts[parts.length - 1] !== "..") parts.pop(); else if (!absolute) parts.push(x); } else if (x && x !== ".") parts.push(x); });
      return (absolute ? "/" : "") + parts.join("/") || (absolute ? "/" : ".");
    },
    isAbsolute: function (p) { return String(p)[0] === "/"; },
    delimiter: ":",
    relative: function (from, to) {
      var a = pathModule.resolve(from).split("/").filter(Boolean), b = pathModule.resolve(to).split("/").filter(Boolean), i = 0;
      while (i < a.length && i < b.length && a[i] === b[i]) i++;
      return a.slice(i).map(function () { return ".."; }).concat(b.slice(i)).join("/");
    },
    dirname: function (p) { var i = String(p).replace(/\/+$/, "").lastIndexOf("/"); return i < 0 ? "." : i === 0 ? "/" : p.slice(0, i); },
    basename: function (p, suffix) { var b = String(p).replace(/\/+$/, "").split("/").pop(); return suffix && b.endsWith(suffix) ? b.slice(0, -suffix.length) : b; },
    extname: function (p) { var b = pathModule.basename(p), i = b.lastIndexOf("."); return i <= 0 ? "" : b.slice(i); },
    sep: "/",
  };
  pathModule.default = pathModule;

  var fsModule = {
    // With an encoding, text; without one, the file's bytes, as in herdr-app.
    readFile: function (path, encoding) {
      var name = typeof encoding === "string" ? encoding : encoding && encoding.encoding;
      if (name && encodingName(name) === "utf8") return ask("fs.readFile", { path: String(path) });
      return ask("fs.readFile", { path: String(path), bytes: true }).then(function (data) {
        var bytes = base64Bytes(data);
        return name ? decode(bytes, name) : bytes;
      });
    },
    writeFile: function (path, contents) {
      if (isBytes(contents)) return ask("fs.writeFile", { path: String(path), bytes: base64Of(bytesOf(contents)) });
      return ask("fs.writeFile", { path: String(path), text: String(contents) });
    },
    readdir: function (path) { return ask("fs.readdir", { path: String(path) }); },
    stat: function (path) { return ask("fs.stat", { path: String(path) }).then(function (s) { return Object.assign(s, { isDirectory: function () { return s.dir; }, isFile: function () { return !s.dir; } }); }); },
    mkdir: function (path, options) { return ask("fs.mkdir", { path: String(path), options: options || {} }); },
    rm: function (path, options) { return ask("fs.rm", { path: String(path), options: options || {} }); },
    unlink: function (path) { return ask("fs.rm", { path: String(path), options: {} }); },
    rename: function (from, to) { return ask("fs.rename", { from: String(from), to: String(to) }); },
    access: function (path) { return ask("fs.stat", { path: String(path) }).then(function () { return undefined; }); },
    exists: function (path) { return ask("fs.stat", { path: String(path) }).then(function () { return true; }, function () { return false; }); },
    rmdir: function (path, options) { return ask("fs.rm", { path: String(path), options: options || {} }); },
  };
  fsModule.default = fsModule;

  var ARCH = typeof native.arch === "string" ? native.arch : "arm64";
  var processModule = {
    run: function (command, args) { return herdr.exec(command, args); },
    env: {}, platform: "darwin", arch: ARCH, argv: [],
    cwd: function () { return herdr.home(); },
    nextTick: function (f) { var rest = Array.prototype.slice.call(arguments, 1); Promise.resolve().then(function () { f.apply(null, rest); }); },
    // A mod has no process of its own to end.
    exit: function () {},
  };
  processModule.default = processModule;
  var osModule = { homedir: function () { return herdr.home(); }, platform: function () { return "darwin"; }, arch: function () { return ARCH; }, tmpdir: function () { return "/tmp"; }, hostname: function () { return data("hostname") || ""; }, EOL: "\n" };
  osModule.default = osModule;

  var kit = {
    View: View, div: div, svg: svg, image: image, PathBuilder: PathBuilder, Background: BackgroundModule,
    list: virtualList("list"), uniform_list: virtualList("ulist"),
  };
  var base = {
    h_flex: h_flex, v_flex: v_flex,
    Button: part("button"), Link: part("link"), Checkbox: part("checkbox"), Switch: part("switch"), Radio: part("radio"),
    Toggle: part("toggle"), RadioGroup: part("group"), ToggleGroup: part("group"), Tabs: part("tabs"), Tab: part("tab"),
    Progress: part("progress"), ProgressTrack: part("progress-track"), ProgressIndicator: part("progress-indicator"),
    Avatar: part("avatar"), AvatarFallback: part("avatar-fallback"), AvatarImage: { new: function (path) { return image(path); } },
    Accordion: part("accordion"), AccordionItem: part("accordion-item"), AccordionPanel: part("accordion-panel"), AccordionTrigger: part("accordion-trigger"),
    AccordionHeader: { new: function (trigger) { var e = new El("div"); e.part = "accordion-header"; return e.child(trigger); } },
    Collapsible: part("collapsible"), Pagination: part("pagination"),
    Table: part("table"), TableHeader: part("table-header"), TableBody: part("table-body"), TableCaption: part("table-caption"),
    TableRow: part("table-row"), TableHead: part("table-head"), TableCell: part("table-cell"),
    Popover: popup("popover"), HoverCard: popup("hovercard"), Popup: popup("popup"), Select: part("select"), Combobox: part("combobox"),
    TextView: TextView, Scrollbar: Scrollbar,
    InputState: stateType("input"), Input: { new: fieldElement("input") }, NumberInput: { new: numberInput },
    TextareaState: stateType("textarea"), Textarea: { new: fieldElement("textarea") },
    EditorState: stateType("editor"), Editor: { new: fieldElement("editor") },
    SliderState: { new: function (options) { return new SliderStateC(options); } },
    Slider: sliderPart("slider"), SliderTrack: sliderPart("slider-track"), SliderIndicator: sliderPart("slider-indicator"), SliderThumb: sliderPart("slider-thumb"),
    ScrollHandle: { new: scrollHandle }, VirtualListScrollHandle: { new: scrollHandle },
    v_virtual_list: virtualList("vlist"), h_virtual_list: virtualList("hlist"),
    h_resizable: resizable("h"), v_resizable: resizable("v"), resizable_panel: resizable_panel,
    pagination_items: pagination_items,
    set_theme: function () {},
  };

  // Which page numbers a pager shows: the first, the last, a run around the current one,
  // and a gap (`ellipsis: [first, last]`) for each run left out.
  function pagination_items(current, total, visible) {
    total = Math.floor(Number(total) || 0);
    if (total <= 1) return [];
    visible = Math.max(5, Math.floor(Number(visible) || 7));
    current = Math.max(1, Math.min(total, Math.floor(Number(current) || 1)));
    var out = [], page;
    if (total <= visible) { for (page = 1; page <= total; page++) out.push({ page: page }); return out; }
    // Between the first and the last page: the run, less a place for each gap.
    var room = visible - 2, start = current - Math.floor((room - 1) / 2), end;
    start = Math.max(2, Math.min(start, total - room));
    end = start + room - 1;
    if (start > 2) start++;
    if (end < total - 1) end--;
    out.push({ page: 1 });
    if (start > 2) out.push({ ellipsis: [2, start - 1] });
    for (page = start; page <= end; page++) out.push({ page: page });
    if (end < total - 1) out.push({ ellipsis: [end + 1, total - 1] });
    out.push({ page: total });
    return out;
  }

  // A name a mod takes from a module that Swiftr lacks is noted, as an
  // element's unknown method is: `swiftr-mod check` and Settings name it.
  function noting(label, object) {
    return new Proxy(object, {
      get: function (target, key) {
        if (typeof key === "string" && !(key in target) && key !== "default" && key !== "then" && key !== "__esModule") native.unsupported(label + "." + key);
        return target[key];
      },
    });
  }
  kit = noting("gpui-kit", kit); base = noting("gpui-base", base);
  var herdrNoted = noting("herdr", herdr);

  var modules = {
    "gpui-kit": kit, "gpui": kit, "gpui-base": base, "gpui-component": base, "herdr": herdrNoted,
    "path": pathModule, "node:path": pathModule, "fs/promises": fsModule, "node:fs/promises": fsModule,
    "process": processModule, "node:process": processModule, "os": osModule, "node:os": osModule,
    "console": { default: global.console },
    "buffer": bufferModule, "node:buffer": bufferModule, "crypto": cryptoModule, "node:crypto": cryptoModule,
    "zlib": zlibModule, "node:zlib": zlibModule, "net": netModule, "node:net": netModule, "websocket": websocketModule,
    "url": { URL: global.URL, URLSearchParams: global.URLSearchParams },
    "gpui-fps": { fps_monitor: div, show_fps_monitor: function () {}, hide_fps_monitor: function () { return false; }, fps_monitor_visible: function () { return false; } },
  };

  // ---- What Swiftr calls ------------------------------------------------------------------

  global.__mod = {
    module: function (name) { return modules[name]; },
    star: function (target, source) { for (var k in source) if (k !== "default") target[k] = source[k]; },

    setData: function (key, text) { raw[key] = text; delete parsed[key]; return used[key] === true; },

    create: function (id, Class, propsText, placementText) {
      var props = propsText ? JSON.parse(propsText) : {};
      var record = { id: id, props: props, handlers: [], timers: new Set(), commandWaiters: [], focused: null, stopped: false, placement: placementText ? JSON.parse(placementText) : null };
      record.cx = makeContext(record);
      views.set(id, record);
      enter(record, function () {
        record.view = new Class(props);
        if (typeof record.view.init === "function") record.view.init(props, record.cx);
      });
      return record.view !== undefined;
    },

    setProps: function (id, propsText, placementText) {
      var record = views.get(id);
      if (!record) return;
      if (propsText) record.props = JSON.parse(propsText);
      record.placement = placementText ? JSON.parse(placementText) : null;
    },

    // The copy's panel, as JSON text; null when its render threw.
    render: function (id) {
      var record = views.get(id);
      if (!record || !record.view) return null;
      var before = current;
      current = record;
      // The last render's handlers stay until this one is whole: what is on
      // screen still calls them if this render throws.
      var kept = record.handlers;
      record.handlers = [];
      inRender = true;
      try {
        var out = record.view.render(record.cx);
        if (out instanceof Entity) out = out.render();
        if (!(out instanceof El)) out = div().child(out);
        return JSON.stringify({ root: out, bindings: record.bindings || null });
      } catch (e) {
        record.handlers = kept;
        report(record, e);
        return null;
      } finally {
        inRender = false;
        if (before) current = before;
      }
    },

    // A handler of the last render. Answers whether it stopped the event.
    event: function (id, index, payloadText) {
      var record = views.get(id);
      if (!record) return false;
      var f = record.handlers[index];
      if (typeof f !== "function") return false;
      record.stopped = false;
      var payload = payloadText ? JSON.parse(payloadText) : null;
      enter(record, function () {
        if (payload && payload.args) f.apply(null, payload.args.concat([record.cx])); else f(payload, record.cx);
      });
      return record.stopped;
    },

    // A field's own event (the person typed, pressed Return, the field took the keyboard).
    field: function (stateId, event, value, extraText) {
      var state = states.get(stateId);
      if (!state) return;
      if (value !== null && value !== undefined) state.v = value;
      var listeners = state.listeners[event] || [];
      var record = state.owner;
      var extra = extraText ? JSON.parse(extraText) : {};
      for (var i = 0; i < listeners.length; i++) {
        (function (f) {
          if (record) enter(record, function () { f(state.kind === "slider" ? state.v : extra, record.cx); }); else f(extra, null);
        })(listeners[i]);
      }
    },

    // A slider the person moved: its state takes the value, then tells who listens
    // (`change` while it moves, `release` when the pointer lets go).
    slider: function (stateId, valueText, event) {
      var state = states.get(stateId);
      if (!state) return;
      if (valueText) state.v = JSON.parse(valueText).v;
      var listeners = state.listeners[event] || [], record = state.owner;
      listeners.forEach(function (f) { if (record) enter(record, function () { f(state.v, record.cx); }); else f(state.v, null); });
    },

    // A step of a number field, when its mod wired none of its own.
    step: function (stateId, action) {
      var state = states.get(stateId);
      if (!state) return;
      var before = state.v;
      stepped(state, action);
      if (state.v === before) return;
      var listeners = state.listeners.change || [], record = state.owner;
      listeners.forEach(function (f) { if (record) enter(record, function () { f({}, record.cx); }); else f({}, null); });
    },

    timer: function (timerId) {
      var t = timers.get(timerId);
      if (!t) return false;
      if (!t.every) { timers.delete(timerId); t.record.timers.delete(timerId); }
      enter(t.record, function () { t.f(t.record.cx); });
      return t.every && timers.has(timerId);
    },

    resolve: function (callId, ok, text) {
      var call = calls.get(callId);
      if (!call) return;
      calls.delete(callId);
      var before = current;
      current = call.owner && views.has(call.owner.id) ? call.owner : before;
      try {
        if (ok) call.resolve(text === undefined || text === "" ? null : JSON.parse(text)); else call.reject(new Error(text));
      } finally { if (before) current = before; }
    },

    command: function (id, name) {
      var record = views.get(id);
      if (!record || !record.commandWaiters.length) return false;
      var waiters = record.commandWaiters;
      record.commandWaiters = [];
      enter(record, function () { waiters.forEach(function (resolve) { resolve(name); }); });
      return true;
    },

    focusChanged: function (id, handleId) { var record = views.get(id); if (record) record.focused = handleId; },

    close: function (id) {
      var record = views.get(id);
      if (!record) return;
      views.delete(id);
      record.timers.forEach(function (t) { timers.delete(t); native.cancelTimer(t); });
      if (record.view && typeof record.view.close === "function") enter(record, function () { return record.view.close(record.cx); });
    },
  };
})(this);
