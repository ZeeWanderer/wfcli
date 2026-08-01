#include "daemon_client.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocalSocket>
#include <QProcessEnvironment>
#include <QStandardPaths>
#include <QStringList>
#include <QTimer>

#include <ranges>
#include <utility>

namespace {
constexpr qint64 HelloRequestId = 1;
constexpr int AssetBatchSize = 8;
constexpr int MaxActiveAssetRequests = 2;
constexpr int MarketCacheBatchSize = 100;
constexpr int MaxActiveMarketQuoteRequests = 3;
constexpr int MarketQuoteTtlSeconds = 15 * 60;
} // namespace

DaemonClient::DaemonClient(QObject *parent)
    : QObject(parent), socket_(new QLocalSocket(this)),
      reconnectTimer_(new QTimer(this)) {
  reconnectTimer_->setInterval(1000);
  reconnectTimer_->setSingleShot(true);

  connect(reconnectTimer_, &QTimer::timeout, this,
          &DaemonClient::connectSocket);
  connect(socket_, &QLocalSocket::connected, this, [this] {
    setStatus("Negotiating with wfdaemon");
    sendHello();
  });
  connect(socket_, &QLocalSocket::readyRead, this, [this] {
    input_.append(socket_->readAll());
    for (;;) {
      const qsizetype newline = input_.indexOf('\n');
      if (newline < 0) {
        break;
      }
      const QByteArray line = input_.left(newline).trimmed();
      input_.remove(0, newline + 1);
      if (!line.isEmpty()) {
        handleLine(line);
      }
    }
  });
  connect(socket_, &QLocalSocket::disconnected, this, [this] {
    for (const RelicRequest &request : std::as_const(activeRelicRequests_)) {
      pendingRelicRequests_.insert(relicRequestKey(request), request);
    }
    for (const QJsonArray &assets : std::as_const(activeAssetRequests_)) {
      for (const QJsonValue &asset : assets) {
        const QJsonObject spec = asset.toObject();
        const QString id = spec.value("id").toString();
        if (!id.isEmpty()) {
          pendingAssets_.insert(id, spec);
          pendingAssetOrder_.removeAll(id);
          pendingAssetOrder_.append(id);
        }
      }
    }
    for (const QString &view : std::as_const(activePlayerViews_)) {
      pendingPlayerViews_.insert(view);
    }
    pendingActivity_ = pendingActivity_ || activeActivityRequest_ != 0;
    pendingNotificationSettings_ = true;
    for (const MarketQuoteRequest &request :
         std::as_const(activeMarketQuoteRequests_)) {
      for (const QString &item : request.items) {
        if (request.cacheOnly) {
          marketCacheRequested_.remove(item);
          pendingMarketCacheQuotes_.insert(item);
          pendingMarketCacheQuoteOrder_.removeAll(item);
          pendingMarketCacheQuoteOrder_.append(item);
        } else {
          pendingMarketQuotes_.insert(item, pendingMarketQuotes_.value(item) ||
                                                request.refresh);
          pendingMarketQuoteOrder_.removeAll(item);
          pendingMarketQuoteOrder_.append(item);
        }
      }
    }
    activeRelicRequests_.clear();
    activePlayerViews_.clear();
    activeActivityRequest_ = 0;
    activeNotificationSettingsRequest_ = 0;
    activeNotificationRequestIsSet_ = false;
    sentNotificationMode_.reset();
    activeAssetRequests_.clear();
    activeMarketQuoteRequests_.clear();
    ready_ = false;
    setConnected(false);
    setStatus("wfdaemon disconnected");
    if (!reconnectTimer_->isActive()) {
      reconnectTimer_->start();
    }
  });
  connect(socket_, &QLocalSocket::errorOccurred, this,
          [this](QLocalSocket::LocalSocketError error) {
            if (error == QLocalSocket::ServerNotFoundError ||
                error == QLocalSocket::ConnectionRefusedError) {
              ensureDaemon();
            } else {
              setStatus(socket_->errorString());
            }
            if (!reconnectTimer_->isActive()) {
              reconnectTimer_->start();
            }
          });

  connect(&ensureProcess_,
          qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this,
          [this](int exitCode, QProcess::ExitStatus exitStatus) {
            if (exitStatus != QProcess::NormalExit || exitCode != 0) {
              setStatus(updatingDaemon_ ? "Could not update wfdaemon"
                                        : "Could not start wfdaemon");
            }
            if (!reconnectTimer_->isActive()) {
              reconnectTimer_->start(250);
            }
          });
}

