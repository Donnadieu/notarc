#!/usr/bin/env python3
"""Make a throwaway home folder with a small, made-up Arc data folder, for self-tests.

  scripts/make-test-home.py <dir>
  CFFIXED_USER_HOME=<dir> build/Release/NotArc.app/Contents/MacOS/NotArc --selftest

With CFFIXED_USER_HOME set, NotArc (and macOS's own folder lookups) use <dir> as the home folder, so a run never
reads or writes your real NotArc data, Downloads or Arc folder. The Arc files follow docs/arc-data-format.md:
three Spaces on two profiles, Favorites, Pinned tabs with a nested folder, Today tabs, an archive and a window.
Everything in them is invented.
"""
import json, os, sys, uuid

REF = 978307200  # 2001-01-01 UTC, Arc's NSDate reference


def nsdate(unix):
    return unix - REF


def main(home):
    arc = os.path.join(home, "Library", "Application Support", "Arc")
    os.makedirs(os.path.join(arc, "User Data"), exist_ok=True)
    os.makedirs(os.path.join(home, "Downloads"), exist_ok=True)
    now = 1_793_000_000  # a fixed time keeps the files stable between runs
    items = {}

    def uid(tag):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "notarc-selftest/" + tag)).upper()

    def tab(tag, title, url, parent, active_hours_ago=1):
        i = uid(tag)
        items[i] = {"id": i, "parentID": parent, "childrenIds": [], "title": None, "isUnread": False,
                    "createdAt": nsdate(now - 86400),
                    "data": {"tab": {"savedTitle": title, "savedURL": url, "savedMuteStatus": "allowAudio",
                                     "timeLastActiveAt": nsdate(now - active_hours_ago * 3600)}}}
        items[parent]["childrenIds"].append(i)
        return i

    def container(tag, ctype, parent=None):
        i = uid(tag)
        items[i] = {"id": i, "parentID": parent, "childrenIds": [], "title": None, "isUnread": False,
                    "createdAt": nsdate(now - 86400), "data": {"itemContainer": {"containerType": ctype}}}
        return i

    def folder(tag, title, parent):
        i = uid(tag)
        items[i] = {"id": i, "parentID": parent, "childrenIds": [], "title": title, "isUnread": False,
                    "createdAt": nsdate(now - 86400), "data": {"list": {}}}
        items[parent]["childrenIds"].append(i)
        return i

    profiles = {"Default": None, "Profile 1": "Profile 1"}
    favs = {}
    for name, base in profiles.items():
        ctype = {"topApps": {"_0": {"default": True}}} if base is None else \
            {"topApps": {"_0": {"custom": {"_0": {"directoryBasename": base, "machineID": uid("machine")}}}}}
        favs[name] = container("fav-" + name, ctype)
        os.makedirs(os.path.join(arc, "User Data", name), exist_ok=True)
    tab("fav-mail", "Mail", "https://mail.example.com/", favs["Default"])
    tab("fav-cal", "Calendar", "https://calendar.example.com/", favs["Default"])
    tab("fav-docs", "Docs", "https://docs.example.org/", favs["Profile 1"])

    spaces = []
    layout = [("Home", "Default"), ("Work", "Profile 1"), ("Side Project", "Default")]
    for n, (title, profile) in enumerate(layout):
        sid = uid("space-" + title)
        pinned = container("pinned-" + title, {"spaceItems": {"_0": sid}})
        today = container("today-" + title, {"spaceItems": {"_0": sid}})
        tab(f"{title}-p1", f"{title} pinned", f"https://example.com/{n}/pinned", pinned)
        f = folder(f"{title}-folder", f"{title} folder", pinned)
        tab(f"{title}-f1", "In folder", f"https://example.org/{n}/in-folder", f)
        inner = folder(f"{title}-inner", "Nested", f)
        tab(f"{title}-f2", "In nested folder", f"https://example.net/{n}/nested", inner)
        for k in range(3):
            tab(f"{title}-t{k}", f"{title} today {k}", f"https://example.com/{n}/today/{k}", today, k + 1)
        space = {"id": sid, "title": title, "containerIDs": ["pinned", pinned, "unpinned", today],
                 "newContainerIDs": [{"pinned": {}}, pinned, {"unpinned": {"_0": {"shared": {}}}}, today],
                 "customInfo": {}}
        if profile != "Default":
            space["profile"] = {"custom": {"_0": {"directoryBasename": profile, "machineID": uid("machine")}}}
        else:
            space["profile"] = {"default": True}
        spaces.append(space)

    flat_items = []
    for i, it in items.items():
        flat_items += [i, it]
    flat_spaces = []
    for s in spaces:
        flat_spaces += [s["id"], s]
    sidebar = {"version": 1, "sidebar": {"containers": [
        {"global": {}},
        {"spaces": flat_spaces, "items": flat_items, "topAppsContainerIDs": list(favs.values())}]}}
    with open(os.path.join(arc, "StorableSidebar.json"), "w") as fh:
        json.dump(sidebar, fh, indent=1)

    windows = {"windows": [{"id": uid("window"), "sidebarWidth": 273, "sidebarMode": "anchored",
                            "focusedSpaceID": spaces[0]["id"], "expandedItems": [],
                            "spacesWithCollapsedPinnedSection": []}]}
    with open(os.path.join(arc, "StorableWindows.json"), "w") as fh:
        json.dump(windows, fh, indent=1)

    archive = []
    for k in range(4):
        aid = uid(f"archived-{k}")
        archive += [aid, {"reason": "auto" if k % 2 else "manual", "archivedAt": nsdate(now - k * 7200),
                          "source": {"space": {"_0": spaces[k % 3]["id"]}},
                          "sidebarItem": {"id": aid, "title": None, "childrenIds": [],
                                          "data": {"tab": {"savedTitle": f"Archived {k}",
                                                           "savedURL": f"https://archive.example.com/{k}",
                                                           "timeLastActiveAt": nsdate(now - k * 7200 - 43200)}}}}]
    with open(os.path.join(arc, "StorableArchiveItems.json"), "w") as fh:
        json.dump({"version": 1, "items": archive}, fh, indent=1)
    print(arc)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(os.path.abspath(sys.argv[1]))
