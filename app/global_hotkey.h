// Little Window from anywhere (#42): Arc opens Little Arc when you press Cmd+Option+N in any app. NotArc registers the
// same key system-wide with Carbon's hot key API, which needs no Accessibility permission. One key at a time.
#pragma once

#import <Foundation/Foundation.h>

BOOL GlobalHotkeyInstall(void (^handler)(void));  // Cmd+Option+N; NO if another app already owns it
void GlobalHotkeyRemove(void);
BOOL GlobalHotkeyInstalled(void);
