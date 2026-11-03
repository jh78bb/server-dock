# CryptoSwift (vendored)

Copy of https://github.com/royalapplications/CryptoSwift (branch `foundationessentials`, revision a59b4d91ebb22011656c830f874fe7152e183a57),
the dependency of RoyalVNCKit. The only change is in `Package.swift`: the `CryptoSwift` target builds with `-O` in Debug so that
macOS Screen Sharing (ARD) authentication, which computes 4096-bit modular exponentiations with `BigUInteger`, takes about 1 s instead of 30+ s
when running from Xcode. Being a local package, it overrides the remote dependency of the same identity.
