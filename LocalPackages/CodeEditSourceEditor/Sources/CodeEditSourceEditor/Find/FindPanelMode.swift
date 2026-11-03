//
//  FindPanelMode.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 4/18/25.
//

enum FindPanelMode: CaseIterable {
    case find
    case replace

    var displayName: String {
        switch self {
        case .find:
            return String(localized: "Find", bundle: .main)
        case .replace:
            return String(localized: "Replace", bundle: .main)
        }
    }
}
