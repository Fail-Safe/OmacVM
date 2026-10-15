import Foundation
import OmacVMUSB

// Vendor HID devices (USBHID.swift, the "Vendor HID devices" switch): on
// made-up IORegistry trees and fakes; no device is read or opened.

/// A vendor bootloader as macOS shows it: one HID interface, its IOHIDDevice
/// with a vendor-page report descriptor (60-byte input and output reports).
func hidTree(registryID: UInt64 = 0x1_0000_0123, serial: String = "BOOT-01", page: Int = 0xff00,
             subclass: Int = 0, interfaces: Int = 1, extraChild: String? = nil) -> USBScan.Entry {
    let desc = Data([0x06, UInt8(page & 0xff), UInt8(page >> 8), 0x09, 0x01, 0xa1, 0x01,
                     0x75, 0x08, 0x95, 0x3c, 0x09, 0x01, 0x81, 0x02, 0x09, 0x01, 0x91, 0x02, 0xc0])
    let usage: [String: Any] = ["PrimaryUsagePage": page, "PrimaryUsage": 1,
                                "DeviceUsagePairs": [["DeviceUsagePage": page, "DeviceUsage": 1]]]
    var hidChildren = [USBScan.Entry(registryID: registryID + 1, className: "IOHIDInterface", properties: usage)]
    if let extraChild { hidChildren.append(USBScan.Entry(registryID: registryID + 2, className: extraChild)) }
    let hid = USBScan.Entry(registryID: registryID, className: "AppleUserHIDDevice", conforms: ["IOHIDDevice"], properties: [
        "VendorID": 0x1209, "ProductID": 0x0007, "SerialNumber": serial, "Product": "Vendor Bootloader",
        "Transport": "USB", "ReportDescriptor": desc,
    ].merging(usage) { a, _ in a }, children: hidChildren)
    let ifs = (0..<interfaces).map { i in
        USBScan.Entry(registryID: 20 + UInt64(i), className: "IOUSBHostInterface", properties: [
            "bInterfaceClass": 3, "bInterfaceSubClass": subclass, "bInterfaceProtocol": 0,
        ], children: i == 0 ? [hid] : [])
    }
    return USBScan.Entry(registryID: 11, className: "IOUSBHostDevice",
                         properties: ["idVendor": 0x1209, "idProduct": 0x0007], children: ifs)
}

/// The device as the plain scan reads it (switch off: as before this change).
let hidPlain = USBDevice(id: USBDeviceID(vendor: 0x1209, product: 0x0007), name: "Vendor Bootloader", deviceClass: 0,
                         interfaces: [I(number: 0, interfaceClass: 3, users: ["AppleUserHIDDevice"])],
                         serial: "BOOT-01", location: 0x0130_0000, address: 7)

