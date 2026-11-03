// swift scripts/icons/verify-lucide.swift /absolute/path/to/ServerDock.app
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let mapping = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("scripts/icons/symbol-map.json")))
guard CommandLine.arguments.count == 2, let bundle = Bundle(path: CommandLine.arguments[1]) else {
    fatalError("Pass the path of a built ServerDock.app")
}
var failures = [String]()
for name in Set(mapping.values).sorted() {
    guard let image = bundle.image(forResource: "lucide-" + name) else {
        failures.append("Missing asset: \(name)")
        continue
    }
    let sizes: [NSSize] = [12.0, 18.0, 24.0].compactMap { pointSize in
        image.withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))?.size
    }
    if sizes.count != 3 || sizes.contains(where: { $0.width <= 0 || $0.height <= 0 }) || sizes.first == sizes.last {
        failures.append("Invalid scalable symbol: \(name)")
    }
}
let literal = try NSRegularExpression(pattern: #"lucideSymbol:\s*"([a-zA-Z0-9.]+)""#)
let files = FileManager.default.enumerator(at: root.appendingPathComponent("ServerDock"), includingPropertiesForKeys: nil)!
for case let file as URL in files where file.pathExtension == "swift" {
    let source = try String(contentsOf: file, encoding: .utf8)
    let ns = source as NSString
    for match in literal.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
        let name = ns.substring(with: match.range(at: 1))
        if mapping[name] == nil { failures.append("Unmapped \(name) in \(file.lastPathComponent)") }
    }
    if source.contains("Image(systemName:") || source.contains("NSImage(systemSymbolName:") || source.contains("systemImage:") {
        failures.append("System icon call remains in \(file.lastPathComponent)")
    }
}
guard failures.isEmpty else { fatalError(failures.joined(separator: "\n")) }
print("Verified \(Set(mapping.values).count) scalable Lucide assets, \(mapping.count) aliases, and UI icon call sites.")
