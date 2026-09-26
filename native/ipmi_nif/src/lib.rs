use std::net::SocketAddr;
use std::time::Duration;

use ipmi::{BlockingClient, Error, PrivilegeLevel};

#[rustler::nif(schedule = "DirtyIo")]
fn send_command(
    address: String,
    username: String,
    password: String,
    timeout_ms: u64,
    netfn: u8,
    command: u8,
    data: Vec<u8>,
) -> Result<(u8, Vec<u8>), &'static str> {
    if timeout_ms < 100 || timeout_ms > 30_000 || netfn > 62 || netfn % 2 != 0 || data.len() > 2048
    {
        return Err("invalid_request");
    }

    let target: SocketAddr = address.parse().map_err(|_| "invalid_request")?;

    let client = BlockingClient::builder(target)
        .username(username)
        .password(password)
        .privilege_level(PrivilegeLevel::Administrator)
        .timeout(Duration::from_millis(timeout_ms))
        // The crate counts the first send as an attempt. Never replay an effect.
        .retries(1)
        .build()
        .map_err(connect_error)?;

    // Once send_raw is entered, even an I/O error may follow a delivered command.
    let result = client
        .send_raw(netfn, command, &data)
        .map(|response| (response.completion_code, response.data))
        .map_err(|_| "outcome_unknown");

    let _ = client.close_session();
    result
}

fn connect_error(error: Error) -> &'static str {
    match error {
        Error::AuthenticationFailed(_) => "authentication",
        Error::Unsupported(_) => "unsupported",
        Error::InvalidArgument(_) => "invalid_request",
        _ => "unreachable",
    }
}

rustler::init!("Elixir.Opsonde.Targets.BMC.IPMINative");
