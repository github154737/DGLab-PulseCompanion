//! Test-only loopback server using upstream Buttplug's real serializer and simulator.
//! The only registered communication manager is SimulatedHardwareCommunicationManager.
//! No BLE, serial, HID, vendor API or physical-device websocket managers are dependencies.
use buttplug_core::message::serializer::{ButtplugMessageSerializer, ButtplugSerializedMessage};
use buttplug_server::{
    ButtplugServerBuilder,
    device::{
        ServerDeviceManagerBuilder,
        hardware::simulated::{SimulatedDeviceEntry, SimulatedHardwareCommunicationManagerBuilder},
    },
    message::serializer::ButtplugServerJSONSerializer,
};
use buttplug_server_device_config::load_protocol_configs;
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use std::io::{self, Write};
use tokio::net::TcpListener;
use tokio_tungstenite::{accept_async, tungstenite::Message};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let config = load_protocol_configs(&None, &None, false)?.finish()?;
    let mut manager = ServerDeviceManagerBuilder::new(config);
    manager.comm_manager(SimulatedHardwareCommunicationManagerBuilder::new(vec![
        SimulatedDeviceEntry {
            identifier: "simulated-1vibe".into(),
            display_name: Some("AI Haptics isolated simulator".into()),
            address: "simulated:aihaptics-only".into(),
        },
    ]));
    manager.emit_output_observations(true);
    let server = ButtplugServerBuilder::new(manager.finish()?).finish()?;
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    println!(
        "{}",
        json!({"ready":true,"port":listener.local_addr()?.port(),"physical_managers":0,"server_crate":"buttplug_server 12.0.1"})
    );
    io::stdout().flush()?;
    let (tcp, _) =
        tokio::time::timeout(std::time::Duration::from_secs(30), listener.accept()).await??;
    let mut socket = accept_async(tcp).await?;
    let serializer = ButtplugServerJSONSerializer::default();
    let events = server.event_stream();
    let observations = server
        .output_observation_stream()
        .expect("observation enabled");
    tokio::pin!(events, observations);
    loop {
        tokio::select! {
            frame = socket.next() => {
                let Some(Ok(frame)) = frame else { break };
                match frame {
                    Message::Text(text) if text.len() <= 16384 => {
                        let messages = serializer.deserialize(&ButtplugSerializedMessage::Text(text.to_string()))?;
                        for request in messages {
                            let response = match server.parse_message(request).await { Ok(m) | Err(m) => m };
                            if let ButtplugSerializedMessage::Text(body) = serializer.serialize(&[response]) {
                                socket.send(Message::Text(body.into())).await?;
                            }
                        }
                    },
                    Message::Ping(p) => socket.send(Message::Pong(p)).await?,
                    Message::Close(_) => break,
                    _ => break,
                }
            },
            event = events.next() => {
                if let Some(event) = event {
                    if let ButtplugSerializedMessage::Text(body) = serializer.serialize(&[event]) {
                        socket.send(Message::Text(body.into())).await?;
                    }
                }
            },
            observation = observations.next() => {
                if let Some(o) = observation {
                    println!("{}",json!({"observation":{"device":o.device_index,"feature":o.feature_index,"kind":o.output_type,"value":o.value}}));
                    io::stdout().flush()?;
                }
            },
            _ = tokio::time::sleep(std::time::Duration::from_secs(45)) => break,
        }
    }
    let _ = server.disconnect().await;
    Ok(())
}
