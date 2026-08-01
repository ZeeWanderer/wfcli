#pragma once

#include <QAbstractListModel>
#include <QHash>
#include <QJsonArray>
#include <QJsonObject>
#include <QList>
#include <QSet>
#include <QSortFilterProxyModel>
#include <QString>
#include <QStringList>
#include <QVariantList>

class PlayerItemModel final : public QAbstractListModel {
  Q_OBJECT

public:
  enum Role {
    NameRole = Qt::UserRole + 1,
    GroupRole,
    CategoryRole,
    TypeRole,
    QuantityRole,
    DucatsRole,
    MasteredRole,
    AssetPathRole,
    OwnedRole,
    PendingRole,
    RankRole,
    MaxRankRole,
    PotentialXpRole,
    MissingPartsRole,
    FromRelicsRole,
    BuyableRole,
    ComponentsRole,
    AssetSpecRole,
    TradableRole,
    PlatinumRole,
    BuyPlatinumRole,
    PriceStateRole,
    IsPrimeRole,
    MasteryRequirementRole,
    ReadyToBuildRole,
  };

  explicit PlayerItemModel(QObject *parent = nullptr);

  int rowCount(const QModelIndex &parent = {}) const override;
  QVariant data(const QModelIndex &index, int role) const override;
  QHash<int, QByteArray> roleNames() const override;

  bool replace(const QJsonObject &data, QString *error = nullptr);
  void clear();
  void setAssetPaths(const QHash<QString, QString> &paths);
  void applyAssetPaths(const QHash<QString, QString> &paths);
  void applyMarketQuotes(const QJsonArray &quotes, const QJsonArray &missing);
  void markMarketUnavailable(const QStringList &items);

private:
  void rebuildIndexes();
  void notifyMarketRows(const QSet<QString> &names);

  QList<QJsonObject> items_;
  QHash<QString, QString> assetPaths_;
  QMultiHash<QString, int> assetRows_;
  QMultiHash<QString, int> nameRows_;
  mutable QHash<int, QVariantList> componentCache_;
  QHash<QString, QJsonObject> marketQuotes_;
  QSet<QString> unavailableMarketItems_;
};

class PlayerItemFilterModel final : public QSortFilterProxyModel {
  Q_OBJECT

public:
  explicit PlayerItemFilterModel(QObject *parent = nullptr);

  void setText(const QString &text);
  void setGroup(const QString &group);
  void setMode(const QString &mode);

protected:
  bool filterAcceptsRow(int sourceRow,
                        const QModelIndex &sourceParent) const override;

private:
  QString text_;
  QString group_ = "all";
  QString mode_ = "all";
};
