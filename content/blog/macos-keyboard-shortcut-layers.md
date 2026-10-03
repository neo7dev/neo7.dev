---
title: "Four places macOS hides a keyboard shortcut"
date: 2026-10-03T17:40:00+05:30
authors:
  - name: neo7.dev
tags:
  - macos
  - keyboard
excludeSearch: false
summary: "macOS resolves a keypress through four independent layers. Knowing which one owns a shortcut is the difference between a remap that works everywhere and one that works in TextEdit and nowhere else."
# `coverText` renders in the card cover slot with the prompt glyph from
# params.command.prompt until there is a real cover image.
coverText: |
  keyboard --remap
---

{{< lead >}}
macOS resolves a keypress through four independent layers: Modifier Keys decides
which physical key is `cmd`, the Keyboard Shortcuts pane owns named system actions,
`DefaultKeyBinding.dict` owns text navigation, and Karabiner-Elements reaches
everything the other three cannot. Work down that list, not up.
{{< /lead >}}

<!--more-->

Coming to macOS from Windows or Linux, the instinct is to remap everything back.
That instinct is wrong, and the reason is worth understanding: a keypress on
macOS is resolved by four independent mechanisms, and each one can only see some
of the keyboard.

## Stop translating, start swapping

macOS uses `cmd` where other systems use `ctrl` — copy, paste, find, save, quit.
The tempting fix is to rebind every application's shortcuts to `ctrl`. Do not.
There are hundreds of them, third-party apps will not cooperate, and the result
is a machine that behaves differently from every other Mac.

The cheaper fix is physical. Leave `cmd` doing what `cmd` does, and move it to
the key your hand already reaches for:

- `cmd` goes where `ctrl` lives on a PC keyboard — bottom-left of the modifier
  cluster.
- `ctrl` goes where the `win`/`super` key lives.

Your muscle memory is attached to a _position_, not a legend. Swap the positions
and the mental translation disappears within a day.

That swap is the first of the four layers:

**System Settings → Keyboard → Keyboard Shortcuts → Modifier Keys.** Pick the
keyboard from the dropdown first — the mapping is stored per device, so an
external board and the built-in one are configured separately, and plugging in a
second keyboard gives you an unmapped one.

## Layer two: the shortcuts pane

The same **Keyboard Shortcuts** window is a list of system actions you can
rebind: Mission Control, Spotlight, screenshots, input sources, app windows.
Double-click the shortcut on the right of an action and press the new
combination.

This layer owns anything the window server handles before an application sees
it. Switching desktops is the useful one — `ctrl+left`/`ctrl+right` by default,
which collides with word-wise cursor movement on any keyboard where you have
swapped the modifiers. Move it under Mission Control and the collision goes
away.

Anything that is not in that list is not configurable here, and no amount of
looking will add it.

## Layer three: `DefaultKeyBinding.dict`

Text navigation and selection — word-wise movement, line start and end, document
start and end, word-wise delete — are not system shortcuts. They are Cocoa text
actions, and they are rebound in a single file:

```
~/Library/KeyBindings/DefaultKeyBinding.dict
```

Create the `KeyBindings` directory; it does not exist by default. The file is an
old-style property list mapping a key sequence to a selector:

```text
{
  "@\UF702"  = moveWordLeft:;                                // cmd-left
  "@\UF703"  = moveWordRight:;                               // cmd-right
  "@$\UF702" = moveWordLeftAndModifySelection:;              // cmd-shift-left
  "@$\UF703" = moveWordRightAndModifySelection:;             // cmd-shift-right
  "\UF729"   = moveToBeginningOfLine:;                       // home
  "\UF72B"   = moveToEndOfLine:;                             // end
  "$\UF729"  = moveToBeginningOfLineAndModifySelection:;     // shift-home
  "$\UF72B"  = moveToEndOfLineAndModifySelection:;           // shift-end
  "@\U007F"  = deleteWordBackward:;                          // cmd-backspace
  "@\UF728"  = deleteWordForward:;                           // cmd-delete
}
```

Two things to read off that:

- **Modifiers are sigils, not words.** `@` is command, `$` is shift, `~` is
  option, `^` is control. They stack: `$@` is shift-command.
- **Keys are Unicode escapes.** `\UF702` and `\UF703` are left and right arrow,
  `\UF729` and `\UF72B` are home and end, `\U007F` is backspace and `\UF728` is
  forward delete. The private-use block is where AppKit keeps non-printing keys.

Save it as UTF-8, then restart the applications you want it to take effect in.
There is no reload; the file is read once at launch.

