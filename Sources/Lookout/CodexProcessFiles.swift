import Darwin
import Foundation

/// Read-only libproc lookup for the handful of Codex CLI candidates. No child commands,
/// environment reads, transcript contents or persistent path cache.
enum CodexProcessFiles {
    static let descriptorLimit = 4096

    static func openRollouts(pid: Int32) -> Set<String> {
        guard pid > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard required > 0 else { return [] }
        let count = min(Int(required) / stride + 16, descriptorLimit)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let bytes = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard bytes > 0 else { return [] }
        var paths: Set<String> = []
        for descriptor in descriptors.prefix(min(Int(bytes) / stride, count))
            where descriptor.proc_fdtype == PROX_FDTYPE_VNODE {
            var info = vnode_fdinfowithpath()
            let size = MemoryLayout<vnode_fdinfowithpath>.size
            let read = proc_pidfdinfo(
                pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(size)
            )
            guard read == size else { continue }
            let path = withUnsafeBytes(of: info.pvip.vip_path) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            let name = (path as NSString).lastPathComponent
            if name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") { paths.insert(path) }
        }
        return paths
    }
}
