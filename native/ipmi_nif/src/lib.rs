use std::ffi::{c_char, c_void, CString};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, TryLockError};
use std::time::{Duration, Instant};

// The pinned SDK owns one global interface and response buffer.
static SDK: Mutex<()> = Mutex::new(());

struct Cancellation(AtomicBool);

#[rustler::resource_impl]
impl rustler::Resource for Cancellation {
    fn down<'a>(
        &'a self,
        _env: rustler::Env<'a>,
        _pid: rustler::LocalPid,
        _monitor: rustler::Monitor,
    ) {
        self.0.store(true, Ordering::Release);
    }
}

#[rustler::nif]
fn cancellation_token(env: rustler::Env) -> rustler::ResourceArc<Cancellation> {
    let token = rustler::ResourceArc::new(Cancellation(AtomicBool::new(false)));
    if token.monitor(Some(env), &env.pid()).is_none() {
        token.0.store(true, Ordering::Release);
    }
    token
}

#[rustler::nif]
fn cancel(token: rustler::ResourceArc<Cancellation>) {
    token.0.store(true, Ordering::Release);
}

extern "C" fn cancelled(context: *const c_void) -> i32 {
    unsafe {
        (&*(context as *const Cancellation))
            .0
            .load(Ordering::Acquire) as i32
    }
}

fn acquire(
    deadline: Instant,
    cancellation: &Cancellation,
) -> Result<MutexGuard<'static, ()>, &'static str> {
    loop {
        if cancellation.0.load(Ordering::Acquire) {
            return Err("cancelled");
        }
        if Instant::now() >= deadline {
            return Err("unreachable");
        }
        match SDK.try_lock() {
            Ok(guard) => return Ok(guard),
            Err(TryLockError::WouldBlock) => std::thread::sleep(Duration::from_millis(1)),
            Err(TryLockError::Poisoned(_)) => return Err("unreachable"),
        }
    }
}

#[derive(rustler::NifMap)]
struct SolRequest {
    input: Vec<u8>,
    instance: u8,
    flags: u8,
    generate_break: bool,
    read_ms: u32,
    max_output_bytes: u32,
}

#[repr(C)]
struct SolExchange {
    instance: u8,
    flags: u8,
    generate_break: u8,
    input_length: u16,
    input: *const u8,
    read_ms: u32,
    max_output_bytes: u32,
}

#[repr(C)]
struct SolOutcome {
    activation_completion: i32,
    deactivation_completion: i32,
    input_acknowledged: u32,
    output_length: u32,
    output_bytes: u32,
    output_truncated: u8,
    session_closed: u8,
    payload_port: u16,
}

#[derive(rustler::NifMap)]
struct SolResult {
    status: i32,
    activation_completion: i32,
    deactivation_completion: i32,
    input_acknowledged: u32,
    output: Vec<u8>,
    output_bytes: u32,
    output_truncated: bool,
    session_closed: bool,
    payload_port: u16,
    cancelled: bool,
}

#[derive(rustler::NifMap)]
struct Request {
    netfn: u8,
    command: u8,
    data: Vec<u8>,
    lun: u8,
    target_address: u8,
    target_channel: u8,
    transit_address: u8,
    transit_channel: u8,
}

#[repr(C)]
struct Command {
    netfn: u8,
    command: u8,
    lun: u8,
    target_address: u8,
    target_channel: u8,
    transit_address: u8,
    transit_channel: u8,
    data_length: u16,
    data: *const u8,
}

extern "C" {
    fn opsonde_ipmi_sol(
        host: *const c_char,
        port: u16,
        user: *const c_char,
        password: *const c_char,
        timeout_ms: u64,
        request: *const SolExchange,
        output: *mut u8,
        outcome: *mut SolOutcome,
        cancelled: extern "C" fn(*const c_void) -> i32,
        cancellation: *const c_void,
    ) -> i32;
    fn opsonde_ipmi_command(
        host: *const c_char,
        port: u16,
        user: *const c_char,
        password: *const c_char,
        timeout_ms: u64,
        request: *const Command,
        completion: *mut u8,
        data: *mut u8,
        length: *mut u32,
        cancelled: extern "C" fn(*const c_void) -> i32,
        cancellation: *const c_void,
    ) -> i32;
}

