// Audio side: CoreAudio default devices, volume/mute, device list, property
// listeners, and control. No permission needed (no audio data is touched).
import AudioToolbox
import CoreAudio

let systemObject = AudioObjectID(kAudioObjectSystemObject)
let scopeOut = kAudioObjectPropertyScopeOutput, scopeIn = kAudioObjectPropertyScopeInput

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
  -> AudioObjectPropertyAddress {
  AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func has(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool { var a = a; return AudioObjectHasProperty(obj, &a) }

func settable(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress) -> Bool {
  var a = a, s: DarwinBoolean = false
  return AudioObjectIsPropertySettable(obj, &a, &s) == noErr && s.boolValue
}

func get<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ initial: T) -> T? {
  var a = a, v = initial, size = UInt32(MemoryLayout<T>.size)
  guard AudioObjectHasProperty(obj, &a) else { return nil }
  let st = withUnsafeMutableBytes(of: &v) { AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0.baseAddress!) }
  return st == noErr ? v : nil
}

@discardableResult
func set<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
  var a = a
  return withUnsafeBytes(of: value) { AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32($0.count), $0.baseAddress!) }
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
  var a = addr(sel), s: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
  guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr else { return nil }
  return s?.takeRetainedValue() as String?
}

let transportNames: [UInt32: String] = [
  kAudioDeviceTransportTypeBuiltIn: "built-in", kAudioDeviceTransportTypeUSB: "usb",
  kAudioDeviceTransportTypeBluetooth: "bluetooth", kAudioDeviceTransportTypeBluetoothLE: "bluetooth-le",
  kAudioDeviceTransportTypeHDMI: "hdmi", kAudioDeviceTransportTypeDisplayPort: "displayport",
  kAudioDeviceTransportTypeAirPlay: "airplay", kAudioDeviceTransportTypeThunderbolt: "thunderbolt",
  kAudioDeviceTransportTypePCI: "pci", kAudioDeviceTransportTypeFireWire: "firewire",
  kAudioDeviceTransportTypeAVB: "avb", kAudioDeviceTransportTypeVirtual: "virtual",
  kAudioDeviceTransportTypeAggregate: "aggregate", kAudioDeviceTransportTypeAutoAggregate: "aggregate",
  kAudioDeviceTransportTypeContinuityCaptureWired: "continuity", kAudioDeviceTransportTypeContinuityCaptureWireless: "continuity",
]

// The volume a device exposes: the virtual main volume (what the menu bar slider
// moves, spans all channels), else a main-element scalar. HDMI/DisplayPort
// outputs usually have neither.
func volumeAddress(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> AudioObjectPropertyAddress? {
  [addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope), addr(kAudioDevicePropertyVolumeScalar, scope)]
    .first { has(dev, $0) }
}

func rounded(_ v: Float32) -> Double { (Double(v) * 1000).rounded() / 1000 }

/// 0.563, not 0.56299999999999994, in the JSON.
func jsonVolume(_ v: Float32) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.3f", Double(v))) }

func describeAudio(_ old: [String: Any], _ s: [String: Any]) -> String? {
  func uid(_ d: [String: Any], _ k: String) -> Any? { (d[k] as? [String: Any])?["uid"] }
  func uids(_ d: [String: Any]) -> [String] { (d["devices"] as? [[String: Any]] ?? []).compactMap { $0["uid"] as? String } }
  guard !same(uid(old, "output"), uid(s, "output")) || !same(uid(old, "input"), uid(s, "input")) || uids(old) != uids(s)
  else { return nil }   // volume/mute changes stay quiet
  func show(_ k: String) -> String {
    guard let d = s[k] as? [String: Any] else { return "-" }
    return "\(d["name"]!) (\(d["transport"]!)) vol=\(d["volume"]!) muted=\(d["muted"]!)"
  }
  return "output=\(show("output")) input=\(show("input")) devices=\(uids(s).count)"
}

final class Audio {
  var onChange: ((String) -> Void)?
  private let q = DispatchQueue(label: "omacvm-bridge.audio")
  private var watched = Set<AudioObjectID>()

