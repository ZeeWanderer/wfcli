#include "player_item_model.h"

#include <QJsonArray>
#include <QSet>
#include <QVariantList>
#include <QVariantMap>

namespace {
QString assetId(const QJsonObject &item) {
  return item.value("asset").toObject().value("id").toString();
}
} // namespace

PlayerItemModel::PlayerItemModel(QObject *parent)
    : QAbstractListModel(parent) {}

int PlayerItemModel::rowCount(const QModelIndex &parent) const {
  return parent.isValid() ? 0 : items_.size();
}

QVariant PlayerItemModel::data(const QModelIndex &index, int role) const {
  if (!index.isValid() || index.row() < 0 || index.row() >= items_.size()) {
    return {};
  }
  const QJsonObject &item = items_.at(index.row());
  switch (role) {
  case NameRole:
  case Qt::DisplayRole:
  case Qt::ToolTipRole:
    return item.value("name").toString();
  case GroupRole:
    return item.value("group").toString();
  case CategoryRole:
    return item.value("category").toString();
  case QuantityRole:
    return item.value("quantity").toInt();
  case DucatsRole:
    return item.value("ducats").toInt();
  case MasteredRole:
    return item.value("mastered").toBool();
  case AssetPathRole:
    return assetPaths_.value(assetId(item));
  case OwnedRole:
    return item.value("owned").toBool();
  case PendingRole:
    return item.value("pending").toBool();
  case RankRole:
    return item.value("rank").toInt();
  case MaxRankRole:
    return item.value("max_rank").toInt();
  case PotentialXpRole:
    return item.value("potential_xp").toInt();
  case MissingPartsRole:
    return item.value("missing_parts").toInt();
  case FromRelicsRole:
    return item.value("from_relics").toBool();
  case BuyableRole:
    return item.value("buyable").toBool();
  case ComponentsRole: {
    const auto cached = componentCache_.constFind(index.row());
    if (cached != componentCache_.cend()) {
      return cached.value();
    }
    QVariantList result;
    for (const QJsonValue &value : item.value("components").toArray()) {
      const QJsonObject component = value.toObject();
      QVariantMap converted = component.toVariantMap();
      converted.insert("image", assetPaths_.value(assetId(component)));
      result.append(converted);
    }
    componentCache_.insert(index.row(), result);
    return result;
  }
  case AssetSpecRole:
    return item.value("asset").toObject().toVariantMap();
  case TradableRole:
    return item.value("tradable").toBool();
  case PlatinumRole: {
    const QJsonValue price =
        marketQuotes_.value(item.value("name").toString()).value("lowest_sell");
    return price.isDouble() ? QVariant(price.toInt()) : QVariant();
  }
  case PriceStateRole: {
    if (!item.value("tradable").toBool()) {
      return QStringLiteral("none");
    }
    const QString name = item.value("name").toString();
    if (marketQuotes_.value(name).value("lowest_sell").isDouble()) {
      return QStringLiteral("ready");
    }
    return unavailableMarketItems_.contains(name) ||
                   marketQuotes_.contains(name)
               ? QStringLiteral("unavailable")
               : QStringLiteral("loading");
  }
  default:
    return {};
  }
}

QHash<int, QByteArray> PlayerItemModel::roleNames() const {
  return {{NameRole, "name"},
          {GroupRole, "group"},
          {CategoryRole, "category"},
          {QuantityRole, "quantity"},
          {DucatsRole, "ducats"},
          {MasteredRole, "mastered"},
          {AssetPathRole, "assetPath"},
          {OwnedRole, "owned"},
          {PendingRole, "pending"},
          {RankRole, "rank"},
          {MaxRankRole, "maxRank"},
          {PotentialXpRole, "potentialXp"},
          {MissingPartsRole, "missingParts"},
          {FromRelicsRole, "fromRelics"},
          {BuyableRole, "buyable"},
          {ComponentsRole, "components"},
          {AssetSpecRole, "assetSpec"},
          {TradableRole, "tradable"},
          {PlatinumRole, "platinum"},
          {PriceStateRole, "priceState"}};
}

bool PlayerItemModel::replace(const QJsonObject &data, QString *error) {
  if (!data.value("items").isArray()) {
    if (error) {
      *error = "daemon returned malformed player view data";
    }
    return false;
  }
  QList<QJsonObject> next;
  for (const QJsonValue &value : data.value("items").toArray()) {
    const QJsonObject item = value.toObject();
    if (!item.value("id").isString() || !item.value("name").isString()) {
      continue;
    }
    next.append(item);
  }
  beginResetModel();
  items_ = std::move(next);
  componentCache_.clear();
  rebuildIndexes();
  endResetModel();
  return true;
}

void PlayerItemModel::clear() {
  if (items_.isEmpty()) {
    return;
  }
  beginResetModel();
  items_.clear();
  assetRows_.clear();
  nameRows_.clear();
  componentCache_.clear();
  endResetModel();
}

