#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>

#include "daemon_client.h"
#include "player_item_model.h"
#include "relic_model.h"

class AppController final : public QObject {
  Q_OBJECT

public:
  explicit AppController(QObject *parent = nullptr);

  QAbstractItemModel *relics();
  QAbstractItemModel *foundryItems();
  QAbstractItemModel *inventoryItems();
  QAbstractItemModel *masteryItems();
  QString selectedEra() const;
  QString filterText() const;
  bool onlyOwned() const;
  QString status() const;
  QString error() const;
  bool connected() const;
  bool loading() const;
  bool pricing() const;
  int traceCount() const;
  QJsonObject foundrySummary() const;
  QJsonObject inventorySummary() const;
  QJsonObject masterySummary() const;
  QJsonObject playerProfile() const;
  QString assetPath(const QString &id) const;
  QJsonObject activity() const;
  QString fissureNotificationMode() const;
  bool notificationSettingsLoaded() const;
  QString foundryError() const;
  QString inventoryError() const;
  QString masteryError() const;
  bool foundryLoading() const;
  bool inventoryLoading() const;
  bool masteryLoading() const;
  bool foundryLoaded() const;
  bool inventoryLoaded() const;
  bool masteryLoaded() const;
  QJsonObject marketAccount() const;
  QJsonObject marketItem(const QString &key) const;
  QJsonObject marketQuote(const QString &key) const;
  QJsonObject marketVariantQuote(const QString &item,
                                 const QJsonObject &filters) const;
  QString marketError() const;
  bool marketLoaded() const;
  bool marketBusy() const;
  bool marketQuoteFetchBusy() const;
  int ownedMarketQuantity(const QString &name) const;
  QJsonObject sourceAssetCache() const;
  QString sourceAssetCacheError() const;
  bool sourceAssetCacheBusy() const;

  void setFilterText(const QString &text);
  void setOnlyOwned(bool onlyOwned);
  void selectEra(const QString &era);
  void setActivePage(const QString &page);
  void refresh();
  void ensureRelics();
  void ensureFoundry();
  void ensureInventory();
  void ensureMastery();
  void refreshFoundry();
  void refreshInventory();
  void refreshMastery();
  void refreshActivity();
  void setFissureNotificationMode(const QString &mode);
  void resolveAssets(const QJsonArray &assets);
  void resolveMarketQuotes(const QStringList &items, bool refresh = false);
  void requestMarketVariantQuote(const QString &item,
                                 const QJsonObject &filters,
                                 bool refresh = false);
  void searchMarketItems(const QString &query, int limit = 5);
  void describeMarketItems(const QStringList &items);
  void ensureMarket();
  void refreshMarket();
  void marketLogin(const QString &email, const QString &password);
  void marketLogout();
  void marketCreateOrder(const QJsonObject &order);
  void marketUpdateOrder(const QString &id, const QJsonObject &patch);
  void marketDeleteOrder(const QString &id);
  void marketCloseOrder(const QString &id, int quantity);
  void setMarketOrdersVisible(bool visible, const QString &type = QString());
  void setMarketPresenceMode(const QString &mode);
  void refreshSourceAssetCache();
  void clearSourceAssetCache();

signals:
  void selectedEraChanged();
  void filterTextChanged();
  void onlyOwnedChanged();
  void statusChanged();
  void errorChanged();
  void connectedChanged();
  void loadingChanged();
  void pricingChanged();
  void traceCountChanged();
  void foundryStateChanged();
  void inventoryStateChanged();
  void masteryStateChanged();
  void playerProfileChanged();
  void assetsChanged(const QStringList &ids);
  void activityStateChanged();
  void notificationSettingsChanged();
  void marketAccountChanged();
  void marketCatalogChanged();
  void marketQuotesChanged();
  void marketQuoteCacheSettled();
  void marketQuoteFetchSettled();
  void marketVariantQuoteReady(const QString &item, const QJsonObject &filters,
                               const QJsonObject &data);
  void marketVariantQuoteFailed(const QString &item, const QJsonObject &filters,
                                const QString &error);
  void marketSearchReady(const QString &query, const QJsonArray &matches);
  void marketSearchFailed(const QString &query, const QString &error);
  void sourceAssetCacheChanged();

private:
  struct PlayerViewState {
    QJsonObject summary;
    QString error;
    qint64 revision = -1;
    bool loaded = false;
    bool pending = false;
    bool stale = false;
  };

  void setError(const QString &error);
  void setLoading(bool loading);
  void applySelectedEra();
  void requestAssets(const QJsonObject &data);
  void handlePlayerDatasetChanged(qint64 revision, const QString &source);
  void applyPlayerView(const QString &view, const QJsonObject &data);
  PlayerViewState *playerState(const QString &view);
  PlayerItemModel *playerModel(const QString &view);
  void emitPlayerStateChanged(const QString &view);
  void applyMarketDescriptors(const QJsonArray &items);
  void beginMarketAction();
  void finishMarketAction();
  static QString marketKey(const QString &value);
  static QString marketVariantKey(const QString &item,
                                  const QJsonObject &filters);

  struct EraState {
    QJsonObject metadata;
    QJsonObject priced;
    QString error;
    bool hasMetadata = false;
    bool hasPrices = false;
    bool metadataPending = false;
    bool pricesPending = false;
    bool stale = false;
    qint64 metadataRevision = -1;
    qint64 pricesRevision = -1;
  };

  DaemonClient daemon_;
  RelicModel relics_;
  RelicFilterModel filteredRelics_;
  PlayerItemModel inventoryItems_;
  PlayerItemModel masteryItems_;
  PlayerItemModel foundryItems_;
  QString selectedEra_ = "all";
  QString error_;
  EraState relicState_;
  wfgui::AssetMap assets_;
  QHash<QString, qint64> assetRequestedAt_;
  QHash<QString, QString> assetRequestedIdentity_;
  QHash<QString, qint64> marketRequestedAt_;
  QHash<QString, QJsonObject> marketItems_;
  QHash<QString, QJsonObject> marketQuotes_;
  QHash<QString, QJsonObject> marketVariantQuotes_;
  QSet<QString> marketVariantPending_;
  QJsonObject marketAccount_;
  QString marketError_;
  PlayerViewState foundryState_;
  PlayerViewState inventoryState_;
  PlayerViewState masteryState_;
  QJsonObject playerProfile_;
  QJsonObject activity_;
  QJsonObject sourceAssetCache_;
  QString sourceAssetCacheError_;
  QString activityError_;
  QString fissureNotificationMode_ = "off";
  bool notificationSettingsLoaded_ = false;
  bool marketLoaded_ = false;
  bool sourceAssetCacheBusy_ = false;
  bool marketPending_ = false;
  int marketActions_ = 0;
  bool relicsRequested_ = false;
  bool loading_ = false;
  QString activePage_ = "foundry";
  qint64 playerRevision_ = -1;
};
