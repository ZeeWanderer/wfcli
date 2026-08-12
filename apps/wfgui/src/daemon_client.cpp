#include "daemon_client.h"
#include "wfgui_paths.h"

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

#include <algorithm>
#include <ranges>
#include <utility>

namespace {
constexpr qint64 HelloRequestId = 1;
constexpr qint64 PlayerSubscriptionId = 2;
constexpr int AssetBatchSize = 8;
constexpr int MaxActiveAssetRequests = 2;
constexpr int MarketCacheBatchSize = 100;
constexpr int MarketDescriptionBatchSize = 100;
constexpr int MaxActiveMarketDescriptionRequests = 2;
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
    if (activeAssetCacheRequest_ != 0) {
      if (activeAssetCacheClear_) {
        emit assetCacheRequestFailed(
            "wfdaemon disconnected; cache clear result is unknown");
      }
      pendingAssetCacheStatus_ = true;
    }
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
    for (const MarketVariantRequest &request :
         std::as_const(activeMarketVariantRequests_)) {
      pendingMarketVariantRequests_.prepend(request);
    }
    if (!pendingMarketResolve_.has_value() &&
        !activeMarketResolveRequests_.isEmpty()) {
      pendingMarketResolve_ = activeMarketResolveRequests_.constBegin().value();
    }
    for (const QStringList &items :
         std::as_const(activeMarketDescriptionRequests_)) {
      for (const QString &item : items) {
        pendingMarketDescriptions_.insert(item);
        pendingMarketDescriptionOrder_.removeAll(item);
        pendingMarketDescriptionOrder_.append(item);
      }
    }
    for (const QString &action : std::as_const(activeMarketAccountRequests_)) {
      if (action == "snapshot") {
        pendingMarketAccountSnapshot_ = true;
      } else if (action == "presence") {
        emit marketPresenceFailed(
            "wfdaemon disconnected; presence update result is unknown");
      } else {
        emit marketAccountFailed(
            action, "wfdaemon disconnected; operation result is unknown");
        pendingMarketAccountSnapshot_ = true;
      }
    }
    activeRelicRequests_.clear();
    activePlayerViews_.clear();
    activeActivityRequest_ = 0;
    activeNotificationSettingsRequest_ = 0;
    activeNotificationRequestIsSet_ = false;
    sentNotificationMode_.reset();
    activeAssetRequests_.clear();
    activeAssetCacheRequest_ = 0;
    activeAssetCacheClear_ = false;
    activeMarketQuoteRequests_.clear();
    activeMarketVariantRequests_.clear();
    activeMarketResolveRequests_.clear();
    activeMarketDescriptionRequests_.clear();
    activeMarketAccountRequests_.clear();
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
            const bool succeeded =
                exitStatus == QProcess::NormalExit && exitCode == 0;
            if (!succeeded) {
              if (stoppingDaemon_) {
                setStatus("Could not restart wfdaemon");
              } else if (updatingDaemon_) {
                setStatus("Could not update wfdaemon");
              } else {
                setStatus("Could not start wfdaemon");
              }
            }
            if (stoppingDaemon_ && succeeded) {
              stoppingDaemon_ = false;
              ensureAttempted_ = false;
              ensureDaemon();
              return;
            }
            stoppingDaemon_ = false;
            if (!reconnectTimer_->isActive()) {
              reconnectTimer_->start(250);
            }
          });
}

bool DaemonClient::connected() const { return connected_; }

QString DaemonClient::status() const { return status_; }

bool DaemonClient::marketQuoteFetchBusy() const {
  return marketQuotePhaseBusy(false);
}

void DaemonClient::start() { connectSocket(); }

void DaemonClient::requestRelics(const QString &era, bool fetchPrices) {
  const RelicRequest request{.era = era, .prices = fetchPrices};
  const QString key = relicRequestKey(request);
  pendingRelicRequests_.insert(key, request);
  sendPendingRequests();
}

