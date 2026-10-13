import Foundation

// The production setOnAllSpaces body is compiled unchanged. Only its external
// dependencies are replaced: a temporary store, a log sink, and no subprocess.
let wallpaperStore = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("Index.plist")
var restarts = 0
var messages: [String] = []
func log(_ message: String) { messages.append(message) }
final class Process {
  var executableURL: URL?
  var arguments: [String]?
  func run() throws {
    expect(executableURL?.path == "/usr/bin/killall" && arguments == ["WallpaperAgent"], "restart target")
    restarts += 1
  }
  func waitUntilExit() {}
}

var checks = 0
var failures = 0
func expect(_ condition: Bool, _ label: String) {
  checks += 1
  if !condition { failures += 1; print("FAIL: \(label)") }
}
func plist(_ object: Any) throws -> Data {
  try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
}
func dictionary(_ data: Data) throws -> [String: Any] {
  try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as! [String: Any]
}
func desktop(_ configuration: Data, _ url: URL) -> [String: Any] {
  ["Desktop": ["Content": ["Choices": [["Provider": imageProvider,
    "Files": [["relative": url.absoluteString]], "Configuration": configuration]], "Shuffle": "old"]]]
}

let oldURL = URL(fileURLWithPath: "/wallpaper/background-old.jpg")
let newURL = URL(fileURLWithPath: "/wallpaper/background-new picture.png")
let configuration = try plist(["type": "imageFile", "url": ["relative": oldURL.absoluteString],
                               "placement": "fill", "backgroundColor": ["red": 0.25]])
try plist(desktop(configuration, oldURL)).write(to: wallpaperStore)
setOnAllSpaces(newURL)
let store = try dictionary(Data(contentsOf: wallpaperStore))
let content = (store["Desktop"] as! [String: Any])["Content"] as! [String: Any]
let choice = (content["Choices"] as! [[String: Any]])[0]
expect((choice["Files"] as? [[String: String]])?.first?["relative"] == newURL.absoluteString, "Files uses new URL")
let embedded = try dictionary(choice["Configuration"] as! Data)
let embeddedURL = (embedded["url"] as? [String: String])?["relative"]
expect(embeddedURL == newURL.absoluteString, "embedded Configuration URL: expected \(newURL.absoluteString), got \(embeddedURL ?? "missing")")
expect(embedded["placement"] as? String == "fill", "placement preserved")
expect((embedded["backgroundColor"] as? [String: Double])?["red"] == 0.25, "background colour preserved")
expect(restarts == 1 && messages.isEmpty, "store saved and restart requested")
// A stale Space before the one NSWorkspace just updated must not spread its
// old URL. Arrays make discovery order deterministic, unlike dictionary keys.
let freshConfiguration = try plist(["type": "imageFile", "url": ["relative": newURL.absoluteString]])
let idle: [String: Any] = ["Content": ["Choices": [["Provider": "screensaver", "Configuration": Data([1, 2])]]]]
let fixture: [String: Any] = ["Nodes": [
  desktop(configuration, oldURL),
  ["Spaces": ["active": desktop(freshConfiguration, newURL)]],
  ["Displays": ["external": desktop(configuration, oldURL)]],
  ["SystemDefault": desktop(configuration, oldURL)],
  ["AllSpacesAndDisplays": desktop(configuration, oldURL)],
  ["Idle": idle],
], "Unrelated": "keep"]
try plist(fixture).write(to: wallpaperStore)
setOnAllSpaces(newURL)
let multi = try dictionary(Data(contentsOf: wallpaperStore))
var desktops = 0
func checkDesktops(_ object: Any) throws {
  if let dict = object as? [String: Any] {
    for (key, value) in dict {
      if key == "Desktop" {
        desktops += 1
        let content = (value as! [String: Any])["Content"] as! [String: Any]
        let choices = content["Choices"] as! [[String: Any]]
        expect(choices.count == 1 && content["Shuffle"] as? String == "$null", "one non-shuffling choice")
        let choice = choices[0]
        expect(choice["Provider"] as? String == imageProvider, "image provider")
        expect((choice["Files"] as? [[String: String]])?.first?["relative"] == newURL.absoluteString, "every desktop Files URL")
        let image = try dictionary(choice["Configuration"] as! Data)
        expect((image["url"] as? [String: String])?["relative"] == newURL.absoluteString, "every desktop embedded URL")
        expect(image["placement"] as? String == "fill", "copied placement retained")
      } else { try checkDesktops(value) }
    }
  } else if let array = object as? [Any] { for value in array { try checkDesktops(value) } }
}
try checkDesktops(multi)
expect(desktops == 5, "visited all five fixture desktops")
let nodes = multi["Nodes"] as! [[String: Any]]
expect(NSDictionary(dictionary: nodes[5]["Idle"] as! [String: Any]).isEqual(to: idle), "Idle untouched")
expect(multi["Unrelated"] as? String == "keep", "unrelated fields untouched")
func semantic(_ object: Any) -> Any {
  if let data = object as? Data,
     let decoded = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
    return semantic(decoded)
  }
  if let dict = object as? [String: Any] { return dict.mapValues(semantic) }
  if let array = object as? [Any] { return array.map(semantic) }
  return object
}
setOnAllSpaces(newURL)
let repeated = try dictionary(Data(contentsOf: wallpaperStore))
expect(NSDictionary(dictionary: semantic(repeated) as! [String: Any]).isEqual(to: semantic(multi) as! [String: Any]), "repeat is semantically idempotent")