#[rustler::nif(schedule = "DirtyIo")]
fn send_command(
    address: String,
    username: String,
    password: String,
    timeout_ms: u64,
    request: Request,
    token: rustler::ResourceArc<Cancellation>,
) -> Result<(u8, Vec<u8>), &'static str> {
    if !(1..=30_000).contains(&timeout_ms)
        || request.netfn > 62
        || request.netfn % 2 != 0
        || request.data.len() > 2048
        || request.lun > 3
        || request.target_channel > 15
        || request.transit_channel > 15
        || username.is_empty()
        || username.len() > 16
        || password.is_empty()
        || password.len() > 16
    {
        return Err("invalid_request");
    }
    let target: SocketAddr = address.parse().map_err(|_| "invalid_request")?;
    let host = CString::new(target.ip().to_string()).unwrap();
    let user = CString::new(username).map_err(|_| "invalid_request")?;
    let password = CString::new(password).map_err(|_| "invalid_request")?;
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let _guard = acquire(deadline, &token)?;
    let remaining = deadline
        .saturating_duration_since(Instant::now())
        .as_millis() as u64;
    if remaining == 0 {
        return Err("unreachable");
    }
    let command = Command {
        netfn: request.netfn,
        command: request.command,
        lun: request.lun,
        target_address: request.target_address,
        target_channel: request.target_channel,
        transit_address: request.transit_address,
        transit_channel: request.transit_channel,
        data_length: request.data.len() as u16,
        data: request.data.as_ptr(),
    };
    let mut completion = 0;
    let mut length = 0;
    let mut data = vec![0u8; 1024];
    let status = unsafe {
        opsonde_ipmi_command(
            host.as_ptr(),
            target.port(),
            user.as_ptr(),
            password.as_ptr(),
            remaining,
            &command,
            &mut completion,
            data.as_mut_ptr(),
            &mut length,
            cancelled,
            &*token as *const Cancellation as *const c_void,
        )
    };
    match status {
        0 => {
            data.truncate(length as usize);
            Ok((completion, data))
        }
        3 => Err("outcome_unknown"),
        4 => Err("authentication"),
        6 => Err("cancelled"),
        _ => Err("unreachable"),
    }
}

#[rustler::nif(schedule = "DirtyIo")]
fn sol_exchange(
    address: String,
    username: String,
    password: String,
    timeout_ms: u64,
    request: SolRequest,
    token: rustler::ResourceArc<Cancellation>,
) -> Result<SolResult, &'static str> {
    if !(1..=30_000).contains(&timeout_ms)
        || !(1..=15).contains(&request.instance)
        || request.input.len() > 2048
        || !(1..=30_000).contains(&request.max_output_bytes)
        || request.read_ms as u64 >= timeout_ms
        || username.is_empty()
        || username.len() > 16
        || password.is_empty()
        || password.len() > 16
    {
        return Err("invalid_request");
    }
    let target: SocketAddr = address.parse().map_err(|_| "invalid_request")?;
    let host = CString::new(target.ip().to_string()).unwrap();
    let user = CString::new(username).map_err(|_| "invalid_request")?;
    let password = CString::new(password).map_err(|_| "invalid_request")?;
    let deadline = Instant::now() + Duration::from_millis(timeout_ms);
    let _guard = acquire(deadline, &token)?;
    let remaining = deadline
        .saturating_duration_since(Instant::now())
        .as_millis() as u64;
    if remaining == 0 {
        return Err("unreachable");
    }
    let exchange = SolExchange {
        instance: request.instance,
        flags: request.flags,
        generate_break: request.generate_break as u8,
        input_length: request.input.len() as u16,
        input: request.input.as_ptr(),
        read_ms: request.read_ms,
        max_output_bytes: request.max_output_bytes,
    };
    let mut outcome = SolOutcome {
        activation_completion: -1,
        deactivation_completion: -1,
        input_acknowledged: 0,
        output_length: 0,
        output_bytes: 0,
        output_truncated: 0,
        session_closed: 0,
        payload_port: 0,
    };
    let mut output = vec![0u8; request.max_output_bytes as usize];
    let status = unsafe {
        opsonde_ipmi_sol(
            host.as_ptr(),
            target.port(),
            user.as_ptr(),
            password.as_ptr(),
            remaining,
            &exchange,
            output.as_mut_ptr(),
            &mut outcome,
            cancelled,
            &*token as *const Cancellation as *const c_void,
        )
    };
    match status {
        1 | 2 => Err("unreachable"),
        4 => Err("authentication"),
        6 => Err("cancelled"),
        _ => {
            output.truncate(outcome.output_length as usize);
            Ok(SolResult {
                status,
                activation_completion: outcome.activation_completion,
                deactivation_completion: outcome.deactivation_completion,
                input_acknowledged: outcome.input_acknowledged,
                output,
                output_bytes: outcome.output_bytes,
                output_truncated: outcome.output_truncated != 0,
                session_closed: outcome.session_closed != 0,
                payload_port: outcome.payload_port,
                cancelled: token.0.load(Ordering::Acquire),
            })
        }
    }
}

rustler::init!("Elixir.Opsonde.Transports.IPMI");