void DaemonClient::requestPlayerView(const QString &view) {
  pendingPlayerViews_.insert(view);
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

void DaemonClient::requestAssetCacheStatus() {
  pendingAssetCacheStatus_ = true;
  sendPendingAssetCacheRequest();
}

void DaemonClient::clearAssetCache() {
  pendingAssetCacheClear_ = true;
  sendPendingAssetCacheRequest();
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

void DaemonClient::requestMarketVariantQuote(const QString &item,
                                             const QJsonObject &filters,
                                             bool refresh) {
  if (item.isEmpty() || filters.isEmpty()) {
    return;
  }
  pendingMarketVariantRequests_.append(
      {.item = item, .filters = filters, .refresh = refresh});
  sendPendingMarketVariantQuotes();
}

void DaemonClient::requestMarketMatches(const QString &query, int limit) {
  const QString normalized = query.trimmed();
  if (normalized.isEmpty()) {
    return;
  }
  pendingMarketResolve_ =
      MarketResolveRequest{.query = normalized, .limit = qBound(1, limit, 5)};
  sendPendingMarketResolve();
}

void DaemonClient::requestMarketItems(const QStringList &items) {
  for (const QString &item : items) {
    if (item.isEmpty() || pendingMarketDescriptions_.contains(item)) {
      continue;
    }
    bool active = false;
    for (const QStringList &request : activeMarketDescriptionRequests_) {
      if (request.contains(item)) {
        active = true;
        break;
      }
    }
    if (!active) {
      pendingMarketDescriptions_.insert(item);
      pendingMarketDescriptionOrder_.append(item);
    }
  }
  sendPendingMarketDescriptions();
}

void DaemonClient::requestMarketAccount() {
  pendingMarketAccountSnapshot_ = true;
  sendPendingMarketAccount();
}

void DaemonClient::marketLogin(const QString &email, const QString &password) {
  queueMarketAccountRequest(
      "login",
      {{"op", "market_login"}, {"email", email}, {"password", password}});
}

void DaemonClient::marketLogout() {
  queueMarketAccountRequest("logout", {{"op", "market_logout"}});
}

void DaemonClient::marketCreateOrder(const QJsonObject &order) {
  queueMarketAccountRequest("create",
                            {{"op", "market_order_create"}, {"order", order}});
}

void DaemonClient::marketUpdateOrder(const QString &id,
                                     const QJsonObject &patch) {
  queueMarketAccountRequest(
      "update",
      {{"op", "market_order_update"}, {"order_id", id}, {"patch", patch}});
}

void DaemonClient::marketDeleteOrder(const QString &id) {
  queueMarketAccountRequest("delete",
                            {{"op", "market_order_delete"}, {"order_id", id}});
}

void DaemonClient::marketCloseOrder(const QString &id, int quantity) {
  queueMarketAccountRequest(
      "close",
      {{"op", "market_order_close"}, {"order_id", id}, {"quantity", quantity}});
}

void DaemonClient::setMarketOrdersVisible(bool visible, const QString &type) {
  QJsonObject message{{"op", "market_orders_visibility"}, {"visible", visible}};
  if (type == "buy" || type == "sell") {
    message.insert("type", type);
  }
  queueMarketAccountRequest("visibility", message);
}

void DaemonClient::setMarketPresenceMode(const QString &mode) {
  queueMarketAccountRequest("presence",
                            {{"op", "market_presence_set"}, {"mode", mode}});
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
  if (ensureProcess_.state() != QProcess::NotRunning) {
    return;
  }
  QString action;
  if (!update) {
    if (ensureAttempted_) {
      return;
    }
    ensureAttempted_ = true;
    action = "ensure";
  } else if (!updateAttempted_) {
    updateAttempted_ = true;
    action = "update";
  } else if (!stopAttempted_) {
    stopAttempted_ = true;
    action = "stop";
  } else {
    return;
  }
  updatingDaemon_ = action == "update";
  stoppingDaemon_ = action == "stop";
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
  ensureProcess_.setArguments({"daemon", action});
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
  if (message.value("event").toString() == "dataset" &&
      message.value("subscription").toInteger() == PlayerSubscriptionId &&
      message.value("dataset").toString() == "player" &&
      message.value("data").isObject()) {
    handlePlayerSnapshot(message.value("data").toObject(),
                         message.value("source").toString());
    return;
  }
  if (message.value("event").toString() == "market_presence" &&
      message.value("data").isObject()) {
    emit marketPresenceReady(message.value("data").toObject(), false);
    return;
  }
  if (message.value("event").toString() == "asset" &&
      message.value("data").isObject()) {
    emit assetRefreshed(message.value("data").toObject());
    return;
  }
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
        "relic.planner",          "worldstate.activity",
        "player.foundry",         "player.inventory",
        "player.mastery",         "market.quote",
        "market.resolve",         "market.describe",
        "market.account",         "market.orders",
        "market.quote.variant",   "market.presence",
        "notifications.fissures", "asset.cache",
        "dataset.subscribe",      "dataset.subscribe.metadata"};
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
    stopAttempted_ = false;
    setConnected(true);
    setStatus("Connected to wfdaemon");
    sendPlayerSubscription();
    sendPendingRequests();
    sendPendingPlayerViews();
    sendPendingActivity();
    sendPendingNotificationSettings();
    sendPendingAssets();
    sendPendingAssetCacheRequest();
    sendPendingMarketQuotes();
    sendPendingMarketVariantQuotes();
    sendPendingMarketResolve();
    sendPendingMarketDescriptions();
    sendPendingMarketAccount();
    return;
  }

  if (id == PlayerSubscriptionId) {
    if (!message.value("ok").toBool() || !message.value("data").isObject()) {
      setStatus(message.value("error").toString(
          "wfdaemon player subscription failed"));
      return;
    }
    handlePlayerSnapshot(message.value("data").toObject(), QString());
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
      sendPendingRequests();
      return;
    }
    const QJsonValue data = message.value("data");
    if (!data.isObject()) {
      emit requestFailed(request.era, request.prices,
                         "daemon returned malformed relic planner data");
      sendPendingRequests();
      return;
    }
    emit relicPlannerReady(request.era, request.prices, data.toObject());
    sendPendingRequests();
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

  if (id == activeAssetCacheRequest_) {
    activeAssetCacheRequest_ = 0;
    activeAssetCacheClear_ = false;
    if (message.value("ok").toBool() && message.value("data").isObject()) {
      emit assetCacheStatusReady(message.value("data").toObject());
    } else {
      emit assetCacheRequestFailed(
          message.value("error").toString("asset cache request failed"));
    }
    sendPendingAssetCacheRequest();
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
    const auto settle = [this, cacheOnly] {
      sendPendingMarketQuotes();
      if (!marketQuotePhaseBusy(cacheOnly)) {
        if (cacheOnly) {
          emit marketQuoteCacheSettled();
        } else {
          emit marketQuoteFetchSettled();
        }
      }
    };
    if (!message.value("ok").toBool()) {
      if (!cacheOnly) {
        emit marketQuoteRequestFailed(
            items,
            message.value("error").toString("market quote request failed"));
      }
      settle();
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
      settle();
      return;
    }
    const QJsonArray quotes = data.value("quotes").toArray();
    const QJsonArray missing = data.value("missing").toArray();
    if (!quotes.isEmpty() || (!cacheOnly && !missing.isEmpty())) {
      emit marketQuotesResolved(quotes, cacheOnly ? QJsonArray{} : missing);
    }
    settle();
    return;
  }

  const auto variantRequest = activeMarketVariantRequests_.find(id);
  if (variantRequest != activeMarketVariantRequests_.end()) {
    const MarketVariantRequest request = variantRequest.value();
    activeMarketVariantRequests_.erase(variantRequest);
    if (!message.value("ok").toBool()) {
      emit marketVariantQuoteFailed(request.item, request.filters,
                                    message.value("error").toString(
                                        "market variant quote request failed"));
    } else if (!message.value("data").isObject()) {
      emit marketVariantQuoteFailed(request.item, request.filters,
                                    "daemon returned malformed variant quote");
    } else {
      emit marketVariantQuoteReady(request.item, request.filters,
                                   message.value("data").toObject());
    }
    sendPendingMarketVariantQuotes();
    return;
  }

  const auto resolveRequest = activeMarketResolveRequests_.find(id);
  if (resolveRequest != activeMarketResolveRequests_.end()) {
    const MarketResolveRequest request = resolveRequest.value();
    activeMarketResolveRequests_.erase(resolveRequest);
    if (!message.value("ok").toBool()) {
      emit marketMatchesFailed(
          request.query,
          message.value("error").toString("market search request failed"));
      return;
    }
    const QJsonObject data = message.value("data").toObject();
    const QJsonArray resolutions = data.value("resolutions").toArray();
    if (!message.value("data").isObject() || resolutions.isEmpty() ||
        !resolutions.first().isObject() ||
        !resolutions.first().toObject().value("matches").isArray()) {
      emit marketMatchesFailed(request.query,
                               "daemon returned malformed market search data");
      return;
    }
    emit marketMatchesResolved(
        request.query,
        resolutions.first().toObject().value("matches").toArray());
    return;
  }

  const auto describeRequest = activeMarketDescriptionRequests_.find(id);
  if (describeRequest != activeMarketDescriptionRequests_.end()) {
    const QStringList items = describeRequest.value();
    activeMarketDescriptionRequests_.erase(describeRequest);
    if (!message.value("ok").toBool()) {
      emit marketItemDescribeFailed(
          items, message.value("error").toString("market item request failed"));
      sendPendingMarketDescriptions();
      return;
    }
    const QJsonValue dataValue = message.value("data");
    const QJsonObject data = dataValue.toObject();
    if (!dataValue.isObject() || !data.value("items").isArray() ||
        !data.value("missing").isArray()) {
      emit marketItemDescribeFailed(
          items, "daemon returned malformed market item data");
      sendPendingMarketDescriptions();
      return;
    }
    emit marketItemsDescribed(data.value("items").toArray(),
                              data.value("missing").toArray());
    sendPendingMarketDescriptions();
    return;
  }

  const auto accountRequest = activeMarketAccountRequests_.find(id);
  if (accountRequest != activeMarketAccountRequests_.end()) {
    const QString action = accountRequest.value();
    activeMarketAccountRequests_.erase(accountRequest);
    if (!message.value("ok").toBool()) {
      const QString error =
          message.value("error").toString("market account request failed");
      if (action == "presence") {
        emit marketPresenceFailed(error);
      } else {
        emit marketAccountFailed(action, error);
      }
      sendPendingMarketAccount();
      return;
    }
    const QJsonValue data = message.value("data");
    if (!data.isObject()) {
      if (action == "presence") {
        emit marketPresenceFailed("daemon returned malformed Market presence");
      } else {
        emit marketAccountFailed(
            action, "daemon returned malformed market account data");
      }
      sendPendingMarketAccount();
      return;
    }
    if (action == "presence") {
      emit marketPresenceReady(data.toObject(), true);
    } else {
      emit marketAccountReady(action, data.toObject());
      pendingMarketAccountSnapshot_ = false;
    }
    sendPendingMarketAccount();
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
    sendPendingPlayerViews();
    return;
  }
  const QJsonValue data = message.value("data");
  if (!data.isObject()) {
    emit playerViewFailed(view, "daemon returned malformed player view data");
    sendPendingPlayerViews();
    return;
  }
  emit playerViewReady(view, data.toObject());
  sendPendingPlayerViews();
}