// Accept both plist encodings, preserve options (including URL metadata), and
// leave unknown provider configuration formats alone rather than inventing one.
for format in [PropertyListSerialization.PropertyListFormat.binary, .xml] {
  let original: [String: Any] = ["type": "imageFile", "url": ["relative": oldURL.absoluteString, "metadata": "keep"], "option": 7]
  let encoded = try PropertyListSerialization.data(fromPropertyList: original, format: format, options: 0)
  try plist(desktop(encoded, oldURL)).write(to: wallpaperStore)
  setOnAllSpaces(newURL)
  let output = try dictionary(Data(contentsOf: wallpaperStore))
  let content = (output["Desktop"] as! [String: Any])["Content"] as! [String: Any]
  let choice = (content["Choices"] as! [[String: Any]])[0]
  let data = choice["Configuration"] as! Data
  var expected = original
  expected["url"] = ["relative": newURL.absoluteString, "metadata": "keep"]
  expect(NSDictionary(dictionary: try dictionary(data)).isEqual(to: expected), "only embedded URL changes (\(format))")
  expect(data.starts(with: Data("bplist00".utf8)), "configuration written as binary plist")
}
let opaqueConfigurations: [Any] = [
  Data("not a plist".utf8),
  try plist(["type": "other", "url": ["relative": oldURL.absoluteString]]),
  try plist(["type": "imageFile", "url": "unknown representation"]),
  try plist(["type": "imageFile"]),
  try plist(["not", "a", "dictionary"]),
  "unknown configuration",
]
for opaque in opaqueConfigurations {
  var input = desktop(Data(), oldURL)
  input["Desktop"] = ["Content": ["Choices": [["Provider": imageProvider, "Files": [["relative": oldURL.absoluteString]], "Configuration": opaque]]]]
  try plist(input).write(to: wallpaperStore)
  setOnAllSpaces(newURL)
  let output = try dictionary(Data(contentsOf: wallpaperStore))
  let content = (output["Desktop"] as! [String: Any])["Content"] as! [String: Any]
  let choice = (content["Choices"] as! [[String: Any]])[0]
  expect(NSDictionary(dictionary: ["value": choice["Configuration"]!]).isEqual(to: ["value": opaque]), "unknown configuration preserved")
}

// Existing no-configuration fallback remains usable; no image settings means
// other providers are not rewritten to an invented image configuration.
let noConfig: [String: Any] = ["Desktop": ["Content": ["Choices": [["Provider": imageProvider, "Files": [["relative": oldURL.absoluteString]], "option": "keep"]]]]]
try plist(noConfig).write(to: wallpaperStore)
setOnAllSpaces(newURL)
let fallback = try dictionary(Data(contentsOf: wallpaperStore))
let fallbackContent = (fallback["Desktop"] as! [String: Any])["Content"] as! [String: Any]
let fallbackChoice = (fallbackContent["Choices"] as! [[String: Any]])[0]
expect(fallbackChoice["Configuration"] == nil && fallbackChoice["option"] as? String == "keep", "missing configuration fallback preserved")
expect((fallbackChoice["Files"] as? [[String: String]])?.first?["relative"] == newURL.absoluteString, "fallback Files updated")
let other: [String: Any] = ["Desktop": idle]
let otherData = try plist(other)
try otherData.write(to: wallpaperStore)
let beforeRestarts = restarts
setOnAllSpaces(newURL)
expect(try Data(contentsOf: wallpaperStore) == otherData, "non-image-only store not written")
expect(restarts == beforeRestarts, "no restart without changed desktops")
try FileManager.default.removeItem(at: wallpaperStore)
setOnAllSpaces(newURL)
expect(restarts == beforeRestarts, "missing store does not restart")
try Data("invalid store".utf8).write(to: wallpaperStore)
setOnAllSpaces(newURL)
expect(restarts == beforeRestarts, "invalid store does not restart")

// The shape macOS 27 writes (the Mac mini's store): Configuration holds only the
// type and the picture's URL; placement and colour are in the Desktop's
// EncodedOptionValues, which stay with each Desktop.
let options = try plist(["values": ["placement": ["picker": ["_0": ["id": "Crop"]]]]])
let oldOnly = try plist(["type": "imageFile", "url": ["relative": oldURL.absoluteString]])
func realDesktop(_ configuration: Data, _ url: URL) -> [String: Any] {
  ["Type": "individual", "Desktop": ["Content": ["Choices": [["Provider": imageProvider,
    "Files": [["relative": url.absoluteString]], "Configuration": configuration]],
    "Shuffle": "$null", "EncodedOptionValues": options]]]
}
try plist(["SystemDefault": realDesktop(oldOnly, oldURL),
           "Spaces": ["S1": ["Default": realDesktop(freshConfiguration, newURL)],
                      "S2": ["Default": realDesktop(oldOnly, oldURL)]]]).write(to: wallpaperStore)
setOnAllSpaces(newURL)
let real = try dictionary(Data(contentsOf: wallpaperStore))
let realSpaces = real["Spaces"] as! [String: Any]
for (name, desktopEntry) in [("SystemDefault", real["SystemDefault"]!),
                             ("S1", (realSpaces["S1"] as! [String: Any])["Default"]!),
                             ("S2", (realSpaces["S2"] as! [String: Any])["Default"]!)] {
  let content = ((desktopEntry as! [String: Any])["Desktop"] as! [String: Any])["Content"] as! [String: Any]
  let choice = (content["Choices"] as! [[String: Any]])[0]
  expect((choice["Files"] as? [[String: String]])?.first?["relative"] == newURL.absoluteString, "macOS 27 shape: \(name) Files URL")
  expect(NSDictionary(dictionary: try dictionary(choice["Configuration"] as! Data))
    .isEqual(to: ["type": "imageFile", "url": ["relative": newURL.absoluteString]]), "macOS 27 shape: \(name) Configuration names the new picture")
  expect(content["EncodedOptionValues"] as? Data == options, "macOS 27 shape: \(name) placement and colour kept")
}
print("wallpaper: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
