use std::collections::HashMap;
use std::sync::mpsc;
use std::thread;

use ashpd::desktop::global_shortcuts::{
    BindShortcutsOptions, GlobalShortcuts, ListShortcutsOptions, NewShortcut,
};
use ashpd::desktop::{CreateSessionOptions, Session};
use ashpd::zbus;
use ashpd::zvariant::OwnedValue;
use futures_util::StreamExt;
use tokio::sync::watch;

use crate::UiEvent;
use crate::desktop;
use crate::incident;

const SHORTCUT_ID: &str = "interaction-mode";

pub(crate) struct Controller {
    enabled: watch::Sender<bool>,
}

impl Controller {
    pub(crate) fn set_enabled(&self, enabled: bool) {
        self.enabled.send_replace(enabled);
    }
}

pub(crate) fn spawn(events: mpsc::Sender<UiEvent>) -> Controller {
    let (enabled, receiver) = watch::channel(false);
    thread::Builder::new()
        .name("wfcompanion-shortcut".to_owned())
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build();
            match runtime {
                Ok(runtime) => {
                    if let Err(error) = runtime.block_on(run(receiver, events)) {
                        incident::warn("shortcut.unavailable", error);
                    }
                }
                Err(error) => incident::warn("shortcut.unavailable", error.to_string()),
            }
        })
        .expect("spawn shortcut worker");
    Controller { enabled }
}

async fn run(
    mut enabled: watch::Receiver<bool>,
    events: mpsc::Sender<UiEvent>,
) -> Result<(), String> {
    let desktop_path =
        desktop::ensure_identity().map_err(|error| format!("desktop portal identity: {error}"))?;
    incident::info(
        "shortcut.desktop_identity",
        desktop_path.display().to_string(),
    );
    let connection = zbus::Connection::session()
        .await
        .map_err(|error| format!("session bus: {error}"))?;
    register_host_app(&connection).await;
    let portal = GlobalShortcuts::with_connection(connection)
        .await
        .map_err(|error| format!("global shortcuts portal: {error}"))?;
    let mut activations = Box::pin(
        portal
            .receive_activated()
            .await
            .map_err(|error| format!("shortcut activation stream: {error}"))?,
    );
    let session = open_session(&portal).await?;
    let mut active = *enabled.borrow_and_update();

    loop {
        tokio::select! {
            changed = enabled.changed() => {
                if changed.is_err() {
                    close_session(session).await?;
                    return Ok(());
                }
                active = *enabled.borrow_and_update();
            }
            activation = activations.next() => {
                let Some(activation) = activation else {
                    return Err("global shortcuts portal closed activation stream".to_owned());
                };
                if active && activation.shortcut_id() == SHORTCUT_ID {
                    incident::info("shortcut.trigger", "id=interaction-mode");
                    let _ = events.send(UiEvent::InteractionToggle);
                }
            }
        }
    }
}

async fn register_host_app(connection: &zbus::Connection) {
    let result = async {
        let proxy = zbus::Proxy::new(
            connection,
            "org.freedesktop.portal.Desktop",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.host.portal.Registry",
        )
        .await?;
        let options = HashMap::<String, OwnedValue>::new();
        proxy
            .call::<_, _, ()>("Register", &(desktop::APP_ID, options))
            .await
    }
    .await;
    if let Err(error) = result {
        incident::warn("shortcut.app_registration_failed", error.to_string());
    }
}

async fn open_session(portal: &GlobalShortcuts) -> Result<Session<GlobalShortcuts>, String> {
    let session = portal
        .create_session(CreateSessionOptions::default())
        .await
        .map_err(|error| format!("create session: {error}"))?;
    let result = async {
        let listed = portal
            .list_shortcuts(&session, ListShortcutsOptions::default())
            .await
            .and_then(|request| request.response())
            .map_err(|error| format!("list shortcuts: {error}"))?;
        if listed
            .shortcuts()
            .iter()
            .any(|shortcut| shortcut.id() == SHORTCUT_ID)
        {
            return Ok(());
        }
        let shortcut = NewShortcut::new(SHORTCUT_ID, "Toggle overlay interaction mode")
            .preferred_trigger("CTRL+Tab");
        let bound = portal
            .bind_shortcuts(&session, &[shortcut], None, BindShortcutsOptions::default())
            .await
            .and_then(|request| request.response())
            .map_err(|error| format!("bind Ctrl+Tab: {error}"))?;
        bound
            .shortcuts()
            .iter()
            .any(|shortcut| shortcut.id() == SHORTCUT_ID)
            .then_some(())
            .ok_or_else(|| "Ctrl+Tab was not granted".to_owned())
    }
    .await;
    if let Err(error) = result {
        let _ = session.close().await;
        return Err(error);
    }
    incident::info("shortcut.active", "id=interaction-mode");
    Ok(session)
}

async fn close_session(session: Session<GlobalShortcuts>) -> Result<(), String> {
    session
        .close()
        .await
        .map_err(|error| format!("close shortcut session: {error}"))?;
    incident::info("shortcut.inactive", "id=interaction-mode");
    Ok(())
}
