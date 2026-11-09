#import "app/global_hotkey.h"

#import <Carbon/Carbon.h>

static EventHotKeyRef gHotKey;
static EventHandlerRef gHandlerRef;
static void (^gHandler)(void);

static OSStatus OnHotKey(EventHandlerCallRef, EventRef, void*) {
  if (gHandler) dispatch_async(dispatch_get_main_queue(), gHandler);
  return noErr;
}

BOOL GlobalHotkeyInstall(void (^handler)(void)) {
  GlobalHotkeyRemove();
  gHandler = [handler copy];
  EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
  if (InstallApplicationEventHandler(&OnHotKey, 1, &spec, nullptr, &gHandlerRef) != noErr) return NO;
  EventHotKeyID hid = {'NtAr', 1};
  if (RegisterEventHotKey(kVK_ANSI_N, cmdKey | optionKey, hid, GetApplicationEventTarget(), 0, &gHotKey) != noErr) {
    GlobalHotkeyRemove();
    return NO;
  }
  return YES;
}

void GlobalHotkeyRemove(void) {
  if (gHotKey) UnregisterEventHotKey(gHotKey);
  if (gHandlerRef) RemoveEventHandler(gHandlerRef);
  gHotKey = nullptr;
  gHandlerRef = nullptr;
}

BOOL GlobalHotkeyInstalled(void) { return gHotKey != nullptr; }
