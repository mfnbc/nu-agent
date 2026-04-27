mod commands;
mod state;

use crate::state::RagPlugin;
use nu_plugin::{serve_plugin, MsgPackSerializer};

fn main() {
    serve_plugin(&RagPlugin::new(), MsgPackSerializer)
}
