// Hidden design renders for the visual parity checklist (docs/visual-parity.md).
//
//   CFFIXED_USER_HOME=<throwaway home> NotArc --visual-shots=<plan.txt>
//
// Runs with the same isolation as the self-test (test profiles, memory-only settings, mock Keychain), keeps every
// window far off screen, and follows a small plan file, one command per line:
//   out <dir>                    where PNGs go (default: the plan's folder)
//   size <w> <h>                 main window size in points
//   appearance dark|light|auto
//   space <n>                    switch to the n-th Space (0-based)
//   theme <n> <#hex> [#hex] [#hex] <intensity>
//   grain <n> <0..1>             the Space's grain
//   welcome <page>               the first-launch welcome on a page (welcome, pin, spaces, split, commandbar, import,
//                                progress, done)
//   newtab <url>                 new Today tab in the current Space
//   show <text>                  show the first tab whose address or title contains <text>
//   split <url> <url> [...]      open a split view
//   newspace <name>              make a Space and switch to it
//   peek-sidebar                 hide the sidebar and float it in, as the left-edge hover does
//   loading [0|1]                show the shown tab as loading
//   inactive [0|1]               draw the window as inactive
//   hover-today                  hover the Today divider (shows Clear)
//   hover <text>                 hover the sidebar row of that tab (empty: none)
//   js <script>                  run a script in the shown tab
//   poll-media                   ask every tab what it's playing now
//   load <n>                     load the first n tabs of every Space (real icons and titles)
//   do <selector>                send an action (e.g. showArchive:) to the window controller
//   setting <key> <0|1>          memory-only setting
//   cmdbar <text>                open the new-tab command bar and type <text>
//   cmdbar-current               open the command bar for the current tab (Cmd+L)
//   close-cmdbar
//   kv <key path>                print a value from the window controller (layout checks)
//   wait <seconds>
//   shot <name>                  the whole window, child panels composited on top
//   sidebar <name>               the sidebar view only
//   quit
// Lines starting with # are comments. Every command prints one VISUAL line.
#pragma once
#import <Cocoa/Cocoa.h>

@class MainWindowController;

BOOL VisualShotsRequested(int argc, char* argv[], NSString** planPath);
void VisualShotsPrepareWindow(NSWindow* window);  // before the window is shown
void VisualShotsKeepOffscreen(MainWindowController* controller);  // every 50 ms from the hidden-run timer
void VisualShotsRun(MainWindowController* controller, NSString* planPath);
