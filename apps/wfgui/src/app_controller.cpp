#include "app_controller.h"

#include <QDateTime>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSet>
#include <QTimer>

namespace {
constexpr int AssetRefreshIntervalMs = 30 * 60'000;

QString assetRequestIdentity(const QJsonObject &spec) {
  return spec.value("source").toString("wfcd") + QChar::Null +
         spec.value("image_name").toString();
}
} // namespace

AppController::AppController(QObject *parent)
    : QObject(parent), daemon_(this), relics_(this), filteredRelics_(this),
      inventoryItems_(this), masteryItems_(this), foundryItems_(this) {
  filteredRelics_.setSourceModel(&relics_);
  assets_.insert("embedded:forma", wfgui::AssetRef::embedded(
                                       "embedded:forma", ":/assets/forma.png"));

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
            wfgui::AssetMap changedAssets;
            for (const QJsonValue &value : assets) {
              const wfgui::AssetRef asset =
                  wfgui::AssetRef::fromJson(value.toObject());
              if (asset.isValid() && assets_.value(asset.id) != asset) {
                assets_.insert(asset.id, asset);
                changedAssets.insert(asset.id, asset);
              }
            }
            if (!changedAssets.isEmpty()) {
              relics_.applyAssets(changedAssets);
              foundryItems_.applyAssets(changedAssets);
              inventoryItems_.applyAssets(changedAssets);
              masteryItems_.applyAssets(changedAssets);
              QStringList ids = changedAssets.keys();
              ids.sort();
              emit assetsChanged(ids);
            }
          });
  connect(&daemon_, &DaemonClient::assetRequestFailed, this,
          [this] { assetRequestedAt_.clear(); });
  connect(&daemon_, &DaemonClient::assetCacheStatusReady, this,
          [this](const QJsonObject &status) {
            sourceAssetCache_ = status;
            if (status.value("objects").toInteger() == 0) {
              assetRequestedAt_.clear();
            }
            sourceAssetCacheError_.clear();
            sourceAssetCacheBusy_ = false;
            emit sourceAssetCacheChanged();
          });
  connect(&daemon_, &DaemonClient::assetCacheRequestFailed, this,
          [this](const QString &requestError) {
            sourceAssetCacheError_ = requestError;
            sourceAssetCacheBusy_ = false;
            emit sourceAssetCacheChanged();
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
            QJsonArray descriptors;
            for (const QJsonValue &value : quotes) {
              const QJsonObject row = value.toObject();
              const QJsonObject item = row.value("item_data").toObject();
              if (!item.isEmpty()) {
                descriptors.append(item);
              }
              const QStringList keys = {
                  row.value("item").toString(), row.value("slug").toString(),
                  item.value("id").toString(), item.value("slug").toString(),
                  item.value("name").toString()};
              for (const QString &key : keys) {
                if (!key.isEmpty()) {
                  marketQuotes_.insert(marketKey(key), row);
                }
              }
            }
            applyMarketDescriptors(descriptors);
            emit marketQuotesChanged();
          });
  connect(&daemon_, &DaemonClient::marketQuoteRequestFailed, this,
          [this](const QStringList &items, const QString &) {
            for (const QString &item : items) {
              marketRequestedAt_.remove(item);
            }
            foundryItems_.markMarketUnavailable(items);
            inventoryItems_.markMarketUnavailable(items);
            masteryItems_.markMarketUnavailable(items);
            emit marketQuotesChanged();
          });
  connect(&daemon_, &DaemonClient::marketVariantQuoteReady, this,
          [this](const QString &item, const QJsonObject &filters,
                 const QJsonObject &data) {
            const QString key = marketVariantKey(item, filters);
            marketVariantPending_.remove(key);
            marketVariantQuotes_.insert(key, data);
            emit marketVariantQuoteReady(item, filters, data);
          });
  connect(&daemon_, &DaemonClient::marketVariantQuoteFailed, this,
          [this](const QString &item, const QJsonObject &filters,
                 const QString &error) {
            marketVariantPending_.remove(marketVariantKey(item, filters));
            emit marketVariantQuoteFailed(item, filters, error);
          });
  connect(&daemon_, &DaemonClient::marketMatchesResolved, this,
          &AppController::marketSearchReady);
  connect(&daemon_, &DaemonClient::marketMatchesFailed, this,
          &AppController::marketSearchFailed);
  connect(&daemon_, &DaemonClient::marketItemsDescribed, this,
          [this](const QJsonArray &items, const QJsonArray &) {
            applyMarketDescriptors(items);
          });
  connect(&daemon_, &DaemonClient::marketAccountReady, this,
          [this](const QString &action, const QJsonObject &account) {
            if (action == "snapshot") {
              marketPending_ = false;
            } else {
              finishMarketAction();
            }
            marketAccount_ = account;
            marketLoaded_ = true;
            marketError_.clear();
            QStringList items;
            for (const QJsonValue &value : account.value("orders").toArray()) {
              const QString item = value.toObject().value("itemId").toString();
              if (!item.isEmpty() && !items.contains(item)) {
                items.append(item);
              }
            }
            describeMarketItems(items);
            resolveMarketQuotes(items);
            emit marketAccountChanged();
          });
  connect(&daemon_, &DaemonClient::marketAccountFailed, this,
          [this](const QString &action, const QString &requestError) {
            if (action == "snapshot") {
              marketPending_ = false;
            } else {
              finishMarketAction();
            }
            marketError_ = requestError;
            if (requestError.contains("session expired", Qt::CaseInsensitive)) {
              marketAccount_ = {{"authenticated", false},
                                {"profile", QJsonValue::Null},
                                {"orders", QJsonArray{}}};
              marketLoaded_ = true;
            }
            emit marketAccountChanged();
          });
  connect(&daemon_, &DaemonClient::marketPresenceReady, this,
          [this](const QJsonObject &presence, bool requested) {
            if (requested) {
              finishMarketAction();
            }
            marketAccount_.insert("presence", presence);
            marketError_.clear();
            emit marketAccountChanged();
          });
  connect(&daemon_, &DaemonClient::marketPresenceFailed, this,
          [this](const QString &requestError) {
            finishMarketAction();
            marketError_ = requestError;
            emit marketAccountChanged();
          });

  daemon_.start();
  ensureFoundry();
  refreshActivity();
  auto *activityTimer = new QTimer(this);
  activityTimer->setInterval(60'000);
  connect(activityTimer, &QTimer::timeout, this,
          &AppController::refreshActivity);
  activityTimer->start();

  auto *assetRefreshTimer = new QTimer(this);
  assetRefreshTimer->setInterval(AssetRefreshIntervalMs);
  connect(assetRefreshTimer, &QTimer::timeout, this, [this] {
    QJsonArray specs;
    for (auto asset = assets_.cbegin(); asset != assets_.cend(); ++asset) {
      if (!asset->isPersistent()) {
        continue;
      }
      specs.append(QJsonObject{{"id", asset->id},
                               {"source", asset->source},
                               {"image_name", asset->imageName}});
    }
    resolveAssets(specs);
  });
  assetRefreshTimer->start();
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
  return assets_.value(id).path;
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

QJsonObject AppController::marketAccount() const { return marketAccount_; }

QJsonObject AppController::marketItem(const QString &key) const {
  return marketItems_.value(marketKey(key));
}

QJsonObject AppController::marketQuote(const QString &key) const {
  return marketQuotes_.value(marketKey(key));
}

QJsonObject
AppController::marketVariantQuote(const QString &item,
                                  const QJsonObject &filters) const {
  return marketVariantQuotes_.value(marketVariantKey(item, filters));
}

QString AppController::marketError() const { return marketError_; }

bool AppController::marketLoaded() const { return marketLoaded_; }

bool AppController::marketBusy() const {
  return marketPending_ || marketActions_ > 0;
}

int AppController::ownedMarketQuantity(const QString &name) const {
  if (!inventoryState_.loaded) {
    return -1;
  }
  const QString key = marketKey(name);
  int quantity = 0;
  bool found = false;
  for (int row = 0; row < inventoryItems_.rowCount(); ++row) {
    const QModelIndex index = inventoryItems_.index(row, 0);
    const QString marketName =
        marketKey(index.data(PlayerItemModel::MarketNameRole).toString());
    const QString displayName =
        marketKey(index.data(PlayerItemModel::NameRole).toString());
    if (marketName == key || displayName == key) {
      quantity += index.data(PlayerItemModel::QuantityRole).toInt();
      found = true;
    }
  }
  return found ? quantity : 0;
}

QJsonObject AppController::sourceAssetCache() const {
  return sourceAssetCache_;
}

QString AppController::sourceAssetCacheError() const {
  return sourceAssetCacheError_;
}

bool AppController::sourceAssetCacheBusy() const {
  return sourceAssetCacheBusy_;
}

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
  } else if (relicState_.hasPrices) {
    requestAssets(relicState_.priced);
  } else if (relicState_.hasMetadata) {
    requestAssets(relicState_.metadata);
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
  const qint64 now = QDateTime::currentMSecsSinceEpoch();
  QJsonArray pending;
  for (const QJsonValue &value : assets) {
    const QJsonObject spec = value.toObject();
    const QString id = spec.value("id").toString();
    if (id.isEmpty()) {
      continue;
    }
    const bool missing = !assets_.contains(id);
    const QString identity = assetRequestIdentity(spec);
    const bool changed = assetRequestedIdentity_.value(id) != identity;
    if (missing || changed ||
        now - assetRequestedAt_.value(id, 0) >= AssetRefreshIntervalMs) {
      pending.append(value);
      assetRequestedAt_.insert(id, now);
      assetRequestedIdentity_.insert(id, identity);
    }
  }
  daemon_.requestAssets(pending);
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

void AppController::requestMarketVariantQuote(const QString &item,
                                              const QJsonObject &filters,
                                              bool refresh) {
  const QString key = marketVariantKey(item, filters);
  const QJsonObject cached = marketVariantQuote(item, filters);
  if (!refresh && !cached.isEmpty()) {
    QTimer::singleShot(0, this, [this, item, filters, cached] {
      emit marketVariantQuoteReady(item, filters, cached);
    });
    return;
  }
  if (marketVariantPending_.contains(key)) {
    return;
  }
  marketVariantPending_.insert(key);
  daemon_.requestMarketVariantQuote(item, filters, refresh);
}

void AppController::searchMarketItems(const QString &query, int limit) {
  daemon_.requestMarketMatches(query, limit);
}

void AppController::describeMarketItems(const QStringList &items) {
  QStringList missing;
  for (const QString &item : items) {
    if (!item.isEmpty() && !marketItems_.contains(marketKey(item))) {
      missing.append(item);
    }
  }
  daemon_.requestMarketItems(missing);
}

void AppController::ensureMarket() {
  if (!marketLoaded_ && !marketPending_) {
    refreshMarket();
  }
}

void AppController::refreshMarket() {
  if (marketPending_) {
    return;
  }
  marketPending_ = true;
  marketError_.clear();
  emit marketAccountChanged();
  daemon_.requestMarketAccount();
}

void AppController::marketLogin(const QString &email, const QString &password) {
  beginMarketAction();
  daemon_.marketLogin(email, password);
}

void AppController::marketLogout() {
  beginMarketAction();
  daemon_.marketLogout();
}

void AppController::marketCreateOrder(const QJsonObject &order) {
  beginMarketAction();
  daemon_.marketCreateOrder(order);
}

void AppController::marketUpdateOrder(const QString &id,
                                      const QJsonObject &patch) {
  beginMarketAction();
  daemon_.marketUpdateOrder(id, patch);
}

void AppController::marketDeleteOrder(const QString &id) {
  beginMarketAction();
  daemon_.marketDeleteOrder(id);
}

void AppController::marketCloseOrder(const QString &id, int quantity) {
  beginMarketAction();
  daemon_.marketCloseOrder(id, quantity);
}

void AppController::setMarketOrdersVisible(bool visible, const QString &type) {
  beginMarketAction();
  daemon_.setMarketOrdersVisible(visible, type);
}

void AppController::setMarketPresenceMode(const QString &mode) {
  beginMarketAction();
  daemon_.setMarketPresenceMode(mode);
}

void AppController::refreshSourceAssetCache() {
  if (sourceAssetCacheBusy_) {
    return;
  }
  sourceAssetCacheBusy_ = true;
  sourceAssetCacheError_.clear();
  emit sourceAssetCacheChanged();
  daemon_.requestAssetCacheStatus();
}

void AppController::clearSourceAssetCache() {
  if (sourceAssetCacheBusy_) {
    return;
  }
  sourceAssetCacheBusy_ = true;
  sourceAssetCacheError_.clear();
  emit sourceAssetCacheChanged();
  daemon_.clearAssetCache();
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
  relics_.setAssets(assets_);
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
    if (!relicId.isEmpty()) {
      relicAssets.append(relicAsset);
    }
    for (const QJsonValue &rewardValue : item.value("rewards").toArray()) {
      const QJsonObject rewardAsset =
          rewardValue.toObject().value("asset").toObject();
      const QString rewardId = rewardAsset.value("id").toString();
      if (!rewardId.isEmpty()) {
        rewardAssets.append(rewardAsset);
      }
    }
    for (const QJsonValue &componentValue :
         item.value("components").toArray()) {
      const QJsonObject componentAsset =
          componentValue.toObject().value("asset").toObject();
      const QString componentId = componentAsset.value("id").toString();
      if (!componentId.isEmpty()) {
        rewardAssets.append(componentAsset);
      }
    }
  }
  resolveAssets(relicAssets);
  resolveAssets(rewardAssets);
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
    model->setAssets(assets_);
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

void AppController::applyMarketDescriptors(const QJsonArray &items) {
  QJsonArray assets;
  bool changed = false;
  for (const QJsonValue &value : items) {
    const QJsonObject item = value.toObject();
    if (item.isEmpty()) {
      continue;
    }
    const QStringList keys = {item.value("id").toString(),
                              item.value("slug").toString(),
                              item.value("name").toString()};
    for (const QString &key : keys) {
      if (!key.isEmpty() && marketItems_.value(marketKey(key)) != item) {
        marketItems_.insert(marketKey(key), item);
        changed = true;
      }
    }
    const QJsonObject asset = item.value("asset").toObject();
    if (!asset.isEmpty()) {
      assets.append(asset);
    }
  }
  resolveAssets(assets);
  if (changed) {
    emit marketCatalogChanged();
  }
}

void AppController::beginMarketAction() {
  ++marketActions_;
  marketError_.clear();
  emit marketAccountChanged();
}

void AppController::finishMarketAction() {
  marketActions_ = qMax(0, marketActions_ - 1);
}

QString AppController::marketKey(const QString &value) {
  return value.trimmed().toCaseFolded();
}

QString AppController::marketVariantKey(const QString &item,
                                        const QJsonObject &filters) {
  return marketKey(item) + ':' +
         QString::fromUtf8(
             QJsonDocument(filters).toJson(QJsonDocument::Compact));
}
