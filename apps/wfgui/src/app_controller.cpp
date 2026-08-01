#include "app_controller.h"

#include <QDateTime>
#include <QJsonObject>
#include <QSet>
#include <QTimer>

AppController::AppController(QObject *parent)
    : QObject(parent), daemon_(this), relics_(this), filteredRelics_(this),
      inventoryItems_(this), masteryItems_(this), foundryItems_(this) {
  filteredRelics_.setSourceModel(&relics_);
  assetPaths_.insert("embedded:forma", ":/assets/forma.png");

  connect(&daemon_, &DaemonClient::connectionChanged, this,
          &AppController::connectedChanged);
  connect(&daemon_, &DaemonClient::statusChanged, this,
          &AppController::statusChanged);
  connect(&filteredRelics_, &RelicFilterModel::filterTextChanged, this,
          &AppController::filterTextChanged);
  connect(&filteredRelics_, &RelicFilterModel::onlyOwnedChanged, this,
          &AppController::onlyOwnedChanged);
  connect(&daemon_, &DaemonClient::relicPlannerReady, this,
          [this](const QString &era, bool prices, const QJsonObject &data) {
            if (era != "all") {
              return;
            }
            EraState &state = relicState_;
            if (prices) {
              state.priced = data;
              state.hasPrices = true;
              state.pricesPending = false;
            } else {
              state.metadata = data;
              state.hasMetadata = true;
              state.metadataPending = false;
            }
            state.error.clear();
            requestAssets(data);
            applySelectedEra();
          });
  connect(&daemon_, &DaemonClient::assetsResolved, this,
          [this](const QJsonArray &assets) {
            QHash<QString, QString> changedPaths;
            for (const QJsonValue &value : assets) {
              const QJsonObject asset = value.toObject();
              if (asset.value("ok").toBool()) {
                const QString id = asset.value("id").toString();
                const QString path = asset.value("path").toString();
                if (!id.isEmpty() && !path.isEmpty() &&
                    assetPaths_.value(id) != path) {
                  assetPaths_.insert(id, path);
                  changedPaths.insert(id, path);
                }
              }
            }
            if (!changedPaths.isEmpty()) {
              relics_.setAssetPaths(changedPaths);
              foundryItems_.applyAssetPaths(changedPaths);
              inventoryItems_.applyAssetPaths(changedPaths);
              masteryItems_.applyAssetPaths(changedPaths);
              emit assetsChanged();
            }
          });
  connect(&daemon_, &DaemonClient::requestFailed, this,
          [this](const QString &era, bool prices, const QString &requestError) {
            if (era != "all") {
              return;
            }
            EraState &state = relicState_;
            state.error = requestError;
            if (prices) {
              state.pricesPending = false;
            } else {
              state.metadataPending = false;
            }
            applySelectedEra();
          });
  connect(&daemon_, &DaemonClient::playerViewReady, this,
          &AppController::applyPlayerView);
  connect(&daemon_, &DaemonClient::playerViewFailed, this,
          [this](const QString &view, const QString &requestError) {
            if (PlayerViewState *state = playerState(view)) {
              state->pending = false;
              state->error = requestError;
              emitPlayerStateChanged(view);
            }
          });
  connect(&daemon_, &DaemonClient::activityReady, this,
          [this](const QJsonObject &data) {
            activity_ = data;
            activityError_.clear();
            emit activityStateChanged();
          });
  connect(&daemon_, &DaemonClient::activityFailed, this,
          [this](const QString &requestError) {
            activityError_ = requestError;
            emit activityStateChanged();
          });
  connect(
      &daemon_, &DaemonClient::notificationSettingsReady, this,
      [this](const QJsonObject &settings) {
        const QString mode =
            settings.value("fissures").toObject().value("mode").toString("off");
        if (mode != "off" && mode != "session" && mode != "persistent") {
          return;
        }
        const bool changed =
            fissureNotificationMode_ != mode || !notificationSettingsLoaded_;
        fissureNotificationMode_ = mode;
        notificationSettingsLoaded_ = true;
        if (changed) {
          emit notificationSettingsChanged();
        }
      });
  connect(&daemon_, &DaemonClient::marketQuotesResolved, this,
          [this](const QJsonArray &quotes, const QJsonArray &missing) {
            foundryItems_.applyMarketQuotes(quotes, missing);
            inventoryItems_.applyMarketQuotes(quotes, missing);
            masteryItems_.applyMarketQuotes(quotes, missing);
          });
  connect(&daemon_, &DaemonClient::marketQuoteRequestFailed, this,
          [this](const QStringList &items, const QString &) {
            for (const QString &item : items) {
              marketRequestedAt_.remove(item);
            }
          });

  daemon_.start();
  ensureFoundry();
  refreshActivity();
  auto *activityTimer = new QTimer(this);
  activityTimer->setInterval(60'000);
  connect(activityTimer, &QTimer::timeout, this,
          &AppController::refreshActivity);
  activityTimer->start();
}

QAbstractItemModel *AppController::relics() { return &filteredRelics_; }

QAbstractItemModel *AppController::foundryItems() { return &foundryItems_; }

QAbstractItemModel *AppController::inventoryItems() { return &inventoryItems_; }

QAbstractItemModel *AppController::masteryItems() { return &masteryItems_; }

QString AppController::selectedEra() const { return selectedEra_; }

QString AppController::filterText() const {
  return filteredRelics_.filterText();
}

bool AppController::onlyOwned() const { return filteredRelics_.onlyOwned(); }

QString AppController::status() const { return daemon_.status(); }

QString AppController::error() const { return error_; }

bool AppController::connected() const { return daemon_.connected(); }

bool AppController::loading() const { return loading_; }

bool AppController::pricing() const { return relicState_.pricesPending; }

int AppController::traceCount() const { return relics_.traceCount(); }

QJsonObject AppController::foundrySummary() const {
  return foundryState_.summary;
}

QJsonObject AppController::inventorySummary() const {
  return inventoryState_.summary;
}

QJsonObject AppController::masterySummary() const {
  return masteryState_.summary;
}

QJsonObject AppController::playerProfile() const { return playerProfile_; }

QString AppController::assetPath(const QString &id) const {
  return assetPaths_.value(id);
}

QJsonObject AppController::activity() const {
  QJsonObject result = activity_;
  if (!activityError_.isEmpty()) {
    result.insert("error", activityError_);
  }
  return result;
}

QString AppController::fissureNotificationMode() const {
  return fissureNotificationMode_;
}

bool AppController::notificationSettingsLoaded() const {
  return notificationSettingsLoaded_;
}

QString AppController::foundryError() const { return foundryState_.error; }

QString AppController::inventoryError() const { return inventoryState_.error; }

QString AppController::masteryError() const { return masteryState_.error; }

bool AppController::foundryLoading() const { return foundryState_.pending; }

bool AppController::inventoryLoading() const { return inventoryState_.pending; }

bool AppController::masteryLoading() const { return masteryState_.pending; }

bool AppController::foundryLoaded() const { return foundryState_.loaded; }

bool AppController::inventoryLoaded() const { return inventoryState_.loaded; }

bool AppController::masteryLoaded() const { return masteryState_.loaded; }

void AppController::setFilterText(const QString &text) {
  filteredRelics_.setFilterText(text);
}

void AppController::setOnlyOwned(bool onlyOwned) {
  filteredRelics_.setOnlyOwned(onlyOwned);
}

void AppController::selectEra(const QString &era) {
  static const QSet<QString> eras = {
      "all", "lith", "meso", "neo", "axi",
  };
  if (!eras.contains(era) || selectedEra_ == era) {
    return;
  }
  selectedEra_ = era;
  filteredRelics_.setEra(era);
  emit selectedEraChanged();
}

void AppController::refresh() {
  relicsRequested_ = true;
  EraState &state = relicState_;
  state.metadataPending = true;
  state.pricesPending = true;
  state.error.clear();
  applySelectedEra();
  daemon_.requestRelics("all", false);
  daemon_.requestRelics("all", true);
}

void AppController::ensureRelics() {
  if (!relicsRequested_) {
    refresh();
  }
}

void AppController::ensureFoundry() {
  if (!foundryState_.loaded && !foundryState_.pending) {
    refreshFoundry();
  }
}

void AppController::ensureInventory() {
  if (!inventoryState_.loaded && !inventoryState_.pending) {
    refreshInventory();
  }
}

void AppController::ensureMastery() {
  if (!masteryState_.loaded && !masteryState_.pending) {
    refreshMastery();
  }
}

void AppController::refreshFoundry() {
  foundryState_.pending = true;
  foundryState_.error.clear();
  emit foundryStateChanged();
  daemon_.requestPlayerView("foundry");
}

void AppController::refreshInventory() {
  inventoryState_.pending = true;
  inventoryState_.error.clear();
  emit inventoryStateChanged();
  daemon_.requestPlayerView("inventory");
}

void AppController::refreshMastery() {
  masteryState_.pending = true;
  masteryState_.error.clear();
  emit masteryStateChanged();
  daemon_.requestPlayerView("mastery");
}

void AppController::refreshActivity() { daemon_.requestActivity(); }

void AppController::setFissureNotificationMode(const QString &mode) {
  if (mode != "off" && mode != "session" && mode != "persistent") {
    return;
  }
  if (notificationSettingsLoaded_ && fissureNotificationMode_ == mode) {
    return;
  }
  fissureNotificationMode_ = mode;
  notificationSettingsLoaded_ = true;
  emit notificationSettingsChanged();
  daemon_.setFissureNotificationMode(mode);
}

void AppController::resolveAssets(const QJsonArray &assets) {
  QJsonArray missing;
  for (const QJsonValue &value : assets) {
    const QString id = value.toObject().value("id").toString();
    if (!id.isEmpty() && !assetPaths_.contains(id)) {
      missing.append(value);
    }
  }
  daemon_.requestAssets(missing);
}

void AppController::resolveMarketQuotes(const QStringList &items,
                                        bool refresh) {
  constexpr qint64 RetryAfterMs = 15 * 60'000;
  const qint64 now = QDateTime::currentMSecsSinceEpoch();
  QStringList pending;
  for (const QString &item : items) {
    if (item.isEmpty()) {
      continue;
    }
    const qint64 requestedAt = marketRequestedAt_.value(item, 0);
    if (refresh || requestedAt == 0 || now - requestedAt >= RetryAfterMs) {
      marketRequestedAt_.insert(item, now);
      pending.append(item);
    }
  }
  daemon_.requestMarketQuotes(pending, refresh);
}

void AppController::setError(const QString &error) {
  if (error_ == error) {
    return;
  }
  error_ = error;
  emit errorChanged();
}

void AppController::setLoading(bool loading) {
  if (loading_ == loading) {
    return;
  }
  loading_ = loading;
  emit loadingChanged();
}

void AppController::applySelectedEra() {
  const EraState &state = relicState_;
  const QJsonObject data = state.hasPrices ? state.priced : state.metadata;
  if (!data.isEmpty()) {
    QString parseError;
    if (!relics_.replace(data, &parseError)) {
      setError(parseError);
    } else {
      setError(state.error);
      emit traceCountChanged();
    }
  } else {
    relics_.clear();
    setError(state.error);
    emit traceCountChanged();
  }
  relics_.setPricesLoading(state.pricesPending);
  relics_.setAssetPaths(assetPaths_);
  setLoading(!state.hasMetadata && state.metadataPending);
  emit pricingChanged();
}

void AppController::requestAssets(const QJsonObject &data) {
  QJsonArray relicAssets;
  QJsonArray rewardAssets;
  for (const QJsonValue &itemValue : data.value("items").toArray()) {
    const QJsonObject item = itemValue.toObject();
    const QJsonObject relicAsset = item.value("asset").toObject();
    const QString relicId = relicAsset.value("id").toString();
    if (!relicId.isEmpty() && !assetPaths_.contains(relicId)) {
      relicAssets.append(relicAsset);
    }
    for (const QJsonValue &rewardValue : item.value("rewards").toArray()) {
      const QJsonObject rewardAsset =
          rewardValue.toObject().value("asset").toObject();
      const QString rewardId = rewardAsset.value("id").toString();
      if (!rewardId.isEmpty() && !assetPaths_.contains(rewardId)) {
        rewardAssets.append(rewardAsset);
      }
    }
    for (const QJsonValue &componentValue :
         item.value("components").toArray()) {
      const QJsonObject componentAsset =
          componentValue.toObject().value("asset").toObject();
      const QString componentId = componentAsset.value("id").toString();
      if (!componentId.isEmpty() && !assetPaths_.contains(componentId)) {
        rewardAssets.append(componentAsset);
      }
    }
  }
  daemon_.requestAssets(relicAssets);
  daemon_.requestAssets(rewardAssets);
}

void AppController::applyPlayerView(const QString &view,
                                    const QJsonObject &data) {
  PlayerViewState *state = playerState(view);
  PlayerItemModel *model = playerModel(view);
  if (!state || !model) {
    return;
  }
  QString parseError;
  state->pending = false;
  if (!model->replace(data, &parseError)) {
    state->error = parseError;
  } else {
    state->loaded = true;
    state->error.clear();
    state->summary = data.value("summary").toObject();
    const QJsonObject profile = data.value("profile").toObject();
    if (!profile.isEmpty() && profile != playerProfile_) {
      playerProfile_ = profile;
      emit playerProfileChanged();
    }
    const QJsonObject rankAsset = profile.value("rank_asset").toObject();
    if (!rankAsset.value("id").toString().isEmpty()) {
      resolveAssets(QJsonArray{rankAsset});
    }
    model->setAssetPaths(assetPaths_);
  }
  emitPlayerStateChanged(view);
}

AppController::PlayerViewState *
AppController::playerState(const QString &view) {
  if (view == "foundry") {
    return &foundryState_;
  }
  if (view == "inventory") {
    return &inventoryState_;
  }
  if (view == "mastery") {
    return &masteryState_;
  }
  return nullptr;
}

PlayerItemModel *AppController::playerModel(const QString &view) {
  if (view == "foundry") {
    return &foundryItems_;
  }
  if (view == "inventory") {
    return &inventoryItems_;
  }
  if (view == "mastery") {
    return &masteryItems_;
  }
  return nullptr;
}

void AppController::emitPlayerStateChanged(const QString &view) {
  if (view == "foundry") {
    emit foundryStateChanged();
  } else if (view == "inventory") {
    emit inventoryStateChanged();
  } else if (view == "mastery") {
    emit masteryStateChanged();
  }
}