{{< callout type="warning" >}}
This layer is advisory. Any application that implements its own text handling —
Electron apps, JetBrains IDEs, terminals, anything with a custom editor — can
and does ignore it. A chat client may honour `moveWordLeft:` and ignore
`moveToEndOfLine:` in the same text box. That is not a bug in your file.
{{< /callout >}}

## Layer four: Karabiner-Elements

Karabiner sits below all of the above, rewriting events before the system sees
them. It is the only layer that can reach an application that ignores layer
three, and the only one that can condition a remap on which application is in
front.

It has two modes.

**Simple Modifications** swaps one key or button for another, globally. Caps lock
to tab, a keypad key to a mouse button, a key your keyboard's firmware cannot
reassign to one it can. Self-explanatory in the UI.

**Complex Modifications** are JSON rules. The structure is a list of
manipulators, each with a `from`, an optional set of `conditions`, and a `to`:

```json
{
  "description": "Home/End in an app that ignores the system binding",
  "manipulators": [
    {
      "type": "basic",
      "from": {
        "key_code": "home",
        "modifiers": { "optional": ["left_shift"] }
      },
      "conditions": [
        {
          "type": "frontmost_application_if",
          "bundle_identifiers": ["com.example.theapp"]
        }
      ],
      "to": [
        { "key_code": "left_arrow", "modifiers": ["left_command"] }
      ]
    }
  ]
}
```

The non-obvious parts:

- **`optional` modifiers are what make selection work.** Without
  `"optional": ["left_shift"]` the rule fires on bare `home` and not on
  `shift+home`, so the key navigates but never selects. Listing a modifier as
  optional means "fire whether or not this is held, and pass it through".
- **`mandatory` is the opposite** and is what you want for a hotkey:
  `{"key_code": "s", "modifiers": {"mandatory": ["left_control", "left_command"]}}`
  fires only on that exact combination.
- **Conditions key off bundle identifiers.** Find one with the Karabiner
  EventViewer: status menu → Launch EventViewer → **Frontmost Application**, then
  switch to the application you care about. The same tool's **Main** tab prints
  `key_code` values for any key you press — necessary, because Karabiner's names
  are not the names anything else uses.
- **`left_command` or `left_control`?** After swapping modifiers in System
  Settings, Karabiner sees physical keys while applications see logical ones. If
  a rule does nothing, swap the two and try again before debugging anything else.

### Importing rules without making a mess

Karabiner has no rule editor. Rules arrive by import, and the import appends — so
re-importing an edited rule leaves the old version enabled alongside the new one,
and the two fight. Delete the previous section every time you import.

The practical workflow is to keep the JSON in a real file under version control,
edit it in an editor that validates JSON, and import after each change. Browser-
based rule generators are useful exactly once, to produce a template worth
copying.

## The payoff: layers and launchers

Once Karabiner is in place, two things become available that no amount of
system-level configuration offers.

**Direct application switching.** A manipulator can run a shell command instead
of emitting a key:

```json
{
  "type": "basic",
  "from": {
    "key_code": "s",
    "modifiers": { "mandatory": ["left_control", "left_command"] }
  },
  "to": [{ "shell_command": "open -a 'Some Application'" }]
}
```

One manipulator per application you use daily. No app switcher, no cycling, no
hunting the dock — a single chord goes straight to the window.

**A navigation layer.** Hold a modifier reachable by your thumb and turn the home
row into arrows: `i`/`j`/`k`/`l` as up/left/down/right, `u`/`o` as home/end.
Programmable keyboards do this in firmware; Karabiner does it on the built-in
laptop keyboard. For anyone editing text all day it is the single remap with the
best return, because it removes the reach to the arrow cluster entirely.

## Which layer to reach for

| You want to change                                     | Layer                           |
| ------------------------------------------------------ | ------------------------------- |
| Which physical key is `cmd`                            | Modifier Keys                   |
| A named system action (spaces, Spotlight, screenshots) | Keyboard Shortcuts pane         |
| Text navigation, selection, word-wise delete           | `DefaultKeyBinding.dict`        |
| One key becoming another, globally                     | Karabiner Simple Modifications  |
| A remap in one application only                        | Karabiner Complex Modifications |
| A remap an application refuses to honour               | Karabiner Complex Modifications |
| A chord that launches something                        | Karabiner, `shell_command`      |

Work down the list, not up. The higher layers survive reinstalls, need no
background process, and cannot conflict with each other. Karabiner is the
escape hatch, not the starting point.