bool DaemonClient::connected() const { return connected_; }

QString DaemonClient::status() const { return status_; }

void DaemonClient::start() { connectSocket(); }

void DaemonClient::requestRelics(const QString &era, bool fetchPrices) {
  const RelicRequest request{.era = era, .prices = fetchPrices};
  const QString key = relicRequestKey(request);
  if (!relicRequestActive(key)) {
    pendingRelicRequests_.insert(key, request);
  }
  sendPendingRequests();
}

void DaemonClient::requestPlayerView(const QString &view) {
  if (!activePlayerViews_.values().contains(view)) {
    pendingPlayerViews_.insert(view);
  }
  sendPendingPlayerViews();
}

void DaemonClient::requestActivity() {
  if (activeActivityRequest_ == 0) {
    pendingActivity_ = true;
  }
  sendPendingActivity();
}

void DaemonClient::requestNotificationSettings() {
  pendingNotificationSettings_ = true;
  sendPendingNotificationSettings();
}

void DaemonClient::setFissureNotificationMode(const QString &mode) {
  if (mode != "off" && mode != "session" && mode != "persistent") {
    return;
  }
  desiredNotificationMode_ = mode;
  sendPendingNotificationSettings();
}

void DaemonClient::requestAssets(const QJsonArray &assets) {
  QStringList requested;
  for (const QJsonValue &asset : assets) {
    const QJsonObject spec = asset.toObject();
    const QString id = spec.value("id").toString();
    if (!id.isEmpty() && !assetRequestActive(id)) {
      pendingAssets_.insert(id, spec);
      pendingAssetOrder_.removeAll(id);
      requested.append(id);
    }
  }
  for (auto id = requested.crbegin(); id != requested.crend(); ++id) {
    pendingAssetOrder_.prepend(*id);
  }
  sendPendingAssets();
}

void DaemonClient::requestMarketQuotes(const QStringList &items, bool refresh) {
  QStringList cacheRequested;
  QStringList requested;
  for (const QString &item : items) {
    if (item.isEmpty()) {
      continue;
    }
    if (!refresh && !marketCacheRequested_.contains(item)) {
      marketCacheRequested_.insert(item);
      pendingMarketCacheQuotes_.insert(item);
      pendingMarketCacheQuoteOrder_.removeAll(item);
      cacheRequested.append(item);
    }
    if (marketQuoteActive(item, false) && !refresh) {
      continue;
    }
    pendingMarketQuotes_.insert(item,
                                pendingMarketQuotes_.value(item) || refresh);
    pendingMarketQuoteOrder_.removeAll(item);
    requested.append(item);
  }
  for (auto item = requested.crbegin(); item != requested.crend(); ++item) {
    pendingMarketQuoteOrder_.prepend(*item);
  }
  for (auto item = cacheRequested.crbegin(); item != cacheRequested.crend();
       ++item) {
    pendingMarketCacheQuoteOrder_.prepend(*item);
  }
  sendPendingMarketQuotes();
}

void DaemonClient::connectSocket() {
  if (socket_->state() != QLocalSocket::UnconnectedState) {
    return;
  }
  input_.clear();
  setStatus("Connecting to wfdaemon");
  socket_->connectToServer(socketPath());
}

