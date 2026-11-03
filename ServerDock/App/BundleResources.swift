import Foundation

extension Bundle {
    /// Resource bundle: .module for SwiftPM, .main for Xcode app targets.
    /// Use SWIFT_PACKAGE, defined only by SwiftPM, so shared source locates
    /// AppIcon, font-logos, Nerd Font, and other assets under either build system. App targets store resources in .main,
    /// where Bundle.module does not exist; this accessor unifies access.
    static var app: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }
}
