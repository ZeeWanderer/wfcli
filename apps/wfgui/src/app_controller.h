#pragma once

#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QObject>
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
  QJsonObject inventorySummary() const;
  QJsonObject masterySummary() const;
  QString inventoryError() const;
  QString masteryError() const;
  bool inventoryLoading() const;
  bool masteryLoading() const;
  bool inventoryLoaded() const;
  bool masteryLoaded() const;

  void setFilterText(const QString &text);
  void setOnlyOwned(bool onlyOwned);
  void selectEra(const QString &era);
  void refresh();
  void ensureInventory();
  void ensureMastery();
  void refreshInventory();
  void refreshMastery();
  void resolveAssets(const QJsonArray &assets);
  void resolveMarketQuotes(const QStringList &items, bool refresh = false);

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
  void inventoryStateChanged();
  void masteryStateChanged();

private:
  void setError(const QString &error);
  void setLoading(bool loading);
  void requestEra(const QString &era);
  void applySelectedEra();
  void requestAssets(const QJsonObject &data);
  void applyPlayerView(const QString &view, const QJsonObject &data);

  struct EraState {
    QJsonObject metadata;
    QJsonObject priced;
    QString error;
    bool hasMetadata = false;
    bool hasPrices = false;
    bool metadataPending = false;
    bool pricesPending = false;
  };

  struct PlayerViewState {
    QJsonObject summary;
    QString error;
    bool loaded = false;
    bool pending = false;
  };

  DaemonClient daemon_;
  RelicModel relics_;
  RelicFilterModel filteredRelics_;
  PlayerItemModel inventoryItems_;
  PlayerItemModel masteryItems_;
  QString selectedEra_ = "all";
  QString error_;
  QHash<QString, EraState> eras_;
  QHash<QString, QString> assetPaths_;
  QHash<QString, qint64> marketRequestedAt_;
  PlayerViewState inventoryState_;
  PlayerViewState masteryState_;
  bool loading_ = false;
};