void DaemonClient::ensureDaemon(bool update) {
  bool &attempted = update ? updateAttempted_ : ensureAttempted_;
  if (attempted || ensureProcess_.state() != QProcess::NotRunning) {
    return;
  }
  attempted = true;
  updatingDaemon_ = update;
  const QString command = wfcliCommand();
  if (command.isEmpty()) {
    setStatus("wfcli executable not found");
    return;
  }

  QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
  for (const QString &name :
       QStringList{"LD_PRELOAD", "LD_LIBRARY_PATH", "STEAM_RUNTIME",
                   "STEAM_RUNTIME_LIBRARY_PATH"}) {
    environment.remove(name);
  }
  ensureProcess_.setProcessEnvironment(environment);
  ensureProcess_.setProgram(command);
  ensureProcess_.setArguments(
      {"daemon", update ? QStringLiteral("update") : QStringLiteral("ensure")});
  ensureProcess_.setStandardOutputFile(QProcess::nullDevice());
  ensureProcess_.setStandardErrorFile(QProcess::nullDevice());
  ensureProcess_.start();
}

void DaemonClient::handleLine(const QByteArray &line) {
  QJsonParseError parseError;
  const QJsonDocument document = QJsonDocument::fromJson(line, &parseError);
  if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
    setStatus("wfdaemon returned invalid JSON");
    return;
  }

  const QJsonObject message = document.object();
  const qint64 id = message.value("id").toInteger();
  if (id == HelloRequestId) {
    if (!message.value("ok").toBool() ||
        !message.value("compatible").toBool()) {
      const int daemonProtocol = message.value("protocol").toInt(-1);
      setStatus(QString("Protocol mismatch: GUI %1, daemon %2")
                    .arg(WFCLI_LOCAL_PROTOCOL)
                    .arg(daemonProtocol));
      ensureDaemon(true);
      socket_->abort();
      return;
    }
    const QJsonArray capabilities = message.value("capabilities").toArray();
    const QStringList requiredCapabilities = {
        "relic.planner",         "worldstate.activity", "player.foundry",
        "player.inventory",      "player.mastery",      "market.quote",
        "notifications.fissures"};
    const bool capable = std::ranges::all_of(
        requiredCapabilities, [&capabilities](const QString &capability) {
          return capabilities.contains(QJsonValue(capability));
        });
    if (!capable) {
      setStatus("wfdaemon lacks GUI support");
      ensureDaemon(true);
      socket_->abort();
      return;
    }
    ready_ = true;
    ensureAttempted_ = false;
    updateAttempted_ = false;
    setConnected(true);
    setStatus("Connected to wfdaemon");
    sendPendingRequests();
    sendPendingPlayerViews();
    sendPendingActivity();
    sendPendingNotificationSettings();
    sendPendingAssets();
    sendPendingMarketQuotes();
    return;
  }

  const auto active = activeRelicRequests_.find(id);
  if (active != activeRelicRequests_.end()) {
    const RelicRequest request = active.value();
    activeRelicRequests_.erase(active);
    if (!message.value("ok").toBool()) {
      const QString error =
          message.value("error").toString("daemon request failed");
      emit requestFailed(request.era, request.prices, error);
      return;
    }
    const QJsonValue data = message.value("data");
    if (!data.isObject()) {
      emit requestFailed(request.era, request.prices,
                         "daemon returned malformed relic planner data");
      return;
    }
    emit relicPlannerReady(request.era, request.prices, data.toObject());
    return;
  }

  const auto assetRequest = activeAssetRequests_.find(id);
  if (assetRequest != activeAssetRequests_.end()) {
    activeAssetRequests_.erase(assetRequest);
    if (!message.value("ok").toBool()) {
      emit assetRequestFailed(
          message.value("error").toString("asset request failed"));
      sendPendingAssets();
      return;
    }
    const QJsonArray assets =
        message.value("data").toObject().value("assets").toArray();
    emit assetsResolved(assets);
    sendPendingAssets();
    return;
  }

  if (id == activeActivityRequest_) {
    activeActivityRequest_ = 0;
    if (!message.value("ok").toBool()) {
      emit activityFailed(
          message.value("error").toString("activity request failed"));
      return;
    }
    const QJsonValue data = message.value("data");
    if (!data.isObject()) {
      emit activityFailed("daemon returned malformed activity data");
      return;
    }
    emit activityReady(data.toObject());
    return;
  }

  if (id == activeNotificationSettingsRequest_) {
    activeNotificationSettingsRequest_ = 0;
    const bool wasSet = activeNotificationRequestIsSet_;
    activeNotificationRequestIsSet_ = false;
    const std::optional<QString> sentMode = sentNotificationMode_;
    sentNotificationMode_.reset();
    if (!message.value("ok").toBool()) {
      desiredNotificationMode_.reset();
      emit notificationSettingsFailed(message.value("error").toString(
          "notification settings request failed"));
      return;
    }
    const QJsonValue data = message.value("data");
    if (!data.isObject()) {
      desiredNotificationMode_.reset();
      emit notificationSettingsFailed(
          "daemon returned malformed notification settings");
      return;
    }
    pendingNotificationSettings_ = false;
    const bool superseded =
        wasSet && sentMode.has_value() &&
        desiredNotificationMode_.has_value() &&
        desiredNotificationMode_.value() != sentMode.value();
    if (wasSet && !superseded) {
      desiredNotificationMode_.reset();
    }
    if (!superseded) {
      emit notificationSettingsReady(data.toObject());
    }
    sendPendingNotificationSettings();
    return;
  }

  const auto marketRequest = activeMarketQuoteRequests_.find(id);
  if (marketRequest != activeMarketQuoteRequests_.end()) {
    const QStringList items = marketRequest->items;
    const bool cacheOnly = marketRequest->cacheOnly;
    activeMarketQuoteRequests_.erase(marketRequest);
    if (!message.value("ok").toBool()) {
      if (!cacheOnly) {
        emit marketQuoteRequestFailed(
            items,
            message.value("error").toString("market quote request failed"));
      }
      sendPendingMarketQuotes();
      flushMarketQuoteResults();
      return;
    }
    const QJsonValue dataValue = message.value("data");
    const QJsonObject data = dataValue.toObject();
    if (!dataValue.isObject() || !data.value("quotes").isArray() ||
        !data.value("missing").isArray()) {
      if (!cacheOnly) {
        emit marketQuoteRequestFailed(
            items, "daemon returned malformed market quotes");
      }
      sendPendingMarketQuotes();
      flushMarketQuoteResults();
      return;
    }
    const QJsonArray quotes = data.value("quotes").toArray();
    if (cacheOnly) {
      if (!quotes.isEmpty()) {
        emit marketQuotesResolved(quotes, {});
      }
    } else {
      for (const QJsonValue &quote : quotes) {
        resolvedMarketQuotes_.append(quote);
      }
      for (const QJsonValue &missing : data.value("missing").toArray()) {
        resolvedMarketMissing_.append(missing);
      }
    }
    sendPendingMarketQuotes();
    flushMarketQuoteResults();
    return;
  }

  const auto playerRequest = activePlayerViews_.find(id);
  if (playerRequest == activePlayerViews_.end()) {
    return;
  }
  const QString view = playerRequest.value();
  activePlayerViews_.erase(playerRequest);
  if (!message.value("ok").toBool()) {
    emit playerViewFailed(
        view, message.value("error").toString("player view request failed"));
    return;
  }
  const QJsonValue data = message.value("data");
  if (!data.isObject()) {
    emit playerViewFailed(view, "daemon returned malformed player view data");
    return;
  }
  emit playerViewReady(view, data.toObject());
}

