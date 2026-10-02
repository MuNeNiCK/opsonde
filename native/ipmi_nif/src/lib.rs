use std::ffi::{c_char, CString};
use std::net::SocketAddr;
use std::sync::{Mutex, TryLockError};
use std::time::{Duration, Instant};

// The pinned SDK owns one global interface and response buffer.
static SDK: Mutex<()> = Mutex::new(());

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
    ) -> i32;
}

#[rustler::nif(schedule = "DirtyIo")]
fn send_command(
    address: String,
    username: String,
    password: String,
    timeout_ms: u64,
    request: Request,
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
    let _guard = loop {
        if Instant::now() >= deadline {
            return Err("unreachable");
        }
        match SDK.try_lock() {
            Ok(guard) => break guard,
            Err(TryLockError::WouldBlock) => std::thread::sleep(Duration::from_millis(1)),
            Err(TryLockError::Poisoned(_)) => return Err("unreachable"),
        }
    };
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
        )
    };
    match status {
        0 => {
            data.truncate(length as usize);
            Ok((completion, data))
        }
        3 => Err("outcome_unknown"),
        4 => Err("authentication"),
        _ => Err("unreachable"),
    }
}

rustler::init!("Elixir.Opsonde.Transports.IPMI");
