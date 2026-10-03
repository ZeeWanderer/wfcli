use std::collections::HashMap;
use std::thread;
use std::time::Duration;

use ashpd::desktop::global_shortcuts::{BindShortcutsOptions, GlobalShortcuts, NewShortcut};
use ashpd::desktop::{CreateSessionOptions, Session};
use ashpd::zbus;
use ashpd::zvariant::OwnedValue;
use futures_util::StreamExt;
use tokio::sync::{oneshot, watch};

use crate::UiEvent;
use crate::desktop;
use crate::incident;

const SHORTCUT_ID: &str = "interaction-mode";

#[derive(Clone)]
pub(crate) struct Controller {
    enabled: watch::Sender<bool>,
}

impl Controller {
    pub(crate) fn set_enabled(&self, enabled: bool) {
        self.enabled.send_replace(enabled);
    }
}

pub(crate) struct Service {
    controller: Controller,
    stop: Option<oneshot::Sender<()>>,
    worker: Option<thread::JoinHandle<()>>,
}

impl Service {
    pub(crate) fn controller(&self) -> Controller {
        self.controller.clone()
    }
}

impl Drop for Service {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(worker) = self.worker.take() {
            crate::runtime::join_worker("shortcut", worker);
        }
    }
}

pub(crate) fn spawn(events: crate::runtime::presentation::Sender) -> Result<Service, String> {
    let (enabled, receiver) = watch::channel(false);
    let (stop, stopping) = oneshot::channel();
    let worker = thread::Builder::new()
        .name("wfcompanion-shortcut".to_owned())
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build();
            match runtime {
                Ok(runtime) => {
                    if let Err(error) = runtime.block_on(run(receiver, events, stopping)) {
                        incident::warn("shortcut.unavailable", error);
                    }
                }
                Err(error) => incident::warn("shortcut.unavailable", error.to_string()),
            }
        })
        .map_err(|error| format!("could not start shortcut worker: {error}"))?;
    Ok(Service {
        controller: Controller { enabled },
        stop: Some(stop),
        worker: Some(worker),
    })
}

async fn run(
    enabled: watch::Receiver<bool>,
    events: crate::runtime::presentation::Sender,
    mut stopping: oneshot::Receiver<()>,
) -> Result<(), String> {
    let desktop_path =
        desktop::ensure_identity().map_err(|error| format!("desktop portal identity: {error}"))?;
    incident::info(
        "shortcut.desktop_identity",
        desktop_path.display().to_string(),
    );
    let setup = async {
        let connection = zbus::Connection::session()
            .await
            .map_err(|error| format!("session bus: {error}"))?;
        register_host_app(&connection).await;
        let portal = GlobalShortcuts::with_connection(connection)
            .await
            .map_err(|error| format!("global shortcuts portal: {error}"))?;
        let session = portal
            .create_session(CreateSessionOptions::default())
            .await
            .map_err(|error| format!("create session: {error}"))?;
        Ok::<_, String>((portal, session))
    };
    let (portal, session) = tokio::select! {
        biased;
        _ = &mut stopping => return Ok(()),
        result = setup => result?,
    };
    let result = tokio::select! {
        biased;
        _ = &mut stopping => Ok(()),
        result = listen(&portal, &session, enabled, events) => result,
    };
    let closed = tokio::time::timeout(Duration::from_secs(2), close_session(session))
        .await
        .map_err(|_| "close shortcut session timed out".to_owned())?;
    result.and(closed)
}

async fn listen(
    portal: &GlobalShortcuts,
    session: &Session<GlobalShortcuts>,
    mut enabled: watch::Receiver<bool>,
    events: crate::runtime::presentation::Sender,
) -> Result<(), String> {
    let mut activations = Box::pin(
        portal
            .receive_activated()
            .await
            .map_err(|error| format!("shortcut activation stream: {error}"))?,
    );
    bind_shortcut(portal, session).await?;
    let mut active = *enabled.borrow_and_update();

    loop {
        tokio::select! {
            changed = enabled.changed() => {
                if changed.is_err() {
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

async fn bind_shortcut(
    portal: &GlobalShortcuts,
    session: &Session<GlobalShortcuts>,
) -> Result<(), String> {
    let shortcut = NewShortcut::new(SHORTCUT_ID, "Toggle overlay interaction mode")
        .preferred_trigger("CTRL+Tab");
    let bound = portal
        .bind_shortcuts(session, &[shortcut], None, BindShortcutsOptions::default())
        .await
        .and_then(|request| request.response())
        .map_err(|error| format!("bind Ctrl+Tab: {error}"))?;
    bound
        .shortcuts()
        .iter()
        .any(|shortcut| shortcut.id() == SHORTCUT_ID)
        .then_some(())
        .ok_or_else(|| "Ctrl+Tab was not granted".to_owned())?;
    incident::info("shortcut.active", "id=interaction-mode");
    Ok(())
}

async fn close_session(session: Session<GlobalShortcuts>) -> Result<(), String> {
    session
        .close()
        .await
        .map_err(|error| format!("close shortcut session: {error}"))?;
    incident::info("shortcut.inactive", "id=interaction-mode");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    #[test]
    fn service_shutdown_joins_even_with_live_controllers() {
        let (enabled, receiver) = watch::channel(false);
        let (stop, stopping) = oneshot::channel();
        let (done, result) = mpsc::channel();
        let worker = thread::spawn(move || {
            stopping.blocking_recv().unwrap();
            drop(receiver);
            done.send(()).unwrap();
        });
        let service = Service {
            controller: Controller { enabled },
            stop: Some(stop),
            worker: Some(worker),
        };
        let controller = service.controller();
        controller.set_enabled(true);
        drop(service);
        assert!(result.try_recv().is_ok());
        assert!(controller.enabled.is_closed());
    }
}