void DaemonClient::sendHello() {
  write({
      {"op", "hello"},
      {"id", HelloRequestId},
      {"protocol", WFCLI_LOCAL_PROTOCOL},
      {"client", "wfgui"},
      {"version", WFCLI_VERSION},
      {"pid", QCoreApplication::applicationPid()},
      {"mode", "desktop"},
      {"capabilities", QJsonArray{"relic.planner", "worldstate.activity",
                                  "player.foundry", "player.inventory",
                                  "player.mastery", "notifications.fissures"}},
  });
}

void DaemonClient::sendPendingPlayerViews() {
  if (!ready_ || pendingPlayerViews_.isEmpty()) {
    return;
  }
  const QSet<QString> pending = pendingPlayerViews_;
  pendingPlayerViews_.clear();
  for (const QString &view : pending) {
    const qint64 id = nextRequestId_++;
    activePlayerViews_.insert(id, view);
    QString operation = "mastery_view";
    if (view == "foundry") {
      operation = "foundry_view";
    } else if (view == "inventory") {
      operation = "inventory_view";
    }
    write({{"op", operation}, {"id", id}});
  }
}

void DaemonClient::sendPendingActivity() {
  if (!ready_ || !pendingActivity_ || activeActivityRequest_ != 0) {
    return;
  }
  pendingActivity_ = false;
  activeActivityRequest_ = nextRequestId_++;
  write({{"op", "activity_view"}, {"id", activeActivityRequest_}});
}