  func start() {
    let system: [(AudioObjectPropertySelector, String)] = [(kAudioHardwarePropertyDevices, "devices"),
      (kAudioHardwarePropertyDefaultOutputDevice, "default-output"), (kAudioHardwarePropertyDefaultInputDevice, "default-input")]
    for (sel, why) in system {
      var a = addr(sel)
      AudioObjectAddPropertyListenerBlock(systemObject, &a, q) { [weak self] _, _ in
        self?.watchDevices(); self?.onChange?(why)
      }
    }
    q.async { self.watchDevices() }
  }

  // Volume/mute listeners on every device (so a non-default device is already
  // watched when it becomes the default). Runs on q.
  private func watchDevices() {
    let ids = deviceIDs()
    for dev in ids where !watched.contains(dev) {
      watched.insert(dev)
      for scope in [scopeOut, scopeIn] {
        for sel in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
          var a = addr(sel, scope)
          guard AudioObjectHasProperty(dev, &a) else { continue }
          AudioObjectAddPropertyListenerBlock(dev, &a, q) { [weak self] _, _ in self?.onChange?("volume") }
        }
      }
    }
    watched.formIntersection(ids)   // listeners of removed devices go away with them
  }

  func deviceIDs() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
  }

  func defaultDevice(output: Bool) -> AudioObjectID? {
    let id = get(systemObject, addr(output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice),
                 AudioObjectID(0))
    return id == 0 ? nil : id
  }

  func hasStreams(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
    var a = addr(kAudioDevicePropertyStreams, scope), size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr && size > 0
  }

  private func info(_ dev: AudioObjectID, out: AudioObjectID?, inp: AudioObjectID?) -> [String: Any] {
    let transport = get(dev, addr(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
    return ["uid": nn(getString(dev, kAudioDevicePropertyDeviceUID)), "name": nn(getString(dev, kAudioObjectPropertyName)),
            "transport": transportNames[transport] ?? "unknown",
            "has_output": hasStreams(dev, scopeOut), "has_input": hasStreams(dev, scopeIn),
            "default_output": dev == out, "default_input": dev == inp]
  }

  private func detail(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope, out: AudioObjectID?, inp: AudioObjectID?) -> [String: Any] {
    var d = info(dev, out: out, inp: inp)
    let va = volumeAddress(dev, scope), ma = addr(kAudioDevicePropertyMute, scope)
    d["has_volume"] = va != nil
    d["volume_settable"] = va.map { settable(dev, $0) } ?? false
    d["volume"] = nn(va.flatMap { get(dev, $0, Float32(0)) }.map(jsonVolume))
    d["has_mute"] = has(dev, ma)
    d["muted"] = nn(get(dev, ma, UInt32(0)).map { $0 != 0 })
    return d
  }

  func state() -> [String: Any] {
    let out = defaultDevice(output: true), inp = defaultDevice(output: false)
    let devices = deviceIDs().map { info($0, out: out, inp: inp) }
      .filter { $0["has_output"] as! Bool || $0["has_input"] as! Bool }
    return ["output": nn(out.map { detail($0, scopeOut, out: out, inp: inp) }),
            "input": nn(inp.map { detail($0, scopeIn, out: out, inp: inp) }),
            "devices": devices]
  }

  // ---- control ----
  private func device(input: Bool) throws -> AudioObjectID {
    guard let d = defaultDevice(output: !input) else { throw APIError(409, "no default \(input ? "input" : "output") device") }
    return d
  }

  private func name(_ dev: AudioObjectID) -> String { getString(dev, kAudioObjectPropertyName) ?? "device \(dev)" }

  /// Absolute (0..1) or relative volume; unmute = also unmute, like the Mac's volume keys.
  /// The output mutes at 0 and unmutes above it (OutputMute: 0 is not silence).
  func setVolume(input: Bool, absolute: Double?, delta: Double?, unmute: Bool) throws -> (volume: Double, muted: Bool) {
    let scope = input ? scopeIn : scopeOut, dev = try device(input: input)
    guard let va = volumeAddress(dev, scope) else { throw APIError(409, "\(name(dev)) has no volume control") }
    guard settable(dev, va) else { throw APIError(409, "the volume of \(name(dev)) cannot be changed") }
    let now = get(dev, va, Float32(0)).map(Double.init)
    let target = Float32(max(0, min(1, absolute ?? ((now ?? 0) + (delta ?? 0)))))
    let st = set(dev, va, target)
    guard st == noErr else { throw APIError(500, "setting the volume failed (OSStatus \(st))") }
    let ma = addr(kAudioDevicePropertyMute, scope)
    let mute = input ? (unmute ? false : nil) : OutputMute.after(before: now, target: Double(target), unmute: unmute)
    if let mute, let m = get(dev, ma, UInt32(0)), (m == 1) != mute { set(dev, ma, UInt32(mute ? 1 : 0)) }
    return (rounded(get(dev, va, target) ?? target), get(dev, ma, UInt32(0)) == 1)
  }

  /// One volume-key step on the default output, snapped to the grid like macOS
  /// (steps = 16, or 64 for Shift+Option).
  func stepVolume(up: Bool, steps: Double) throws -> (volume: Double, muted: Bool) {
    let dev = try device(input: false)
    guard let va = volumeAddress(dev, scopeOut) else { throw APIError(409, "\(name(dev)) has no volume control") }
    let now = Double(get(dev, va, Float32(0)) ?? 0)
    return try setVolume(input: false, absolute: ((now * steps).rounded() + (up ? 1 : -1)) / steps, delta: nil, unmute: true)
  }

  var outputVolumeSettable: Bool {
    guard let dev = defaultDevice(output: true), let va = volumeAddress(dev, scopeOut) else { return false }
    return settable(dev, va)
  }

  var outputMuteSettable: Bool {
    guard let dev = defaultDevice(output: true) else { return false }
    return settable(dev, addr(kAudioDevicePropertyMute, scopeOut))
  }

  /// Default output's volume (0-100) and mute, for "osd" events.
  func outputSnap() -> VolumeSnap? {
    guard let dev = defaultDevice(output: true) else { return nil }
    let v = volumeAddress(dev, scopeOut).flatMap { get(dev, $0, Float32(0)) }
    return VolumeSnap(device: dev, name: getString(dev, kAudioObjectPropertyName),
                      value: v.map { Int((Double($0) * 100).rounded()) },
                      muted: get(dev, addr(kAudioDevicePropertyMute, scopeOut), UInt32(0)) == 1)
  }

  /// muted == nil toggles.
  func setMute(input: Bool, muted: Bool?) throws -> (volume: Double?, muted: Bool) {
    let scope = input ? scopeIn : scopeOut, dev = try device(input: input), ma = addr(kAudioDevicePropertyMute, scope)
    guard has(dev, ma), settable(dev, ma) else { throw APIError(409, "\(name(dev)) has no mute control") }
    let target = muted ?? !(get(dev, ma, UInt32(0)) == 1)
    let st = set(dev, ma, UInt32(target ? 1 : 0))
    guard st == noErr else { throw APIError(500, "setting mute failed (OSStatus \(st))") }
    return (volumeAddress(dev, scope).flatMap { get(dev, $0, Float32(0)) }.map(rounded), target)
  }

  /// Makes the device with this UID the default output/input. Sound effects follow
  /// the output when they were playing through the previous default (as in the menu bar).
  func setDefault(uid: String, output: Bool) throws -> String {
    let scope = output ? scopeOut : scopeIn
    guard let dev = deviceIDs().first(where: { getString($0, kAudioDevicePropertyDeviceUID) == uid }) else {
      throw APIError(404, "no audio device with uid \(uid)")
    }
    guard hasStreams(dev, scope) else { throw APIError(400, "\(name(dev)) is not an \(output ? "output" : "input") device") }
    let sel = output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    let previous = defaultDevice(output: output)
    let st = set(systemObject, addr(sel), dev)
    guard st == noErr else { throw APIError(500, "switching to \(name(dev)) failed (OSStatus \(st))") }
    let fx = addr(kAudioHardwarePropertyDefaultSystemOutputDevice)
    if output, let previous, get(systemObject, fx, AudioObjectID(0)) == previous { set(systemObject, fx, dev) }
    return name(dev)
  }
}

struct VolumeSnap { let device: AudioObjectID, name: String?, value: Int?, muted: Bool }
