#include "relic_model.h"

#include <QSet>
#include <QVariantList>
#include <QVariantMap>

#include <ranges>

import wfgui.relic_data;

struct RelicModel::Storage {
  wfgui::RelicData data;
};

namespace {
QString identity(const wfgui::Relic &relic) {
  return relic.id.isEmpty() ? relic.name : relic.id;
}

bool sameRelics(const wfgui::RelicData &current, const wfgui::RelicData &next) {
  if (current.relics.size() != next.relics.size()) {
    return false;
  }
  QSet<QString> identities;
  for (const wfgui::Relic &relic : next.relics) {
    const QString key = identity(relic);
    if (key.isEmpty() || identities.contains(key)) {
      return false;
    }
    identities.insert(key);
  }
  return std::ranges::all_of(current.relics, [&identities](const auto &relic) {
    return identities.contains(identity(relic));
  });
}

void preserveAssetPaths(const wfgui::Relic &current, wfgui::Relic &next) {
  if (current.assetId == next.assetId) {
    next.assetPath = current.assetPath;
  }
  QHash<QString, QString> rewardPaths;
  for (const wfgui::Relic::Reward &reward : current.rewards) {
    if (!reward.assetPath.isEmpty()) {
      rewardPaths.insert(reward.assetId, reward.assetPath);
    }
  }
  for (wfgui::Relic::Reward &reward : next.rewards) {
    reward.assetPath = rewardPaths.value(reward.assetId);
  }
}
} // namespace

RelicModel::RelicModel(QObject *parent)
    : QAbstractListModel(parent), storage_(std::make_unique<Storage>()) {}

RelicModel::~RelicModel() = default;

int RelicModel::rowCount(const QModelIndex &parent) const {
  return parent.isValid() ? 0 : static_cast<int>(storage_->data.relics.size());
}

QVariant RelicModel::data(const QModelIndex &index, int role) const {
  if (!index.isValid() || index.row() < 0 ||
      index.row() >= static_cast<int>(storage_->data.relics.size())) {
    return {};
  }

  const wfgui::Relic &relic =
      storage_->data.relics[static_cast<std::size_t>(index.row())];
  switch (role) {
  case NameRole:
    return relic.name;
  case AmountOwnedRole:
    return relic.amountOwned;
  case VaultedRole:
    return relic.vaulted;
  case FavoriteRole:
    return relic.favorite;
  case HasPriceRole:
    return relic.hasPrice;
  case ExpectedPlatinumRole:
    return relic.expectedPlatinum;
  case ExpectedDucatsRole:
    return relic.expectedDucats;
  case PricesLoadingRole:
    return pricesLoading_;
  case RefinementRole:
    return relic.refinement;
  case RelicImageRole:
    return relic.assetPath;
  case PriceCompleteRole:
    return relic.priceComplete;
  case RefinementsRole: {
    QVariantList refinements;
    refinements.reserve(static_cast<qsizetype>(relic.refinements.size()));
    for (const wfgui::Relic::Refinement &refinement : relic.refinements) {
      refinements.push_back(QVariantMap{
          {"name", refinement.name},
          {"amountOwned", refinement.amountOwned},
          {"expectedPlatinum", refinement.expectedPlatinum},
          {"expectedDucats", refinement.expectedDucats},
          {"hasPrice", refinement.hasPrice},
          {"priceComplete", refinement.priceComplete},
      });
    }
    return refinements;
  }
  case RewardsRole: {
    QVariantList rewards;
    rewards.reserve(static_cast<qsizetype>(relic.rewards.size()));
    for (const wfgui::Relic::Reward &reward : relic.rewards) {
      rewards.push_back(QVariantMap{
          {"name", reward.name},
          {"rarity", reward.rarity},
          {"image", reward.assetPath},
          {"platinum", reward.platinum},
          {"ducats", reward.ducats},
          {"owned", reward.owned},
          {"chance", reward.chance},
          {"hasPrice", reward.hasPrice},
      });
    }
    return rewards;
  }
  default:
    return {};
  }
}

QHash<int, QByteArray> RelicModel::roleNames() const {
  return {
      {NameRole, "name"},
      {AmountOwnedRole, "amountOwned"},
      {VaultedRole, "vaulted"},
      {FavoriteRole, "favorite"},
      {HasPriceRole, "hasPrice"},
      {ExpectedPlatinumRole, "expectedPlatinum"},
      {ExpectedDucatsRole, "expectedDucats"},
      {PricesLoadingRole, "pricesLoading"},
      {RefinementRole, "refinement"},
      {RelicImageRole, "relicImage"},
      {PriceCompleteRole, "priceComplete"},
      {RefinementsRole, "refinements"},
      {RewardsRole, "rewards"},
  };
}

