import Foundation

/// Rocky's own open descriptors, kept out of the processes it starts (Part E of M2.9).
enum FileDescriptors {
    /// Marks every descriptor of Rocky's from 3 up close-on-exec (`FD_CLOEXEC`), for a spawn that closes nothing
    /// itself: `forkpty`, then `execve`, keeps every descriptor without the flag. The child's 0, 1 and 2 are the
    /// pseudo-terminal, which forkpty dup2's there, and dup2 clears the flag. Rocky's own use of its descriptors does not
    /// change, since the flag acts only at `execve`, which Rocky never calls on itself.
    ///
    /// A descriptor another thread opens between this marking and the fork still reaches the child. The window is tiny:
    /// SwiftTerm copying the arguments and the environment, then `openpty`, before it forks. Foundation's `Process`
    /// needs none of this: its children already see only their 0, 1 and 2 (`ChildDescriptorsTests`).
    static func closeAllOnExec() {
        for descriptor in openDescriptors() where descriptor > 2 {
            let flags = fcntl(descriptor, F_GETFD)
            if flags >= 0, flags & FD_CLOEXEC == 0 {
                _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
            }
        }
    }

    /// This process's open descriptors, from the kernel's table (`proc_pidinfo`), which opens nothing to read it; from
    /// `/dev/fd` if that fails. Not every number below the limit: that limit is in the hundreds of thousands.
    static func openDescriptors() -> [Int32] {
        let pid = getpid()
        let stride = MemoryLayout<proc_fdinfo>.stride
        // The size asked for first has room for more descriptors than are open; ones opened meanwhile fit in it.
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        if size > 0 {
            var infos = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
            let filled = infos.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            if filled > 0 { return infos.prefix(Int(filled) / stride).map(\.proc_fd) }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? []
        return names.compactMap { Int32($0) }
    }
}
