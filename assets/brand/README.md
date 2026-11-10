# NotArc brand assets

Designed in Claude Design (NotArc Design System). Original artwork: nothing here comes from Arc.

- `notarc-icon.svg`: the app icon (1024 canvas, macOS grid). `notarc-icon-small.svg`: the simpler version used at 16 and 32 px.
- `notarc-icon-1024.png`: the icon as a 1024 px PNG.
- `notarc-mark.svg` (marigold, for dark grounds) and `notarc-mark-indigo.svg` (for light grounds): the ¬ mark.

`app/NotArc.icns` is built from the two icon SVGs: each size rendered to `NotArc.iconset/icon_<size>.png`
(16 and 32 px from the small version), then `iconutil -c icns NotArc.iconset -o app/NotArc.icns`.

Colours: indigo night #120C39 to #140D40, lavender #DAD9FE, marigold #FFC24B, violet #604FD6.
Type: Bricolage Grotesque (display), Figtree (text), JetBrains Mono (shortcuts, versions).