void DaemonClient::sendPendingNotificationSettings() {
  if (!ready_ || activeNotificationSettingsRequest_ != 0) {
    return;
  }
  if (desiredNotificationMode_.has_value()) {
    activeNotificationSettingsRequest_ = nextRequestId_++;
    activeNotificationRequestIsSet_ = true;
    sentNotificationMode_ = desiredNotificationMode_;
    write({{"op", "notification_settings_set"},
           {"id", activeNotificationSettingsRequest_},
           {"fissures", QJsonObject{{"mode", sentNotificationMode_.value()}}}});
    return;
  }
  if (pendingNotificationSettings_) {
    activeNotificationSettingsRequest_ = nextRequestId_++;
    activeNotificationRequestIsSet_ = false;
    write({{"op", "notification_settings"},
           {"id", activeNotificationSettingsRequest_}});
  }
}

void DaemonClient::sendPendingRequests() {
  if (!ready_ || pendingRelicRequests_.isEmpty()) {
    return;
  }
  const QHash<QString, RelicRequest> pending = pendingRelicRequests_;
  pendingRelicRequests_.clear();
  for (const RelicRequest &request : pending) {
    const qint64 id = nextRequestId_++;
    activeRelicRequests_.insert(id, request);
    write({
        {"op", "relic_planner"},
        {"id", id},
        {"era", request.era},
        {"only_owned", false},
        {"fetch_prices", request.prices},
        {"limit", "all"},
    });
  }
}

void DaemonClient::sendPendingAssets() {
  if (!ready_) {
    return;
  }
  while (activeAssetRequests_.size() < MaxActiveAssetRequests &&
         !pendingAssetOrder_.isEmpty()) {
    QJsonArray batch;
    while (batch.size() < AssetBatchSize && !pendingAssetOrder_.isEmpty()) {
      const QString id = pendingAssetOrder_.takeFirst();
      const auto asset = pendingAssets_.find(id);
      if (asset == pendingAssets_.end() || assetRequestActive(id)) {
        continue;
      }
      batch.append(asset.value());
      pendingAssets_.erase(asset);
    }
    if (!batch.isEmpty()) {
      sendAssetBatch(batch);
    }
  }
}

void DaemonClient::sendPendingMarketQuotes() {
  if (!ready_) {
    return;
  }

  while (!pendingMarketCacheQuoteOrder_.isEmpty()) {
    QStringList items;
    while (items.size() < MarketCacheBatchSize &&
           !pendingMarketCacheQuoteOrder_.isEmpty()) {
      const QString item = pendingMarketCacheQuoteOrder_.takeFirst();
      if (!pendingMarketCacheQuotes_.remove(item) ||
          marketQuoteActive(item, true)) {
        continue;
      }
      items.append(item);
    }
    if (items.isEmpty()) {
      continue;
    }
    const qint64 id = nextRequestId_++;
    activeMarketQuoteRequests_.insert(
        id, {.items = items, .refresh = false, .cacheOnly = true});
    write({{"op", "market_quote"},
           {"id", id},
           {"items", QJsonArray::fromStringList(items)},
           {"ttl", MarketQuoteTtlSeconds},
           {"cache_only", true}});
  }

  int activeFetches = 0;
  for (const MarketQuoteRequest &request : activeMarketQuoteRequests_) {
    activeFetches += request.cacheOnly ? 0 : 1;
  }
  int remaining = pendingMarketQuoteOrder_.size();
  while (activeFetches < MaxActiveMarketQuoteRequests && remaining-- > 0 &&
         !pendingMarketQuoteOrder_.isEmpty()) {
    const QString item = pendingMarketQuoteOrder_.takeFirst();
    const auto pending = pendingMarketQuotes_.find(item);
    if (pending == pendingMarketQuotes_.end()) {
      continue;
    }
    if (marketQuoteActive(item, false)) {
      pendingMarketQuoteOrder_.append(item);
      continue;
    }
    const bool refresh = pending.value();
    pendingMarketQuotes_.erase(pending);
    const qint64 id = nextRequestId_++;
    activeMarketQuoteRequests_.insert(
        id, {.items = {item}, .refresh = refresh, .cacheOnly = false});
    write({{"op", "market_quote"},
           {"id", id},
           {"items", QJsonArray{item}},
           {"ttl", MarketQuoteTtlSeconds},
           {"refresh", refresh}});
    ++activeFetches;
  }
}

