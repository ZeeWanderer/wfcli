#include "app_controller.h"

#include <QDateTime>
#include <QJsonObject>
#include <QSet>

AppController::AppController(QObject *parent)
    : QObject(parent), daemon_(this), relics_(this), filteredRelics_(this),
      inventoryItems_(this), masteryItems_(this) {
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
            EraState &state = eras_[era];
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
            if (era == selectedEra_) {
              applySelectedEra();
            }
          });
  connect(&daemon_, &DaemonClient::assetsResolved, this,
          [this](const QJsonArray &assets) {
            for (const QJsonValue &value : assets) {
              const QJsonObject asset = value.toObject();
              if (asset.value("ok").toBool()) {
                assetPaths_.insert(asset.value("id").toString(),
                                   asset.value("path").toString());
              }
            }
            relics_.setAssetPaths(assetPaths_);
            inventoryItems_.setAssetPaths(assetPaths_);
            masteryItems_.setAssetPaths(assetPaths_);
          });
  connect(&daemon_, &DaemonClient::requestFailed, this,
          [this](const QString &era, bool prices, const QString &requestError) {
            EraState &state = eras_[era];
            state.error = requestError;
            if (prices) {
              state.pricesPending = false;
            } else {
              state.metadataPending = false;
            }
            if (era == selectedEra_) {
              applySelectedEra();
            }
          });
  connect(&daemon_, &DaemonClient::playerViewReady, this,
          &AppController::applyPlayerView);
  connect(&daemon_, &DaemonClient::playerViewFailed, this,
          [this](const QString &view, const QString &requestError) {
            PlayerViewState &state =
                view == "inventory" ? inventoryState_ : masteryState_;
            state.pending = false;
            state.error = requestError;
            if (view == "inventory") {
              emit inventoryStateChanged();
            } else {
              emit masteryStateChanged();
            }
          });
  connect(&daemon_, &DaemonClient::marketQuotesResolved, &inventoryItems_,
          &PlayerItemModel::applyMarketQuotes);
  connect(&daemon_, &DaemonClient::marketQuoteRequestFailed, &inventoryItems_,
          &PlayerItemModel::markMarketUnavailable);

  daemon_.start();
  refresh();
}

QAbstractItemModel *AppController::relics() { return &filteredRelics_; }

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

bool AppController::pricing() const {
  return eras_.value(selectedEra_).pricesPending;
}

int AppController::traceCount() const { return relics_.traceCount(); }

QJsonObject AppController::inventorySummary() const {
  return inventoryState_.summary;
}

QJsonObject AppController::masterySummary() const {
  return masteryState_.summary;
}

QString AppController::inventoryError() const { return inventoryState_.error; }

QString AppController::masteryError() const { return masteryState_.error; }

bool AppController::inventoryLoading() const { return inventoryState_.pending; }

bool AppController::masteryLoading() const { return masteryState_.pending; }

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
  emit selectedEraChanged();
  applySelectedEra();
  requestEra(era);
}

void AppController::refresh() {
  EraState &state = eras_[selectedEra_];
  state.metadataPending = true;
  state.pricesPending = true;
  state.error.clear();
  applySelectedEra();
  daemon_.requestRelics(selectedEra_, false);
  daemon_.requestRelics(selectedEra_, true);
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
  constexpr qint64 RetryAfterMs = 60'000;
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

void AppController::requestEra(const QString &era) {
  EraState &state = eras_[era];
  if (!state.hasMetadata && !state.metadataPending) {
    state.metadataPending = true;
    daemon_.requestRelics(era, false);
  }
  if (!state.hasPrices && !state.pricesPending) {
    state.pricesPending = true;
    daemon_.requestRelics(era, true);
  }
  if (era == selectedEra_) {
    applySelectedEra();
  }
}

void AppController::applySelectedEra() {
  const EraState &state = eras_.value(selectedEra_);
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
  PlayerViewState &state =
      view == "inventory" ? inventoryState_ : masteryState_;
  PlayerItemModel &model =
      view == "inventory" ? inventoryItems_ : masteryItems_;
  QString parseError;
  state.pending = false;
  if (!model.replace(data, &parseError)) {
    state.error = parseError;
  } else {
    state.loaded = true;
    state.error.clear();
    state.summary = data.value("summary").toObject();
    model.setAssetPaths(assetPaths_);
  }
  if (view == "inventory") {
    emit inventoryStateChanged();
  } else {
    emit masteryStateChanged();
  }
}
