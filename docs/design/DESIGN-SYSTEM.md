# Talk & Read design system

The app should feel calm and make reading or dictating the obvious next action. Keep each existing feature reachable. The icon is unchanged.

## Navigation and words

Home holds recent reads and dictation. Library holds imported documents. Dictation holds its history and vocabulary. Settings owns preferences and voice management, using native macOS controls where possible.

Use sentence case for commands and labels, as Junior requested. Keep terms consistent with `../GLOSSARY.md`. An ellipsis means more input is required. Errors say what happened and how to recover; destructive library and history actions retain Undo.

## Space and layout

`Space` in `UI/Theme.swift` supplies the four-point scale: 4, 8, 12, 16, 20, 24, 28 and 32 points. Related controls use small gaps; page sections get more space. Use container alignment rather than offsets. System Lists and Forms retain native metrics.

`Tools/check-ui-grid.py` checks custom padding and stack gaps. Purpose-specific drawing geometry may use other dimensions with an explanatory exception; that is not a general spacing exemption.

## Type

`TypeStyle.caption` uses callout; `label` uses body; reading `body` uses title3. Rounded title and largeTitle styles distinguish speed metrics. These are semantic macOS text styles, not fixed point sizes. Keep reading text selectable and long labels able to wrap or disclose their full value.

Purpose-built glyphs, waveform drawing and compact controls may keep measured geometry. Do not shrink content solely to make a snapshot fit.

## Colour and surfaces

Use the existing `Theme` tokens. Yellow is the accent; `onAccent` supplies the dark text on it. `accentText` uses a deeper shade on light backgrounds. `warning` is distinct from the accent and must be accompanied by words or a symbol.

Backgrounds and cards adapt to light and dark. Native materials belong on controls and navigation. The invisible snapshot renderer substitutes a stable material for live glass; it cannot prove real glass or PDF rendering.

## Controls, feedback and motion

Use native Button, Toggle, Picker and Form components. Custom symbol buttons must have an accessibility label and help. Provide keyboard/menu equivalents for frequent actions. Respect Reduce Motion. Status changes remain understandable without colour alone, and transient errors are announced.

## Verification

Run `Tools/check-design.sh` with a fresh evidence folder and the built executable. It checks grid spacing, semantic type and every snapshot in light and dark. `Tools/check-release.sh` includes grid and snapshot checks in its normal run.

Every check uses `--agent-screen` with disposable data and home folders. Never start a microphone, play audio, request permissions, register global shortcuts, show a window or take focus for a test. Live keyboard, voice quality and external-app highlighting require separate authorised evidence.