void RelicModel::clear() {
  if (storage_->data.relics.empty() && storage_->data.traceCount == 0) {
    return;
  }
  beginResetModel();
  storage_->data = {};
  endResetModel();
}

void RelicModel::setPricesLoading(bool loading) {
  if (pricesLoading_ == loading) {
    return;
  }
  pricesLoading_ = loading;
  if (rowCount() > 0) {
    emit dataChanged(index(0), index(rowCount() - 1), {PricesLoadingRole});
  }
}

void RelicModel::setAssetPaths(const QHash<QString, QString> &paths) {
  for (int row = 0; row < rowCount(); ++row) {
    wfgui::Relic &relic = storage_->data.relics[static_cast<std::size_t>(row)];
    bool changed = false;
    const QString relicPath = paths.value(relic.assetId);
    if (!relicPath.isEmpty() && relic.assetPath != relicPath) {
      relic.assetPath = relicPath;
      changed = true;
    }
    for (wfgui::Relic::Reward &reward : relic.rewards) {
      const QString rewardPath = paths.value(reward.assetId);
      if (!rewardPath.isEmpty() && reward.assetPath != rewardPath) {
        reward.assetPath = rewardPath;
        changed = true;
      }
    }
    if (changed) {
      emit dataChanged(index(row), index(row), {RelicImageRole, RewardsRole});
    }
  }
}

bool RelicModel::replace(const QJsonObject &data, QString *error) {
  wfgui::RelicData next;
  if (!wfgui::parseRelicData(data, next, error)) {
    return false;
  }

  if (sameRelics(storage_->data, next)) {
    QHash<QString, std::size_t> rows;
    for (std::size_t row = 0; row < next.relics.size(); ++row) {
      rows.insert(identity(next.relics[row]), row);
    }
    for (wfgui::Relic &current : storage_->data.relics) {
      wfgui::Relic updated =
          std::move(next.relics[rows.value(identity(current))]);
      preserveAssetPaths(current, updated);
      current = std::move(updated);
    }
    storage_->data.traceCount = next.traceCount;
    if (rowCount() > 0) {
      emit dataChanged(index(0), index(rowCount() - 1));
    }
    return true;
  }

  beginResetModel();
  storage_->data = std::move(next);
  endResetModel();
  return true;
}

int RelicModel::traceCount() const { return storage_->data.traceCount; }

RelicFilterModel::RelicFilterModel(QObject *parent)
    : QSortFilterProxyModel(parent) {
  setDynamicSortFilter(true);
}

QString RelicFilterModel::filterText() const { return filterText_; }

bool RelicFilterModel::onlyOwned() const { return onlyOwned_; }

QVariant RelicFilterModel::data(const QModelIndex &index, int role) const {
  QVariant value = QSortFilterProxyModel::data(index, role);
  if (!onlyOwned_ || role != RelicModel::RefinementsRole) {
    return value;
  }

  QVariantList owned;
  for (const QVariant &row : value.toList()) {
    if (row.toMap().value("amountOwned").toInt() > 0) {
      owned.push_back(row);
    }
  }
  return owned;
}

void RelicFilterModel::setFilterText(const QString &text) {
  if (filterText_ == text) {
    return;
  }
  beginFilterChange();
  filterText_ = text;
  endFilterChange(QSortFilterProxyModel::Direction::Rows);
  emit filterTextChanged();
}

void RelicFilterModel::setOnlyOwned(bool onlyOwned) {
  if (onlyOwned_ == onlyOwned) {
    return;
  }
  beginFilterChange();
  onlyOwned_ = onlyOwned;
  endFilterChange(QSortFilterProxyModel::Direction::Rows);
  if (rowCount() > 0) {
    emit dataChanged(index(0, 0), index(rowCount() - 1, 0),
                     {RelicModel::RefinementsRole});
  }
  emit onlyOwnedChanged();
}

bool RelicFilterModel::filterAcceptsRow(int sourceRow,
                                        const QModelIndex &sourceParent) const {
  const QModelIndex index = sourceModel()->index(sourceRow, 0, sourceParent);
  if (onlyOwned_ &&
      sourceModel()->data(index, RelicModel::AmountOwnedRole).toInt() <= 0) {
    return false;
  }
  return filterText_.isEmpty() ||
         sourceModel()
             ->data(index, RelicModel::NameRole)
             .toString()
             .contains(filterText_, Qt::CaseInsensitive);
}