void DaemonClient::flushMarketQuoteResults() {
  if (!pendingMarketQuotes_.isEmpty()) {
    return;
  }
  for (const MarketQuoteRequest &request : activeMarketQuoteRequests_) {
    if (!request.cacheOnly) {
      return;
    }
  }
  if (!resolvedMarketQuotes_.isEmpty() || !resolvedMarketMissing_.isEmpty()) {
    emit marketQuotesResolved(resolvedMarketQuotes_, resolvedMarketMissing_);
    resolvedMarketQuotes_ = {};
    resolvedMarketMissing_ = {};
  }
}

void DaemonClient::sendAssetBatch(const QJsonArray &assets) {
  const qint64 id = nextRequestId_++;
  activeAssetRequests_.insert(id, assets);
  write({{"op", "asset_resolve"}, {"id", id}, {"assets", assets}});
}

void DaemonClient::write(const QJsonObject &message) {
  QByteArray encoded = QJsonDocument(message).toJson(QJsonDocument::Compact);
  encoded.append('\n');
  socket_->write(encoded);
  socket_->flush();
}

void DaemonClient::setConnected(bool connected) {
  if (connected_ == connected) {
    return;
  }
  connected_ = connected;
  emit connectionChanged();
}

void DaemonClient::setStatus(const QString &status) {
  if (status_ == status) {
    return;
  }
  status_ = status;
  emit statusChanged();
}

QString DaemonClient::socketPath() const {
  const QString configured = qEnvironmentVariable("WFCLI_DAEMON_SOCKET");
  if (!configured.isEmpty()) {
    return configured;
  }
  const QString runtime =
      QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
  if (!runtime.isEmpty()) {
    return QDir(runtime).filePath("wfcli/wfdaemon.sock");
  }
  return QDir(QStandardPaths::writableLocation(
                  QStandardPaths::GenericCacheLocation))
      .filePath("wfcli/wfdaemon.sock");
}

QString DaemonClient::wfcliCommand() const {
  const QString configured = qEnvironmentVariable("WFCLI_COMMAND");
  if (!configured.isEmpty()) {
    return configured;
  }

  QDir directory(QCoreApplication::applicationDirPath());
  for (;;) {
    const QFileInfo candidate(directory.filePath("wfcli"));
    if (candidate.isFile() && candidate.isExecutable()) {
      return candidate.absoluteFilePath();
    }
    if (!directory.cdUp()) {
      break;
    }
  }
  return QStandardPaths::findExecutable("wfcli");
}

QString DaemonClient::relicRequestKey(const RelicRequest &request) {
  return request.era + (request.prices ? QStringLiteral(":prices")
                                       : QStringLiteral(":metadata"));
}

bool DaemonClient::relicRequestActive(const QString &key) const {
  for (const RelicRequest &request : activeRelicRequests_) {
    if (relicRequestKey(request) == key) {
      return true;
    }
  }
  return false;
}

bool DaemonClient::assetRequestActive(const QString &id) const {
  for (const QJsonArray &assets : activeAssetRequests_) {
    for (const QJsonValue &asset : assets) {
      if (asset.toObject().value("id").toString() == id) {
        return true;
      }
    }
  }
  return false;
}

bool DaemonClient::marketQuoteActive(const QString &item,
                                     bool cacheOnly) const {
  for (const MarketQuoteRequest &request : activeMarketQuoteRequests_) {
    if (request.cacheOnly == cacheOnly && request.items.contains(item)) {
      return true;
    }
  }
  return false;
}
