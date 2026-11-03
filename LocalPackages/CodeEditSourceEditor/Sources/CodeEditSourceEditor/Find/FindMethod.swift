//
//  FindMethod.swift
//  CodeEditSourceEditor
//
//  Created by Austin Condiff on 5/2/25.
//

enum FindMethod: CaseIterable {
    case contains
    case matchesWord
    case startsWith
    case endsWith
    case regularExpression

    var displayName: String {
        switch self {
        case .contains:
            return String(localized: "Contains", bundle: .main)
        case .matchesWord:
            return String(localized: "Matches Word", bundle: .main)
        case .startsWith:
            return String(localized: "Starts With", bundle: .main)
        case .endsWith:
            return String(localized: "Ends With", bundle: .main)
        case .regularExpression:
            return String(localized: "Regular Expression", bundle: .main)
        }
    }
}