void PlayerItemModel::setAssetPaths(const QHash<QString, QString> &paths) {
  if (assetPaths_ == paths) {
    return;
  }

  QSet<int> affectedRows;
  for (auto path = assetPaths_.cbegin(); path != assetPaths_.cend(); ++path) {
    if (paths.value(path.key()) != path.value()) {
      for (int row : assetRows_.values(path.key())) {
        affectedRows.insert(row);
      }
    }
  }
  for (auto path = paths.cbegin(); path != paths.cend(); ++path) {
    if (assetPaths_.value(path.key()) != path.value()) {
      for (int row : assetRows_.values(path.key())) {
        affectedRows.insert(row);
      }
    }
  }

  assetPaths_ = paths;
  for (int row : affectedRows) {
    componentCache_.remove(row);
    emit dataChanged(index(row), index(row), {AssetPathRole, ComponentsRole});
  }
}

void PlayerItemModel::applyAssetPaths(
    const QHash<QString, QString> &paths) {
  QSet<int> affectedRows;
  for (auto path = paths.cbegin(); path != paths.cend(); ++path) {
    if (path.value().isEmpty() || assetPaths_.value(path.key()) == path.value()) {
      continue;
    }
    assetPaths_.insert(path.key(), path.value());
    for (int row : assetRows_.values(path.key())) {
      affectedRows.insert(row);
    }
  }
  for (int row : affectedRows) {
    componentCache_.remove(row);
    emit dataChanged(index(row), index(row), {AssetPathRole, ComponentsRole});
  }
}

void PlayerItemModel::applyMarketQuotes(const QJsonArray &quotes,
                                        const QJsonArray &missing) {
  QSet<QString> changed;
  for (const QJsonValue &value : quotes) {
    const QJsonObject row = value.toObject();
    const QString name = row.value("item").toString();
    if (name.isEmpty()) {
      continue;
    }
    const QJsonValue quote = row.value("quote");
    if (quote.isObject()) {
      marketQuotes_.insert(name, quote.toObject());
      unavailableMarketItems_.remove(name);
    } else {
      marketQuotes_.remove(name);
      unavailableMarketItems_.insert(name);
    }
    changed.insert(name);
  }
  for (const QJsonValue &value : missing) {
    const QString name = value.toString();
    if (!name.isEmpty()) {
      marketQuotes_.remove(name);
      unavailableMarketItems_.insert(name);
      changed.insert(name);
    }
  }
  notifyMarketRows(changed);
}

void PlayerItemModel::markMarketUnavailable(const QStringList &items) {
  QSet<QString> changed;
  for (const QString &name : items) {
    if (!name.isEmpty()) {
      unavailableMarketItems_.insert(name);
      changed.insert(name);
    }
  }
  notifyMarketRows(changed);
}

void PlayerItemModel::rebuildIndexes() {
  assetRows_.clear();
  nameRows_.clear();
  for (int row = 0; row < items_.size(); ++row) {
    const QJsonObject &item = items_.at(row);
    nameRows_.insert(item.value("name").toString(), row);
    const QString itemAsset = assetId(item);
    if (!itemAsset.isEmpty()) {
      assetRows_.insert(itemAsset, row);
    }
    for (const QJsonValue &value : item.value("components").toArray()) {
      const QString componentAsset = assetId(value.toObject());
      if (!componentAsset.isEmpty()) {
        assetRows_.insert(componentAsset, row);
      }
    }
  }
}

void PlayerItemModel::notifyMarketRows(const QSet<QString> &names) {
  QSet<int> rows;
  for (const QString &name : names) {
    for (int row : nameRows_.values(name)) {
      rows.insert(row);
    }
  }
  for (int row : rows) {
    emit dataChanged(index(row), index(row), {PlatinumRole, PriceStateRole});
  }
}

PlayerItemFilterModel::PlayerItemFilterModel(QObject *parent)
    : QSortFilterProxyModel(parent) {
  setDynamicSortFilter(true);
}

void PlayerItemFilterModel::setText(const QString &text) {
  if (text_ == text) {
    return;
  }
  beginFilterChange();
  text_ = text;
  endFilterChange(QSortFilterProxyModel::Direction::Rows);
}

void PlayerItemFilterModel::setGroup(const QString &group) {
  if (group_ == group) {
    return;
  }
  beginFilterChange();
  group_ = group;
  endFilterChange(QSortFilterProxyModel::Direction::Rows);
}

void PlayerItemFilterModel::setMode(const QString &mode) {
  if (mode_ == mode) {
    return;
  }
  beginFilterChange();
  mode_ = mode;
  endFilterChange(QSortFilterProxyModel::Direction::Rows);
}

bool PlayerItemFilterModel::filterAcceptsRow(
    int sourceRow, const QModelIndex &sourceParent) const {
  const QModelIndex item = sourceModel()->index(sourceRow, 0, sourceParent);
  if (group_ != "all" &&
      sourceModel()->data(item, PlayerItemModel::GroupRole).toString() !=
          group_) {
    return false;
  }
  if (!text_.isEmpty() && !sourceModel()
                               ->data(item, PlayerItemModel::NameRole)
                               .toString()
                               .contains(text_, Qt::CaseInsensitive)) {
    return false;
  }
  const bool mastered =
      sourceModel()->data(item, PlayerItemModel::MasteredRole).toBool();
  if (mode_ == "easy") {
    return !mastered;
  }
  if (mode_ == "relics") {
    return !mastered &&
           sourceModel()->data(item, PlayerItemModel::FromRelicsRole).toBool();
  }
  if (mode_ == "platinum") {
    return !mastered &&
           sourceModel()->data(item, PlayerItemModel::BuyableRole).toBool();
  }
  return true;
}
