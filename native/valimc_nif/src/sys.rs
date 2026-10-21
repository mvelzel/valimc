//! Durability and process limits the BEAM lacks.

use crate::done;
use rustler::{Atom, NifResult};

mod posix {
    rustler::atoms! {
        eacces, eagain, ebadf, edquot, eintr, eio, eisdir, emfile, enfile, enoent, enospc,
        enotdir, enotsup, eperm, erofs,
    }
}

/// An OS error as `:file` names it (`:enoent`, `:emfile`, ...); `:eio` for
/// any other.
fn posix(error: std::io::Error) -> Atom {
    match error.raw_os_error().unwrap_or(libc::EIO) {
        libc::EACCES => posix::eacces(),
        libc::EAGAIN => posix::eagain(),
        libc::EBADF => posix::ebadf(),
        libc::EDQUOT => posix::edquot(),
        libc::EINTR => posix::eintr(),
        libc::EISDIR => posix::eisdir(),
        libc::EMFILE => posix::emfile(),
        libc::ENFILE => posix::enfile(),
        libc::ENOENT => posix::enoent(),
        libc::ENOSPC => posix::enospc(),
        libc::ENOTDIR => posix::enotdir(),
        libc::ENOTSUP => posix::enotsup(),
        libc::EPERM => posix::eperm(),
        libc::EROFS => posix::erofs(),
        _ => posix::eio(),
    }
}

/// `File::sync_all` of `path`: `F_FULLFSYNC` on Apple platforms, where
/// `fsync` stops at the drive's cache; any descriptor of the file will do.
fn sync(path: &str) -> Result<(), Atom> {
    let file = std::fs::File::open(path).map_err(posix)?;
    file.sync_all().map_err(posix)
}

/// fsync a directory so a completed rename survives power loss (Erlang's `:file`
/// cannot open directories). Runs on a dirty I/O scheduler.
#[rustler::nif(schedule = "DirtyIo")]
fn fsync_dir(path: String) -> NifResult<Atom> {
    done(sync(&path))
}

/// Flush a file through the drive's write cache. Runs on a dirty I/O scheduler.
#[rustler::nif(schedule = "DirtyIo")]
fn full_sync(path: String) -> NifResult<Atom> {
    done(sync(&path))
}

/// Set the process's soft limit on open files (`RLIMIT_NOFILE`) to `target`,
/// at most the hard limit and, on macOS, `OPEN_MAX` (10240), as the JVM's
/// `MaxFDLimit` does: macOS starts processes at 256. Returns the limits now in
/// effect, `{soft, hard}`; a refused change leaves them as they were. Startup
/// raises it; tests lower it to provoke `EMFILE`.
#[rustler::nif]
fn set_open_files_limit(target: u64) -> Result<(u64, u64), Atom> {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: `limit` is a valid `rlimit` for getrlimit/setrlimit to read and write.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        return Err(posix(std::io::Error::last_os_error()));
    }
    let mut soft = (target as libc::rlim_t).min(limit.rlim_max);
    if cfg!(target_os = "macos") {
        soft = soft.min(10_240);
    }
    if soft != limit.rlim_cur {
        let wanted = libc::rlimit {
            rlim_cur: soft,
            rlim_max: limit.rlim_max,
        };
        // SAFETY: as above; a refused change returns -1 and changes nothing.
        unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &wanted) };
        // SAFETY: as above.
        if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
            return Err(posix(std::io::Error::last_os_error()));
        }
    }
    Ok((limit.rlim_cur, limit.rlim_max))
}