void DaemonClient::handlePlayerSnapshot(const QJsonObject &data,
                                        const QString &source) {
  const qint64 revision = data.value("revision").toInteger(-1);
  if (revision < 0 ||
      (playerRevision_.has_value() && playerRevision_.value() == revision)) {
    return;
  }
  playerRevision_ = revision;
  emit playerDatasetChanged(revision, source);
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
      {"capabilities",
       QJsonArray{"dataset.subscribe", "dataset.subscribe.metadata",
                  "relic.planner", "worldstate.activity", "player.foundry",
                  "player.inventory", "player.mastery", "market.quote",
                  "market.resolve", "market.describe", "market.account",
                  "market.orders", "market.quote.variant", "market.presence",
                  "notifications.fissures"}},
  });
}

void DaemonClient::sendPlayerSubscription() {
  write({{"op", "subscribe"},
         {"id", PlayerSubscriptionId},
         {"dataset", "player"},
         {"include_data", false}});
}

void DaemonClient::sendPendingPlayerViews() {
  if (!ready_ || pendingPlayerViews_.isEmpty()) {
    return;
  }
  const QSet<QString> pending = pendingPlayerViews_;
  for (const QString &view : pending) {
    if (activePlayerViews_.values().contains(view)) {
      continue;
    }
    pendingPlayerViews_.remove(view);
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
  for (auto request = pending.cbegin(); request != pending.cend(); ++request) {
    if (relicRequestActive(request.key())) {
      continue;
    }
    pendingRelicRequests_.remove(request.key());
    const qint64 id = nextRequestId_++;
    activeRelicRequests_.insert(id, request.value());
    write({
        {"op", "relic_planner"},
        {"id", id},
        {"era", request->era},
        {"only_owned", false},
        {"fetch_prices", request->prices},
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

void DaemonClient::sendPendingMarketVariantQuotes() {
  constexpr int MaxActiveVariantQuotes = 4;
  if (!ready_) {
    return;
  }
  while (activeMarketVariantRequests_.size() < MaxActiveVariantQuotes &&
         !pendingMarketVariantRequests_.isEmpty()) {
    const MarketVariantRequest request =
        pendingMarketVariantRequests_.takeFirst();
    const qint64 id = nextRequestId_++;
    activeMarketVariantRequests_.insert(id, request);
    write({{"op", "market_quote_variant"},
           {"id", id},
           {"item", request.item},
           {"filters", request.filters},
           {"refresh", request.refresh}});
  }
}

void DaemonClient::sendPendingMarketResolve() {
  if (!ready_ || !pendingMarketResolve_.has_value()) {
    return;
  }
  const MarketResolveRequest request = *pendingMarketResolve_;
  pendingMarketResolve_.reset();
  const qint64 id = nextRequestId_++;
  activeMarketResolveRequests_.insert(id, request);
  write({{"op", "market_resolve"},
         {"id", id},
         {"labels", QJsonArray{request.query}},
         {"limit", request.limit}});
}

void DaemonClient::sendPendingMarketDescriptions() {
  if (!ready_) {
    return;
  }
  while (activeMarketDescriptionRequests_.size() <
             MaxActiveMarketDescriptionRequests &&
         !pendingMarketDescriptionOrder_.isEmpty()) {
    QStringList items;
    while (items.size() < MarketDescriptionBatchSize &&
           !pendingMarketDescriptionOrder_.isEmpty()) {
      const QString item = pendingMarketDescriptionOrder_.takeFirst();
      if (pendingMarketDescriptions_.remove(item)) {
        items.append(item);
      }
    }
    if (items.isEmpty()) {
      continue;
    }
    const qint64 id = nextRequestId_++;
    activeMarketDescriptionRequests_.insert(id, items);
    write({{"op", "market_describe"},
           {"id", id},
           {"items", QJsonArray::fromStringList(items)}});
  }
}

void DaemonClient::sendPendingMarketAccount() {
  if (!ready_) {
    return;
  }
  while (!pendingMarketAccountRequests_.isEmpty()) {
    MarketAccountRequest request = pendingMarketAccountRequests_.takeFirst();
    const qint64 id = nextRequestId_++;
    request.message.insert("id", id);
    activeMarketAccountRequests_.insert(id, request.action);
    write(request.message);
  }
  if (!pendingMarketAccountSnapshot_ ||
      !activeMarketAccountRequests_.isEmpty()) {
    return;
  }
  pendingMarketAccountSnapshot_ = false;
  const qint64 id = nextRequestId_++;
  activeMarketAccountRequests_.insert(id, "snapshot");
  write({{"op", "market_account"}, {"id", id}});
}

void DaemonClient::queueMarketAccountRequest(const QString &action,
                                             const QJsonObject &message) {
  pendingMarketAccountRequests_.append({.action = action, .message = message});
  sendPendingMarketAccount();
}

void DaemonClient::sendAssetBatch(const QJsonArray &assets) {
  const qint64 id = nextRequestId_++;
  activeAssetRequests_.insert(id, assets);
  write({{"op", "asset_resolve"}, {"id", id}, {"assets", assets}});
}

void DaemonClient::sendPendingAssetCacheRequest() {
  if (!ready_ || activeAssetCacheRequest_ != 0) {
    return;
  }
  QString operation;
  if (pendingAssetCacheClear_) {
    pendingAssetCacheClear_ = false;
    activeAssetCacheClear_ = true;
    operation = "asset_cache_clear";
  } else if (pendingAssetCacheStatus_) {
    pendingAssetCacheStatus_ = false;
    activeAssetCacheClear_ = false;
    operation = "asset_cache_status";
  } else {
    return;
  }
  activeAssetCacheRequest_ = nextRequestId_++;
  write({{"op", operation}, {"id", activeAssetCacheRequest_}});
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

QString DaemonClient::socketPath() const { return wfgui::daemonSocketPath(); }

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

bool DaemonClient::marketQuotePhaseBusy(bool cacheOnly) const {
  if (cacheOnly ? !pendingMarketCacheQuotes_.isEmpty()
                : !pendingMarketQuotes_.isEmpty()) {
    return true;
  }
  return std::ranges::any_of(activeMarketQuoteRequests_,
                             [cacheOnly](const MarketQuoteRequest &request) {
                               return request.cacheOnly == cacheOnly;
                             });
}
