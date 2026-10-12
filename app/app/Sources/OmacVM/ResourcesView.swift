import OmacVMWindow
import SwiftUI

extension VMConfig {
    /// This VM as it starts on this Mac: CPUs and memory this Mac does not
    /// allow (a VM copied from a bigger Mac) are the Best tier's, for this
    /// start only (vm.env stays). ResourceLimits.startSize.
    var forThisMac: VMConfig {
        guard let s = ResourceLimits.mac.startSize(cpus: cpus, memoryMB: memoryMB, best: Mac.tier(3)) else { return self }
        var c = self
        c.cpus = s.cpus
        c.memoryMB = s.memoryMB
        return c
    }

    /// The window's note when forThisMac differs from vm.env.
    var startSizeNote: String? {
        let s = forThisMac
        guard s != self else { return nil }
        return ResourceLimits.mac.startSizeText(cpus: cpus, memoryMB: memoryMB, start: (s.cpus, s.memoryMB))
    }
}

extension ResourceLimits {
    /// This Mac's, as `omacvm resources` has them.
    static var mac: ResourceLimits { ResourceLimits(macCores: Mac.cores, macMemoryGB: Mac.memoryGB) }
}
