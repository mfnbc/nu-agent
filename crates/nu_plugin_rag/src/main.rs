mod commands;
mod state;

use crate::state::RagPlugin;
use nu_plugin::{serve_plugin, MsgPackSerializer};
use std::ffi::OsStr;

fn main() {
    // Detect plugin invocation robustly. The Nushell plugin loader will pass
    // --stdio for stdio mode, or --local-socket <path> for local-socket mode.
    // Only enter the RPC serve loop when one of these flags is present. This
    // avoids other argument parsing libraries accidentally rejecting plugin
    // loader flags and gives a clear failure mode for non-plugin invocation.
    let args = std::env::args_os();

    let mut is_stdio = false;
    let mut is_local_socket = false;

    for a in args {
        if a == OsStr::new("--stdio") {
            is_stdio = true;
            break;
        }
        if a == OsStr::new("--local-socket") {
            is_local_socket = true;
            break;
        }
    }

    if is_stdio {
        let state = RagPlugin::new();
        // Use MessagePack IPC with the Nushell host
        serve_plugin(&state, MsgPackSerializer)
    } else if is_local_socket {
        // Local socket mode is optional; print a helpful message and exit so
        // the plugin loader can see we're intentionally not supporting it.
        eprintln!("nu_plugin_rag: local-socket mode not supported in this build");
        std::process::exit(1);
    } else {
        eprintln!("nu_plugin_rag: run as a Nushell plugin via 'plugin add' or pass --stdio to start RPC loop");
    }
}
