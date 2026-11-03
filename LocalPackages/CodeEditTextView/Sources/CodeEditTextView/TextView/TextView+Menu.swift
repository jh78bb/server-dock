//
//  TextView+Menu.swift
//  CodeEditTextView
//
//  Created by Khan Winter on 8/21/23.
//

import AppKit

extension TextView {
    override public func menu(for event: NSEvent) -> NSMenu? {
        guard event.type == .rightMouseDown else { return nil }

        // [ServerDock localization] Localize hardcoded Cut/Copy/Paste and add Select All.
        // Use TextView cut/copy/paste/selectAll selectors; target=nil resolves through the responder chain.
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = .command
            return menuItem
        }
        menu.items = [
            item(String(localized: "Cut", bundle: .main), #selector(cut(_:)), "x"),
            item(String(localized: "Copy", bundle: .main), #selector(copy(_:)), "c"),
            item(String(localized: "Paste", bundle: .main), #selector(paste(_:)), "v"),
            .separator(),
            item(String(localized: "Select All", bundle: .main), #selector(selectAll(_:)), "a")
        ]

        return menu
    }

    // [ServerDock] AppKit adds unlocalizable AutoFill/Services/Share submenus automatically.
    // Since our menu has no submenus, remove system submenu items before opening
    // and trim trailing separators, retaining Cut/Copy/Paste/Select All.
    override public func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // AutoFill is built lazily, so submenu is still nil during willOpenMenu and cannot identify it reliably.
        // Keep only our four editing actions and separators; remove other system-added entries.
        let allowed: Set<Selector> = [
            #selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
            #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))
        ]
        for menuItem in menu.items where !menuItem.isSeparatorItem {
            if let action = menuItem.action, allowed.contains(action) { continue }
            menu.removeItem(menuItem)
        }
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }
}
