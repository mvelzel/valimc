//! Background threads for generation (VMC-081c): one per core at a lower OS
//! priority than the BEAM's schedulers, so generation takes the CPU the
//! simulation leaves and never the dirty schedulers the owners call into.
//!
//! A job runs work that calls no BEAM function and sends its result to the
//! calling process as `{tag, :ok, value}`, or `{tag, :raise, reason}` for
//! what the dirty NIF would raise (`Valimc.Native.background/1` waits for
//! it). Jobs that finish work already started go before queued bulk work.
//! A panic is caught and raised the same way; a process that died meanwhile
//! never gets its result.

use rustler::{Atom, Encoder, Env, LocalPid, OwnedEnv, Term};
use std::collections::VecDeque;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Condvar, Mutex, OnceLock};

mod atoms {
    rustler::atoms! { ok, raise }
}

type Job = Box<dyn FnOnce() + Send>;

struct Pool {
    queue: Mutex<VecDeque<Job>>,
    ready: Condvar,
    threads: usize,
}

static POOL: OnceLock<Pool> = OnceLock::new();
static CONFIG: Mutex<Option<(usize, i32)>> = Mutex::new(None);

// Unless configured first: every core, nice 10.
fn pool() -> &'static Pool {
    POOL.get_or_init(|| {
        let (threads, nice) = CONFIG
            .lock()
            .map(|c| *c)
            .unwrap_or(None)
            .unwrap_or_else(|| {
                let cores = std::thread::available_parallelism().map_or(1, |n| n.get());
                (cores, 10)
            });
        for i in 0..threads {
            std::thread::Builder::new()
                .name(format!("valimc-gen-{i}"))
                .spawn(move || {
                    lower_priority(nice);
                    run()
                })
                .expect("background thread");
        }
        Pool {
            queue: Mutex::new(VecDeque::new()),
            ready: Condvar::new(),
            threads,
        }
    })
}

fn run() {
    let pool = pool();
    loop {
        let job = {
            let mut queue = pool.queue.lock().unwrap_or_else(|e| e.into_inner());
            loop {
                match queue.pop_front() {
                    Some(job) => break job,
                    None => queue = pool.ready.wait(queue).unwrap_or_else(|e| e.into_inner()),
                }
            }
        };
        job();
    }
}

// Linux's nice is per thread; macOS lowers a thread by its QoS class.
#[cfg(target_os = "linux")]
fn lower_priority(nice: i32) {
    unsafe {
        libc::setpriority(libc::PRIO_PROCESS, 0, nice);
    }
}

#[cfg(target_os = "macos")]
fn lower_priority(nice: i32) {
    if nice > 0 {
        unsafe {
            libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_UTILITY, 0);
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn lower_priority(_nice: i32) {}

/// Run `work` on a background thread, its result sent to the calling
/// process with `tag`; `urgent` work goes before queued work.
pub(crate) fn submit<'a, T, F>(env: Env<'a>, tag: Term<'a>, urgent: bool, work: F) -> Atom
where
    T: Encoder,
    F: FnOnce() -> Result<T, String> + Send + 'static,
{
    let pid: LocalPid = env.pid();
    let mut owned = OwnedEnv::new();
    let tag = owned.save(tag);
    let job: Job = Box::new(move || {
        let result = catch_unwind(AssertUnwindSafe(work)).unwrap_or_else(|panic| {
            let reason = panic
                .downcast_ref::<&str>()
                .map(|s| s.to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".to_string());
            Err(format!("background job panicked: {reason}"))
        });
        let _ = owned.send_and_clear(&pid, |env| {
            let tag = tag.load(env);
            match result {
                Ok(value) => (tag, atoms::ok(), value).encode(env),
                Err(reason) => (tag, atoms::raise(), reason).encode(env),
            }
        });
    });
    let pool = pool();
    {
        let mut queue = pool.queue.lock().unwrap_or_else(|e| e.into_inner());
        if urgent {
            queue.push_front(job)
        } else {
            queue.push_back(job)
        }
    }
    pool.ready.notify_one();
    atoms::ok()
}

/// Set the threads and their nice value before the first job (a later call
/// changes nothing); the threads running.
#[rustler::nif]
fn background_threads(threads: usize, nice: i32) -> usize {
    if POOL.get().is_none() && threads > 0 {
        if let Ok(mut config) = CONFIG.lock() {
            *config = Some((threads, nice));
        }
    }
    pool().threads
}
