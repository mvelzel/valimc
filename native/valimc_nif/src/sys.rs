//! Durability and process limits the BEAM lacks.

use crate::atoms;
use rustler::Atom;

/// fsync a directory so a completed rename survives power loss (Erlang's `:file`
/// cannot open directories). Runs on a dirty I/O scheduler.
#[rustler::nif(schedule = "DirtyIo")]
fn fsync_dir(path: String) -> Result<Atom, String> {
    let dir = std::fs::File::open(&path).map_err(|e| e.to_string())?;
    dir.sync_all().map_err(|e| e.to_string())?;
    Ok(atoms::ok())
}

/// Flush a file through the drive's write cache. On Apple platforms `fsync`
/// stops at the cache and `File::sync_all` issues `F_FULLFSYNC`; any descriptor of
/// the file will do. Runs on a dirty I/O scheduler.
#[rustler::nif(schedule = "DirtyIo")]
fn full_sync(path: String) -> Result<Atom, String> {
    let file = std::fs::File::open(&path).map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    Ok(atoms::ok())
}

/// Set the process's soft limit on open files (`RLIMIT_NOFILE`) to `target`,
/// at most the hard limit and, on macOS, `OPEN_MAX` (10240), as the JVM's
/// `MaxFDLimit` does: macOS starts processes at 256. Returns the limits now in
/// effect, `{soft, hard}`; a refused change leaves them as they were. Startup
/// raises it; tests lower it to provoke `EMFILE`.
#[rustler::nif]
fn set_open_files_limit(target: u64) -> Result<(u64, u64), String> {
    let mut limit = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    // SAFETY: `limit` is a valid `rlimit` for getrlimit/setrlimit to read and write.
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
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
            return Err(std::io::Error::last_os_error().to_string());
        }
    }
    Ok((limit.rlim_cur, limit.rlim_max))
}
