import AppKit
import Foundation
import Testing
@testable import ModKit

/// What the ready-made parts do by themselves, surfaces, motion and drops.
@Suite(.serialized) struct ModPartsTests {
    private func home(_ body: String, imports: String = "") throws -> Home {
        try Home(["m": """
        import { View, div, FocusHandle } from "gpui-kit";
        import * as base from "gpui-base";
        \(imports)
        const { v_flex, h_flex } = base;
        export default class M extends View {
        \(body)
        }
        """])
    }

    @Test func aPressOnAPartReportsItsChange() throws {
        let home = try home("""
          init() { this.check = false; this.sw = false; this.radio = false; this.toggle = false; this.dead = 0; }
          render() {
            const note = (k) => (v, cx) => { this[k] = v; cx.notify(); };
            return v_flex().size_full()
              .child(base.Checkbox.new("c").checked(this.check).on_change(note("check")).child("check " + this.check))
              .child(base.Switch.new("s").checked(this.sw).on_change(note("sw")).child("switch " + this.sw))
              .child(base.Radio.new("r").checked(this.radio).on_change(note("radio")).child("radio " + this.radio))
              .child(base.Toggle.new("t").pressed(this.toggle).on_change(note("toggle")).child("toggle " + this.toggle))
              .child(base.Checkbox.new("d").disabled(true).on_change(() => { this.dead++; })
                .on_click(() => { this.dead++; }).child("dead " + this.dead));
          }
        """)
        let view = try home.view("m")
        for name in ["check", "switch", "radio", "toggle"] { #expect(view.click(text: "\(name) false")) }
        view.renderNow()
        #expect(view.texts() == ["check true", "switch true", "radio true", "toggle true", "dead 0"])
        // A radio cannot clear itself; the others flip back.
        for name in ["check", "switch", "radio", "toggle"] { #expect(view.click(text: "\(name) true")) }
        #expect(view.click(text: "dead 0"))
        view.renderNow()
        #expect(view.texts() == ["check false", "switch false", "radio true", "toggle false", "dead 0"])
        #expect(view.copy.runtime.errors.isEmpty)
    }

    @Test func aLinkOpensItsPage() throws {
        let home = try home("""
          render() {
            return v_flex()
              .child(base.Link.new("a").href("https://example.invalid/page").child("page"))
              .child(base.Link.new("b").href("file:///etc/passwd").child("file"));
          }
        """)
        let view = try home.view("m")
        #expect(view.click(text: "page"))
        #expect(view.click(text: "file"))
        #expect(home.host.opened == ["https://example.invalid/page"])
    }

    @Test func foldedPartsShowOnlyWhenOpen() throws {
        let home = try home("""
          init() { this.open = false; }
          render() {
            return v_flex()
              .child(base.Collapsible.new("c").open(this.open).content(div().child("inside")))
              .child(base.AccordionItem.new("i").open(this.open)
                .header(base.AccordionHeader.new(base.AccordionTrigger.new("t")
                  .on_change((v, cx) => { this.open = v; cx.notify(); }).child("title")))
                .panel(base.AccordionPanel.new("p").child("panel")))
              .child(base.Avatar.new("a").image(div().child("picture")).fallback(div().child("MS")));
          }
        """)
        let view = try home.view("m")
        // No picture file: the avatar falls back.
        #expect(view.texts() == ["title", "MS"])
        #expect(view.click(text: "title"))
        view.renderNow()
        #expect(view.texts() == ["inside", "title", "panel", "MS"])
        #expect(view.copy.runtime.errors.isEmpty)
    }

    @Test func aPopoverOpensOnAPressAndShutsOutside() throws {
        let home = try home("""
          init() { this.seen = []; }
          render() {
            return v_flex().size_full().p(20)
              .child(div().h(200).child("elsewhere"))
              .child(base.Popover.new("p").anchor("top_left")
                .on_open_change((open, cx) => { this.seen.push(open); cx.notify(); })
                .trigger(div().w(60).h(20).child("open"))
                .content(div().w(120).h(50).mt(4).child("menu " + this.seen.join(","))));
          }
        """)
        let view = try home.view("m")
        #expect(view.texts() == ["elsewhere", "open"])
        #expect(view.click(text: "open"))
        view.renderNow()
        #expect(view.texts() == ["elsewhere", "open", "menu true"])
        // Under its trigger, left edges together, off it by its own margin.
        let trigger = try #require(view.frame(ofText: "open")), menu = try #require(view.frame(ofText: "menu true"))
        #expect(menu.minX == 20)
        #expect(menu.minY == trigger.minY + 20 + 4)
        // A press in it leaves it open; one outside shuts it.
        #expect(view.click(text: "menu true"))
        view.renderNow()
        #expect(view.texts().count == 3)
        #expect(view.click(text: "elsewhere"))
        view.renderNow()
        #expect(view.texts() == ["elsewhere", "open"])
        // Escape shuts it too.
        #expect(view.click(text: "open"))
        view.renderNow()
        #expect(view.texts().count == 3)
        #expect(view.press(key: "escape"))
        view.renderNow()
        #expect(view.texts() == ["elsewhere", "open"])
        #expect(view.copy.runtime.errors.isEmpty)
    }

    @Test func aControlledPopoverFollowsItsScript() throws {
        let home = try home("""
          init() { this.open = false; this.asked = 0; }
          render() {
            return v_flex().size_full()
              .child(div().child("asked " + this.asked))
              .child(base.Popover.new("p").open(this.open)
                .on_open_change((open, cx) => { this.asked++; if (this.asked > 1) this.open = open; cx.notify(); })
                .trigger(div().child("open")).content(div().child("menu")));
          }
        """)
        let view = try home.view("m")
        // The script holds the state: a press it does not follow opens nothing.
        #expect(view.click(text: "open"))
        view.renderNow()
        #expect(view.texts() == ["asked 1", "open"])
        #expect(view.click(text: "open"))
        view.renderNow()
        #expect(view.texts() == ["asked 2", "open", "menu"])
    }

    @Test func aSurfaceStaysInsideTheWindow() throws {
        let home = try home("""
          render() {
            return v_flex().size_full().items_end().justify_end()
              .child(base.Popup.new("p", div().w(40).h(20).child("anchor")).anchor("top_left")
                .content(div().w(200).h(100).child("card")));
          }
        """)
        let view = try home.view("m", width: 300, height: 300)
        let card = try #require(view.frame(ofText: "card"))
        #expect(card.minX == 92)
        #expect(card.minY == 192)
    }

    @Test func aHoverCardOpensUnderTheRestingPointer() throws {
        let home = try home("""
          render() {
            return v_flex().size_full()
              .child(div().h(100).child("away"))
              .child(base.HoverCard.new("h").trigger(div().child("name")).content(div().child("card")));
          }
        """)
        let view = try home.view("m")
        #expect(view.texts() == ["away", "name"])
        #expect(view.hover(text: "name"))
        #expect(view.texts() == ["away", "name", "card"])
        #expect(view.hover(text: "away"))
        #expect(view.texts() == ["away", "name"])
    }

    @Test func aSliderFollowsThePointerAndTheArrows() throws {
        let home = try home("""
          init() {
            this.s = base.SliderState.new({ min: 0, max: 100, step: 10, value: 20 });
            this.log = [];
            this.s.on("change", (v) => { this.log.push("c" + v); });
            this.s.on("release", (v) => { this.log.push("r" + v); });
          }
          render() {
            return v_flex().size_full()
              .child(base.Slider.new(this.s).child(
                base.SliderTrack.new(this.s).flex().items_center().h(24).w(200).child(
                  base.SliderIndicator.new(this.s).relative().w_full().h(6).bg("#444444")
                    .range_style((fill) => fill.bg("#2563eb"))
                    .child(base.SliderThumb.new(this.s).id("thumb").size(16).ml(-8)))))
              .child(div().child("log " + this.log.join(" ")));
          }
        """)
        let view = try home.view("m")
        let thumb = try #require(view.locate { $0.part == "slider-thumb" })
        #expect(thumb.rect.midX == 40)
        view.press(at: CGPoint(x: 100, y: 12), button: "left", clicks: 1, flags: [])
        #expect(view.mouseDrag(to: CGPoint(x: 163, y: 60)))
        view.release(at: CGPoint(x: 163, y: 60), button: "left", clicks: 1, flags: [])
        // 163 of 200 points, on a step of 10.
        #expect(try #require(view.locate { $0.part == "slider-thumb" }).rect.midX == 160)
        view.renderNow()
        #expect(view.texts() == ["log c50 c80 r80"])
        #expect(try #require(view.locate { $0.part == "slider-thumb" }).rect.midX == 160)
        // Tab reaches the thumb; the arrows step it.
        #expect(view.press(key: "tab"))
        #expect(view.focusedNode()?.part == "slider-thumb")
        #expect(view.press(key: "right"))
        #expect(view.press(key: "end"))
        view.renderNow()
        #expect(view.texts() == ["log c50 c80 r80 c90 r90 c100 r100"])
    }

    /// A press on the thumb let go where it began moves nothing, and the
    /// script hears the value the slider shows, not an empty one.
    @Test func aPressOnAThumbKeepsItsValue() throws {
        let home = try home("""
          init() {
            this.s = base.SliderState.new({ min: 0, max: 100, step: 10, value: 20 });
            this.log = [];
            this.s.on("change", (v) => { this.log.push("c" + v); });
            this.s.on("release", (v) => { this.log.push("r" + v); });
          }
          render() {
            return v_flex().size_full()
              .child(base.Slider.new(this.s).child(
                base.SliderTrack.new(this.s).flex().items_center().h(24).w(200).child(
                  base.SliderIndicator.new(this.s).relative().w_full().h(6).bg("#444444")
                    .child(base.SliderThumb.new(this.s).id("thumb").size(16).ml(-8)))))
              .child(div().child("log " + this.log.join(" ") + " value " + this.s.value()));
          }
        """)
        let view = try home.view("m")
        view.press(at: CGPoint(x: 40, y: 12), button: "left", clicks: 1, flags: [])
        view.release(at: CGPoint(x: 40, y: 12), button: "left", clicks: 1, flags: [])
        view.renderNow()
        #expect(view.texts() == ["log r20 value 20"])
        #expect(try #require(view.locate { $0.part == "slider-thumb" }).rect.midX == 40)
    }

    /// A mod with a spinner runs a clock only while it shows in a window,
    /// and takes dragged files only when it has somewhere to drop them.
    @Test func aModOutOfSightRunsNoClock() throws {
        let home = try home("""
          render() { return v_flex().size_full().child(div().frames(["a", "b"], 100)); }
        """)
        let view = try home.view("m")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        view.renderNow()
        #expect(view.clock != nil)
        #expect(view.takesDrops == false)
        view.isShown = false
        #expect(view.clock == nil)
        view.isShown = true
        #expect(view.clock != nil)
        view.removeFromSuperview()
        #expect(view.clock == nil)
    }

    @Test func aNumberFieldSteps() throws {
        let home = try home("""
          init() { this.n = base.InputState.new({ value: "4" }); this.n.set_step(2); this.n.set_max(7); }
          render() {
            return v_flex().size_full()
              .child(base.NumberInput.new(this.n)
                .decrement_button(div().w(60).h(20).child("less"))
                .increment_button(div().w(60).h(20).child("more")))
              .child(div().child("is " + this.n.value()));
          }
        """)
        let view = try home.view("m")
        #expect(view.click(text: "more"))
        view.renderNow()
        #expect(view.texts().last == "is 6")
        #expect(view.click(text: "more"))
        view.renderNow()
        #expect(view.texts().last == "is 7")
        #expect(view.click(text: "less"))
        view.renderNow()
        #expect(view.texts().last == "is 5")
    }

    @Test func tabGoesFromPartToPartAndSpacePresses() throws {
        let home = try home("""
          init() { this.on = false; this.n = 0; }
          render() {
            return v_flex().size_full()
              .child(base.Button.new("b").on_click((_e, cx) => { this.n++; cx.notify(); }).child("button " + this.n))
              .child(base.Checkbox.new("off").disabled(true).child("off"))
              .child(base.Checkbox.new("c").checked(this.on).on_change((v, cx) => { this.on = v; cx.notify(); }).child("check " + this.on))
              .child(div().id("plain").tab_index(0).child("stop"))
              .child(base.Button.new("skip").tab_stop(false).child("skipped"));
          }
        """)
        let view = try home.view("m")
        #expect(view.tabStops().map { $0.id ?? "" } == ["b", "c", "plain"])
        #expect(view.press(key: "tab"))
        #expect(view.press(key: "space"))
        #expect(view.press(key: "tab"))
        #expect(view.press(key: "enter"))
        view.renderNow()
        #expect(view.texts().prefix(3) == ["button 1", "off", "check true"])
        // Round the end, and back.
        #expect(view.press(key: "tab"))
        #expect(view.press(key: "tab"))
        #expect(view.focusedNode()?.id == "b")
        #expect(view.press(key: "shift-tab"))
        #expect(view.focusedNode()?.id == "plain")
    }

    /// The keys as the keyboard sends them, not as a test spells them.
    @Test func realKeysReachTheParts() throws {
        let home = try home("""
          init() { this.on = false; }
          render() {
            return v_flex().size_full()
              .child(base.Checkbox.new("a").checked(this.on).on_change((v, cx) => { this.on = v; cx.notify(); }).child("a " + this.on))
              .child(base.Button.new("b").child("b"));
          }
        """)
        let view = try home.view("m")
        func key(_ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                                      context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
            view.keyDown(with: event)
        }
        try key(48, "\t")
        #expect(view.focusedNode()?.id == "a")
        try key(49, " ")
        view.renderNow()
        #expect(view.texts().first == "a true")
        try key(36, "\r")
        view.renderNow()
        #expect(view.texts().first == "a false")
        try key(48, "\t")
        #expect(view.focusedNode()?.id == "b")
        try key(48, "\u{19}", .shift)
        #expect(view.focusedNode()?.id == "a")
    }

    @Test func aThumbGlidesToAValueSetFromElsewhere() throws {
        let home = try home("""
          init() { this.s = base.SliderState.new({ min: 0, max: 100, value: 0 }); }
          render() {
            return v_flex().size_full()
              .child(div().id("go").on_click(() => { this.s.set_value(100); }).child("go"))
              .child(base.Slider.new(this.s).child(base.SliderTrack.new(this.s).h(20).w(200).child(
                base.SliderIndicator.new(this.s).w_full().h(6)
                  .child(base.SliderThumb.new(this.s).id("thumb").size(10).transition("left", { duration: 200, easing: "linear" })))))
              .child(div().size(8).spin(1));
          }
        """)
        let view = try home.view("m")
        view.timeOverride = 500
        view.renderNow()
        func thumb() throws -> CGFloat { try #require(view.locate { $0.part == "slider-thumb" }).rect.minX }
        #expect(try thumb() == 0)
        #expect(view.click(text: "go"))
        view.renderNow()
        #expect(try thumb() == 0)
        view.timeOverride = 500.1
        view.relayout()
        #expect(abs(try thumb() - 100) < 0.01)
        // Under the pointer it keeps up at once.
        view.timeOverride = 500.3
        view.relayout()
        #expect(try thumb() == 200)
        view.press(at: CGPoint(x: 50, y: 30), button: "left", clicks: 1, flags: [])
        #expect(try thumb() == 50)
        view.release(at: CGPoint(x: 50, y: 30), button: "left", clicks: 1, flags: [])
    }

    @Test func aHiddenPaneKeepsItsPlace() throws {
        let home = try home("""
          init() { this.mid = true; }
          render() {
            return v_flex().size_full()
              .child(div().id("go").on_click((_e, cx) => { this.mid = !this.mid; cx.notify(); }).child("go"))
              .child(base.h_resizable("work").h(100)
                .child(base.resizable_panel().size(100).child("left"))
                .child(base.resizable_panel().size(80).visible(this.mid).child("mid"))
                .child(base.resizable_panel().child("right")));
          }
        """)
        let view = try home.view("m", width: 400)
        func width(_ text: String) throws -> CGFloat { try #require(view.locate { $0.part == "pane" && $0.children.first?.text == text }).rect.width }
        let y = try #require(view.frame(ofText: "left")).midY
        view.press(at: CGPoint(x: 100, y: y), button: "left", clicks: 1, flags: [])
        view.mouseDrag(to: CGPoint(x: 140, y: y))
        view.release(at: CGPoint(x: 140, y: y), button: "left", clicks: 1, flags: [])
        #expect(try width("left") == 140)
        #expect(try width("mid") == 40)
        #expect(view.click(text: "go"))
        view.renderNow()
        #expect(view.texts() == ["go", "left", "right"])
        #expect(try width("left") == 140)
        #expect(try width("right") == 260)
        #expect(view.click(text: "go"))
        view.renderNow()
        #expect(try width("left") == 140)
        #expect(try width("mid") == 40)
    }

    @Test func aTextSpinnerDrawsTheFrameOfTheMoment() throws {
        let home = try home("""
          render() { return div().size_full().bg("#000000").text_color("#ffffff").text_size(40).child(div().frames(["I", "W"], 100)); }
        """)
        let view = try home.view("m", width: 80, height: 60)
        func ink() throws -> Int {
            let image = try #require(view.snapshot(size: CGSize(width: 80, height: 60), scale: 1))
            let data = try #require(image.dataProvider?.data), bytes = try #require(CFDataGetBytePtr(data))
            var lit = 0
            for offset in stride(from: 0, to: CFDataGetLength(data), by: 4) where bytes[offset] > 128 || bytes[offset + 1] > 128 { lit += 1 }
            return lit
        }
        view.timeOverride = 10.05
        let narrow = try ink()
        view.timeOverride = 10.15
        let wide = try ink()
        // A "W" inks more of the picture than an "I".
        #expect(narrow > 0 && wide > narrow * 2)
    }

    @Test func voiceOverMeetsThePartsByRoleAndName() throws {
        let home = try home("""
          init() { this.on = false; this.n = 0; this.s = base.SliderState.new({ value: 40 }); }
          render() {
            return v_flex().size_full()
              .child(div().child("Title"))
              .child(base.Checkbox.new("c").checked(this.on).on_change((v, cx) => { this.on = v; cx.notify(); }).child("Wrap lines"))
              .child(base.Switch.new("s").disabled(true).accessibility_label("Sync").child("x"))
              .child(div().id("plain").on_click((_e, cx) => { this.n++; cx.notify(); }).child("Add " + this.n))
              .child(div().role("list").child(div().role("listitem").aria_selected(true).child("One")))
              .child(base.Slider.new(this.s).child(base.SliderTrack.new(this.s).h(20).w(100).child(
                base.SliderIndicator.new(this.s).w_full().h(6).child(base.SliderThumb.new(this.s).accessibility_label("Volume").size(10)))));
          }
        """)
        let view = try home.view("m")
        #expect(view.accessReport() == [
            "StaticText: Title", "CheckBox: Wrap lines [0]", "CheckBox: Sync [0] (off)", "Button: Add 0",
            "List: One", "Group: One", "Slider: Volume [40]",
            // The list goes on into its row; the row reads as one.
        ])
        #expect(view.accessPress(named: "Wrap lines"))
        #expect(view.accessPress(named: "Add 0"))
        #expect(!view.accessPress(named: "Sync"))
        view.renderNow()
        #expect(view.accessReport().prefix(4) == ["StaticText: Title", "CheckBox: Wrap lines [1]", "CheckBox: Sync [0] (off)", "Button: Add 1"])
    }

    @Test func aSelectOpensAndShutsByKey() throws {
        let home = try home("""
          init(_p, cx) { this.open = false; this.trigger = cx.focus_handle(); this.list = cx.focus_handle(); this.log = []; }
          render() {
            const trigger = div().track_focus(this.trigger).child("pick");
            return v_flex().size_full().child(div().child("log " + this.log.join(" ")))
              .child(base.Select.new("s").open(this.open).track_focus(this.trigger).content_focus_handle(this.list)
                .on_open_change((open, cx) => { this.open = open; this.log.push(open ? "open" : "shut"); cx.notify(); })
                .on_confirm((_e, cx) => { this.log.push("confirm"); cx.notify(); })
                .on_dismiss((_e, cx) => { this.log.push("dismiss"); cx.notify(); })
                .child(base.Popup.new("list", trigger)
                  .when(this.open, (el) => el.content(div().track_focus(this.list).child("options")))));
          }
          focus(cx) { this.trigger.focus(cx.window); }
        """)
        let view = try home.view("m")
        view.takesKeyboard = true
        // The trigger has the keyboard.
        let trigger = try #require(view.locate { $0.focusHandle != nil && $0.kind != .text })
        view.focus(handle: try #require(trigger.node.focusHandle))
        #expect(view.press(key: "down"))
        view.renderNow()
        #expect(view.texts() == ["log open", "pick", "options"])
        #expect(view.focusedNode()?.parent?.isSurfaceRoot == true || view.focusedNode()?.isSurfaceRoot == true)
        #expect(view.press(key: "enter"))
        #expect(view.press(key: "escape"))
        view.renderNow()
        #expect(view.texts() == ["log open confirm dismiss shut", "pick"])
        #expect(view.copy.runtime.errors.isEmpty)
    }

    @Test func motionRunsBetweenTwoValues() throws {
        let home = try home("""
          init() { this.wide = false; }
          render() {
            return v_flex().size_full()
              .child(div().id("go").on_click((_e, cx) => { this.wide = !this.wide; cx.notify(); }).child("go"))
              .child(div().id("bar").h(10).w(this.wide ? 200 : 100).opacity(this.wide ? 1 : 0.5)
                .transition("width", 200).transition("opacity", { duration: 100, easing: "linear" }))
              .child(div().id("pulse").size(10).loop("opacity", { from: 0.2, to: 1, period: 1000, easing: "linear" }))
              .child(div().id("dots").frames(["a", "b", "c"], 100));
          }
        """)
        let view = try home.view("m")
        view.timeOverride = 1000
        view.renderNow()
        func node(_ id: String) throws -> ModNode { try #require(view.locate { $0.id == id }).node }
        // Nothing moves at first: each value is where its script put it.
        #expect(try node("bar").frame.width == 100)
        #expect(view.click(text: "go"))
        view.renderNow()
        #expect(try node("bar").frame.width == 100)
        view.timeOverride = 1000.1
        view.relayout()
        #expect(try node("bar").frame.width == 150)
        #expect(try node("bar").opacityOverride == nil)
        view.timeOverride = 1000.3
        view.relayout()
        #expect(try node("bar").frame.width == 200)
        #expect(view.runs.isEmpty)
        // A loop goes there and back once a period.
        view.timeOverride = 2000.25
        view.relayout()
        #expect(abs((try node("pulse").opacityOverride ?? 0) - 0.6) < 0.001)
        view.timeOverride = 2000.5
        view.relayout()
        #expect(abs((try node("pulse").opacityOverride ?? 0) - 1) < 0.001)
        // A text spinner shows the frame of the moment.
        #expect(try node("dots").frames == ["a", "b", "c"])
        #expect(view.copy.runtime.errors.isEmpty)
    }

    @Test func droppedFilesReachTheElementUnderThem() throws {
        let home = try home("""
          init() { this.got = "none"; }
          render() {
            return v_flex().size_full()
              .child(div().h(80).on_drop((event, cx) => { this.got = event.paths.join("+"); cx.notify(); }).child("drop here"))
              .child(div().child("got " + this.got));
          }
        """)
        let view = try home.view("m")
        #expect(!view.drop(paths: ["/tmp/a.txt"], onText: "got none"))
        #expect(view.drop(paths: ["/tmp/a.txt", "/tmp/b.txt"], onText: "drop here"))
        view.renderNow()
        #expect(view.texts().last == "got /tmp/a.txt+/tmp/b.txt")
    }

    @Test func aModHandsOverOnlyFilesItMayRead() throws {
        let source = """
        import { View, div } from "gpui-kit";
        export default class M extends View { render() { return div().child("x"); } }
        """
        let home = try Home(["m": source])
        let own = home.root.appending(path: "mods/m/main.js").path
        let other = home.root.appending(path: "elsewhere.txt").path
        let plain = try home.view("m")
        #expect(plain.copy.runtime.mayHandOver(own))
        #expect(!plain.copy.runtime.mayHandOver(other))
        #expect(plain.copy.runtime.errors.contains { $0.contains("drag_paths") })
        let home2 = try Home(["m": source])
        let trusted = try home2.view("m", granted: [.readFiles])
        #expect(trusted.copy.runtime.mayHandOver(home2.root.appending(path: "elsewhere.txt").path))
        // Outside the test folders: never, whatever the mod was given.
        #expect(!trusted.copy.runtime.mayHandOver("/etc/hosts"))
    }

    @Test func panesKeepTheSizeTheyWereDraggedTo() throws {
        let home = try home("""
          init() { this.sizes = "none"; }
          render() {
            return v_flex().size_full()
              .child(base.h_resizable("work").h(100)
                .on_resize((sizes, cx) => { this.sizes = sizes.join("/"); cx.notify(); })
                .child(base.resizable_panel().size(100).size_range(60, 150).child("left"))
                .child(base.resizable_panel().child("right")))
              .child(div().child("sizes " + this.sizes));
          }
        """)
        let view = try home.view("m", width: 300)
        func pane(_ index: Int) throws -> CGRect { try #require(view.locate { $0.part == "pane" && $0.parent?.children[index] === $0 }).rect }
        #expect(try pane(0).width == 100)
        #expect(try pane(1).width == 200)
        view.press(at: CGPoint(x: 100, y: 50), button: "left", clicks: 1, flags: [])
        #expect(view.mouseDrag(to: CGPoint(x: 130, y: 50)))
        #expect(try pane(0).width == 130)
        #expect(view.mouseDrag(to: CGPoint(x: 290, y: 50)))
        #expect(try pane(0).width == 150)
        view.release(at: CGPoint(x: 290, y: 50), button: "left", clicks: 1, flags: [])
        view.renderNow()
        #expect(try pane(0).width == 150)
        #expect(try pane(1).width == 150)
        #expect(view.texts().last == "sizes 150/150")
    }

    @Test func anElementHearsItsSize() async throws {
        let home = try home("""
          init() { this.size = "none"; this.wide = false; }
          render() {
            return v_flex().size_full()
              .child(div().id("go").on_click((_e, cx) => { this.wide = true; cx.notify(); }).child("go"))
              .child(div().h(20).w(this.wide ? 80 : 40)
                .on_size_change((size, cx) => { this.size = size.width + "x" + size.height; cx.notify(); }))
              .child(div().child("size " + this.size));
          }
        """)
        let view = try home.view("m")
        await home.settle(0.05)
        view.renderNow()
        #expect(view.texts().last == "size 40x20")
        #expect(view.click(text: "go"))
        view.renderNow()
        await home.settle(0.05)
        view.renderNow()
        #expect(view.texts().last == "size 80x20")
    }

    @Test func aListRowReportsItsKey() throws {
        let home = try home("""
          init() { this.picked = "none"; }
          render() {
            return v_flex().size_full()
              .child(div().child("picked " + this.picked))
              .child(base.v_virtual_list("list", 4, [24, 24, 24, 24], (i) => "k" + i, (range) => {
                  const rows = [];
                  for (let i = range.start; i < range.end; i++) rows.push(div().h(24).child("row " + i));
                  return rows;
                }).h(200)
                .on_item_click((key, cx) => { this.picked = key; cx.notify(); }));
          }
        """)
        let view = try home.view("m")
        #expect(view.click(text: "row 2"))
        view.renderNow()
        #expect(view.texts().first == "picked k2")
    }
}