func vendorHIDTests() {
    // The switch: off by default, per VM, "on" only.
    let folder = freshFolder("vendor-hid")
    expect(!USBVendorHID.isOn(folder: folder) && !USBVendorHID.isOn(fileText: "yes") && USBVendorHID.isOn(fileText: "on\n"),
           "vendor HID: off without its file; only \"on\" turns it on")
    try? USBVendorHID.set(true, folder: folder)
    let on = USBVendorHID.isOn(folder: folder)
    try? USBVendorHID.set(false, folder: folder)
    expect(on && !USBVendorHID.isOn(folder: folder), "vendor HID: the switch is saved in the VM's folder")

    // Switch off: the device as before (macOS's HID driver has it), usb-host only.
    expect(hidPlain.hid == nil && hidPlain.availability == .usedByMac("macOS uses it as a keyboard, mouse or security key"),
           "vendor HID off: the board stays with the Mac, as before")
    expect(USBQMP.attachArguments(hidPlain)["driver"] as? String == "usb-host", "vendor HID off: QEMU never gets usb-host-hid")
    let (s0, m0, a0, _, _, _) = rig()
    s0.plugged(hidPlain)
    expect(a0.asked.isEmpty && m0.log.isEmpty, "vendor HID off: never asked about, never connected")

    // Switch on: which devices have a HID part QEMU takes.
    let part = USBHID.resolve(hidTree())
    expect(part == USBHID(registryID: 0x1_0000_0123, serial: "BOOT-01"), "vendor HID: a vendor bootloader's HID part is read")
    expect(USBHID.candidate(hidPlain) && !USBHID.candidate(stlink) && !USBHID.candidate(key),
           "vendor HID: only a device with a single HID interface is read further")
    let refused: [(String, USBScan.Entry)] = [
        ("a keyboard's usage page", hidTree(page: 0x0001)),
        ("a boot interface (keyboard, mouse)", hidTree(subclass: 1)),
        ("two interfaces", hidTree(interfaces: 2)),
        ("a Mac app has it open", hidTree(extraChild: "IOHIDLibUserClient")),
        ("no serial number", hidTree(serial: "")),
    ]
    for (why, tree) in refused { expect(USBHID.resolve(tree) == nil, "vendor HID: refused: \(why)") }

    var board = hidPlain
    board.hid = part
    expect(board.availability == .free, "vendor HID on: the board can go to the VM")
    let a = USBQMP.attachArguments(board)
    expect(a["driver"] as? String == "usb-host-hid" && a["id"] as? String == "usbh-01300000" && a["bus"] as? String == "usb0.0"
           && a["registry-id"] as? UInt64 == 0x1_0000_0123 && a["vendorid"] as? UInt16 == 0x1209
           && a["productid"] as? UInt16 == 0x0007 && a["serial"] as? String == "BOOT-01" && a["hostbus"] == nil,
           "vendor HID on: device_add usb-host-hid by its HID part's registry id, vendor, product and serial")
    expect(USBQMP.reason(qemuError: "failed to find the HID device (unplugged)") == .gone
           && USBQMP.reason(qemuError: "failed to open the HID device (in use or not allowed): 0xe00002c5") == .busy,
           "vendor HID: QEMU's refusals in the user's terms")

    // The session: macOS publishes the HID part after the device.
    do {
        let (s, m, ask, _, _, lines) = rig()
        s.plugged(hidPlain)
        s.plugged(board)
        expect(s.plugs[board.location]?.state == .asking && ask.asked.count == 1, "vendor HID: its HID part came later: asked then")
        ask.answer(true)
        expect(s.plugs[board.location]?.state == .connected && m.log == ["attach 1300000"], "vendor HID: Connect gives it to the VM")
        s.plugged(board)
        expect(m.log.count == 1, "vendor HID: the same reading again changes nothing")
        // macOS made a new HID part (its driver restarted): QEMU's is gone.
        var renewed = board
        renewed.hid = USBHID(registryID: 0x1_0000_0200, serial: "BOOT-01")
        s.plugged(renewed)
        expect(m.log == ["attach 1300000", "detach 1300000"] && s.plugs[board.location]?.device == renewed
               && ask.asked.count == 2 && lines().last?.contains("disconnected (macOS changed its HID part)") == true,
               "vendor HID: a new HID part: the old one taken back, asked again")
        ask.answer(true)
        s.plugged(hidPlain)
        expect(m.log.suffix(2) == ["attach 1300000", "detach 1300000"] && s.plugs[board.location]?.state == .kept("macOS uses it as a keyboard, mouse or security key"),
               "vendor HID: its HID part gone: taken back, stays with the Mac")
    }
    // Remembered: connected at the next plug without a question; unplugged and back (a reset).
    do {
        var memory = USBMemory()
        memory.remember(board, .omarchy)
        let (s, m, ask, c, _, _) = rig(memory)
        s.plugged(board)
        expect(s.plugs[board.location]?.state == .connected && ask.asked.isEmpty, "vendor HID: Always Connect: connected when plugged in")
        s.unplugged(location: board.location)
        var back = board
        back.hid = USBHID(registryID: 0x1_0000_0300, serial: "BOOT-01")
        s.plugged(back)
        m.have.insert(board.location)   // QEMU still lists its device (a stale one)
        c.advance(USBSession.grace)
        expect(m.log == ["attach 1300000", "detach 1300000", "attach 1300000"] && s.plugs[board.location]?.device == back
               && s.plugs[board.location]?.state == .connected,
               "vendor HID: back after a reset with a new HID part: QEMU's old device removed, the new one added")
    }
}
