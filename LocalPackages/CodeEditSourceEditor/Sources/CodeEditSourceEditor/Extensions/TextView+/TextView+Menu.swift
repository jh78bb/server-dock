//
//  TextView+Menu.swift
//  CodeEditSourceEditor
//
//  Created by Lukas Pistrol on 25.05.22.
//

// [ServerDock] Unused setupMenus/helpMenu/codeMenu/gitMenu/removeMenus had no callers in this repository.
// Upstream's nine context-menu entries had nil actions and did nothing.
// removeMenus checked indexOfItem(withTitle:) >= 0, but missing-item NSNotFound (NSIntegerMax) also passes.
// Calling removeItem(at:) with that index could produce "index 9223372036854775807 is invalid".
// The actual context menu comes from CodeEditTextView's TextView.menu(for:), localized in that vendored copy.
// Delete unused code to prevent these failures from being reconnected accidentally.

import AppKit
