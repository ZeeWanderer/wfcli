#include <QImage>
#include <QJsonArray>
#include <QJsonObject>
#include <QPainter>
#include <QTemporaryDir>
#include <QtTest>

#include <utility>

#include "image_cache.h"
#include "player_item_grid_widget.h"
#include "player_item_model.h"
#include "relic_card_layout.h"
#include "relic_grid_widget.h"
#include "relic_model.h"

class RelicModelTest final : public QObject {
  Q_OBJECT

private slots:
  void parsesRecommendations();
  void appliesResolvedAssets();
  void priceUpdatesPreserveRows();
  void filtersByName();
  void filtersRelicsByOwnershipLocally();
  void filtersRelicsByEraLocally();
  void filtersPlayerItemsLocally();
  void appliesInventoryMarketQuotes();
  void invalidatesCachedComponentAssets();
  void rejectsMalformedPayload();
  void cardLayoutUsesConstraints();
  void gridLayoutUsesStableBreakpoints();
  void playerGridUsesAvailableColumns();
  void masteryGridUsesCompactCards();
  void inventoryGridRequestsVisibleQuotes();
  void ownershipFilterKeepsVisibleCardsStable();
  void thumbnailCacheRespectsSizeAndDpr();
  void widgetThumbnailDecodeCompletesOffPaintPath();
};

namespace {
class HideCounter final : public QObject {
public:
  int count = 0;

protected:
  bool eventFilter(QObject *, QEvent *event) override {
    if (event->type() == QEvent::Hide) {
      ++count;
    }
    return false;
  }
};

class ThumbnailProbe final : public QWidget {
public:
  explicit ThumbnailProbe(QString path) : path_(std::move(path)) {}

  const QPixmap &thumbnail() const { return thumbnail_; }

protected:
  void paintEvent(QPaintEvent *) override {
    QPainter painter(this);
    thumbnail_ = wfgui::cachedThumbnail(painter, path_, QSize(20, 20));
  }

private:
  QString path_;
  QPixmap thumbnail_;
};

QJsonObject recommendations() {
  return {
      {"trace_count", 1842},
      {"items",
       QJsonArray{
           QJsonObject{
               {"name", "Axi A1 Intact"},
               {"era", "axi"},
               {"id", "relic-group:Axi A1 Relic"},
               {"amount_owned", 2},
               {"vaulted", false},
               {"favorite", true},
               {"asset", QJsonObject{{"id", "relic:axi-a1"}}},
               {"expected_platinum", 19},
               {"expected_ducats", 95},
               {"price_complete", true},
               {"refinements",
                QJsonArray{QJsonObject{{"refinement", "Intact"},
                                       {"amount_owned", 2},
                                       {"expected_platinum", 19},
                                       {"expected_ducats", 95},
                                       {"price_complete", true}},
                           QJsonObject{{"refinement", "Radiant"},
                                       {"amount_owned", 0},
                                       {"expected_platinum", 31},
                                       {"expected_ducats", 112},
                                       {"price_complete", true}}}},
               {"rewards",
                QJsonArray{QJsonObject{
                    {"name", "Saryn Prime Chassis"},
                    {"rarity", "Rare"},
                    {"platinum", 42},
                    {"ducats", 100},
                    {"owned", 1},
                    {"chance", 2.0},
                    {"asset", QJsonObject{{"id", "market:saryn_chassis"}}}}}}},
           QJsonObject{{"name", "Lith B1 Intact"},
                       {"era", "lith"},
                       {"amount_owned", 1},
                       {"vaulted", true},
                       {"favorite", false},
                       {"expected_platinum", QJsonValue(QJsonValue::Null)},
                       {"expected_ducats", 70}},
       }},
  };
}
} // namespace

void RelicModelTest::parsesRecommendations() {
  RelicModel model;
  QString error;

  QVERIFY(model.replace(recommendations(), &error));
  QVERIFY(error.isEmpty());
  QCOMPARE(model.rowCount(), 2);
  QCOMPARE(model.traceCount(), 1842);

  const QModelIndex first = model.index(0);
  QCOMPARE(model.data(first, RelicModel::NameRole).toString(),
           QString("Axi A1 Intact"));
  QCOMPARE(model.data(first, RelicModel::AmountOwnedRole).toInt(), 2);
  QCOMPARE(model.data(first, RelicModel::HasPriceRole).toBool(), true);
  QCOMPARE(model.data(first, RelicModel::RefinementsRole).toList().size(), 2);
  QCOMPARE(model.data(first, RelicModel::RewardsRole).toList().size(), 1);

  const QModelIndex second = model.index(1);
  QCOMPARE(model.data(second, RelicModel::VaultedRole).toBool(), true);
  QCOMPARE(model.data(second, RelicModel::HasPriceRole).toBool(), false);
}

void RelicModelTest::appliesResolvedAssets() {
  RelicModel model;
  QVERIFY(model.replace(recommendations()));
  model.setAssetPaths({{"relic:axi-a1", "/tmp/relic.png"},
                       {"market:saryn_chassis", "/tmp/reward.png"}});

  const QModelIndex first = model.index(0);
  QCOMPARE(model.data(first, RelicModel::RelicImageRole).toString(),
           QString("/tmp/relic.png"));
  const QVariantMap reward =
      model.data(first, RelicModel::RewardsRole).toList().front().toMap();
  QCOMPARE(reward.value("image").toString(), QString("/tmp/reward.png"));
}

void RelicModelTest::priceUpdatesPreserveRows() {
  RelicModel model;
  QVERIFY(model.replace(recommendations()));
  QSignalSpy resets(&model, &QAbstractItemModel::modelReset);
  QSignalSpy changes(&model, &QAbstractItemModel::dataChanged);

  QJsonObject priced = recommendations();
  QJsonArray items = priced.value("items").toArray();
  QJsonObject first = items.at(0).toObject();
  first.insert("expected_platinum", 50);
  priced.insert("items", QJsonArray{items.at(1), first});

  QVERIFY(model.replace(priced));
  QCOMPARE(resets.count(), 0);
  QCOMPARE(changes.count(), 1);
  QCOMPARE(model.data(model.index(0), RelicModel::NameRole).toString(),
           QString("Axi A1 Intact"));
  QCOMPARE(model.data(model.index(0), RelicModel::ExpectedPlatinumRole).toInt(),
           50);
}

void RelicModelTest::filtersByName() {
  RelicModel model;
  QVERIFY(model.replace(recommendations()));
  RelicFilterModel filter;
  filter.setSourceModel(&model);

  filter.setFilterText("b1");
  QCOMPARE(filter.rowCount(), 1);
  QCOMPARE(filter.data(filter.index(0, 0), RelicModel::NameRole).toString(),
           QString("Lith B1 Intact"));
}

void RelicModelTest::filtersRelicsByOwnershipLocally() {
  RelicModel model;
  QVERIFY(model.replace(recommendations()));
  QJsonObject data = recommendations();
  QJsonArray items = data.value("items").toArray();
  QJsonObject unowned = items.at(1).toObject();
  unowned.insert("amount_owned", 0);
  items.replace(1, unowned);
  data.insert("items", items);
  QVERIFY(model.replace(data));

  RelicFilterModel filter;
  filter.setSourceModel(&model);
  QCOMPARE(filter.rowCount(), 1);
  const QVariantList ownedRefinements =
      filter.data(filter.index(0, 0), RelicModel::RefinementsRole).toList();
  QCOMPARE(ownedRefinements.size(), 1);
  QCOMPARE(ownedRefinements.front().toMap().value("name").toString(),
           QString("Intact"));
  filter.setOnlyOwned(false);
  QCOMPARE(filter.rowCount(), 2);
  QCOMPARE(filter.data(filter.index(0, 0), RelicModel::RefinementsRole)
               .toList()
               .size(),
           2);
}

void RelicModelTest::filtersRelicsByEraLocally() {
  RelicModel model;
  QVERIFY(model.replace(recommendations()));
  RelicFilterModel filter;
  filter.setSourceModel(&model);

  filter.setEra("lith");
  QCOMPARE(filter.rowCount(), 1);
  QCOMPARE(filter.data(filter.index(0, 0), RelicModel::NameRole).toString(),
           QString("Lith B1 Intact"));
  filter.setEra("all");
  QCOMPARE(filter.rowCount(), 2);
}

void RelicModelTest::filtersPlayerItemsLocally() {
  PlayerItemModel model;
  QVERIFY(model.replace({
      {"items",
       QJsonArray{
           QJsonObject{{"id", "frame"},
                       {"name", "Test Prime"},
                       {"group", "warframes"},
                       {"mastered", false},
                       {"from_relics", true},
                       {"buyable", true}},
           QJsonObject{{"id", "weapon"},
                       {"name", "Test Rifle"},
                       {"group", "weapons"},
                       {"mastered", true},
                       {"from_relics", false},
                       {"buyable", false}},
       }},
  }));
  PlayerItemFilterModel filter;
  filter.setSourceModel(&model);
  filter.setMode("easy");
  QCOMPARE(filter.rowCount(), 1);
  filter.setMode("relics");
  QCOMPARE(filter.rowCount(), 1);
  filter.setGroup("weapons");
  QCOMPARE(filter.rowCount(), 0);
}

void RelicModelTest::appliesInventoryMarketQuotes() {
  PlayerItemModel model;
  QVERIFY(model.replace({
      {"items", QJsonArray{QJsonObject{{"id", "part"},
                                       {"name", "Saryn Prime Chassis"},
                                       {"group", "parts"},
                                       {"tradable", true}}}},
  }));
  const QModelIndex item = model.index(0);
  QCOMPARE(model.data(item, PlayerItemModel::PriceStateRole).toString(),
           QString("loading"));
  QSignalSpy changes(&model, &QAbstractItemModel::dataChanged);

  model.applyMarketQuotes(QJsonArray{QJsonObject{
                              {"item", "Saryn Prime Chassis"},
                              {"slug", "saryn_prime_chassis"},
                              {"quote", QJsonObject{{"lowest_sell", 17},
                                                     {"highest_buy", 14}}},
                          }},
                          {});
  QCOMPARE(model.data(item, PlayerItemModel::PlatinumRole).toInt(), 17);
  QCOMPARE(model.data(item, PlayerItemModel::BuyPlatinumRole).toInt(), 14);
  QCOMPARE(model.data(item, PlayerItemModel::PriceStateRole).toString(),
           QString("ready"));
  QCOMPARE(changes.count(), 1);

  model.markMarketUnavailable({"Saryn Prime Chassis"});
  QCOMPARE(model.data(item, PlayerItemModel::PriceStateRole).toString(),
           QString("ready"));
}

void RelicModelTest::invalidatesCachedComponentAssets() {
  PlayerItemModel model;
  QVERIFY(model.replace({
      {"items",
       QJsonArray{QJsonObject{
           {"id", "set"},
           {"name", "Test Set"},
           {"components",
            QJsonArray{QJsonObject{{"name", "Test Part"},
                                   {"asset", QJsonObject{{"id", "part"}}}}}},
       }}},
  }));
  const QModelIndex item = model.index(0);

  model.setAssetPaths({{"part", "/tmp/first.png"}});
  QCOMPARE(model.data(item, PlayerItemModel::ComponentsRole)
               .toList()
               .front()
               .toMap()
               .value("image")
               .toString(),
           QString("/tmp/first.png"));

  model.setAssetPaths({{"part", "/tmp/second.png"}});
  QCOMPARE(model.data(item, PlayerItemModel::ComponentsRole)
               .toList()
               .front()
               .toMap()
               .value("image")
               .toString(),
           QString("/tmp/second.png"));

  model.setAssetPaths({});
  QVERIFY(model.data(item, PlayerItemModel::ComponentsRole)
              .toList()
              .front()
              .toMap()
              .value("image")
              .toString()
              .isEmpty());
}

void RelicModelTest::rejectsMalformedPayload() {
  RelicModel model;
  QString error;
  QVERIFY(!model.replace({{"trace_count", 10}}, &error));
  QVERIFY(!error.isEmpty());
  QCOMPARE(model.rowCount(), 0);
}

void RelicModelTest::cardLayoutUsesConstraints() {
  const auto narrow = wfgui::RelicCardLayout::calculate({0, 0, 420, 108}, 4, 6);
  const auto wide = wfgui::RelicCardLayout::calculate({0, 0, 620, 108}, 4, 6);
  const auto dense =
      wfgui::RelicCardLayout::calculate({0, 0, 472, 122}, 4, 6, 1.125);

  QCOMPARE(narrow.image.width(), 80);
  QCOMPARE(wide.image.width(), 80);
  QCOMPARE(narrow.rewards.width(), 127);
  QCOMPARE(wide.rewards.width(), 127);
  QCOMPARE(narrow.middle.width(), 173);
  QCOMPARE(wide.middle.width(), 220);
  QCOMPARE(narrow.refinementRows.size(), 4);
  QCOMPARE(narrow.rewardCells.size(), 6);
  QCOMPARE(narrow.rewardCells.front().size(), QSize(37, 37));
  QCOMPARE(dense.image.width(), 90);
  QCOMPARE(dense.rewardCells.front().size(), QSize(42, 42));
  QVERIFY(narrow.image.right() < narrow.middle.left());
  QVERIFY(narrow.middle.right() < narrow.rewards.left());
  QVERIFY(wide.image.left() > narrow.image.left());
  QCOMPARE(narrow.platinumHeader.center().x(),
           narrow.refinementRows.front().platinum.center().x());
  QCOMPARE(narrow.ducatHeader.center().x(),
           narrow.refinementRows.front().ducats.center().x());
  QVERIFY(wide.title.width() > narrow.title.width());
}

void RelicModelTest::gridLayoutUsesStableBreakpoints() {
  QCOMPARE(wfgui::relicGridColumns(399), 1);
  QCOMPARE(wfgui::relicGridColumns(1000), 2);
  QCOMPARE(wfgui::relicGridColumns(1900), 4);
  QCOMPARE(wfgui::relicGridColumns(2280), 4);
  QCOMPARE(wfgui::relicGridColumns(2700), 5);
  QCOMPARE(wfgui::relicGridColumns(2280, 1.125), 4);
}

void RelicModelTest::playerGridUsesAvailableColumns() {
  QJsonArray items;
  for (int row = 0; row < 12; ++row) {
    items.append(QJsonObject{{"id", QString("item-%1").arg(row)},
                             {"name", QString("Item %1").arg(row)},
                             {"group", "parts"}});
  }
  PlayerItemModel model;
  QVERIFY(model.replace({{"items", items}}));

  PlayerItemGridWidget grid(PlayerItemGridWidget::Kind::Inventory);
  grid.setModel(&model);
  grid.resize(2296, 800);
  grid.show();
  QCoreApplication::processEvents();

  QVERIFY(grid.gridSize().width() > 0);
  const int columns = grid.viewport()->width() / grid.gridSize().width();
  QVERIFY(columns >= 5);
  QTRY_COMPARE(grid.visualRect(model.index(columns - 1)).y(),
               grid.visualRect(model.index(0)).y());
  QTRY_VERIFY(grid.visualRect(model.index(columns)).y() >
              grid.visualRect(model.index(0)).y());
}

void RelicModelTest::masteryGridUsesCompactCards() {
  PlayerItemModel model;
  QVERIFY(model.replace({
      {"items",
       QJsonArray{QJsonObject{
           {"id", "frame"}, {"name", "Test Prime"}, {"group", "warframes"}}}},
  }));

  PlayerItemGridWidget grid(PlayerItemGridWidget::Kind::Mastery);
  grid.setModel(&model);
  grid.resize(800, 600);
  grid.show();
  QCoreApplication::processEvents();

  QCOMPARE(grid.gridSize().height(), 99);
}

void RelicModelTest::inventoryGridRequestsVisibleQuotes() {
  PlayerItemModel model;
  QVERIFY(model.replace({
      {"items", QJsonArray{QJsonObject{{"id", "part"},
                                       {"name", "Saryn Prime Chassis"},
                                       {"group", "parts"},
                                       {"tradable", true}},
                           QJsonObject{{"id", "resource"},
                                       {"name", "Ferrite"},
                                       {"group", "misc"},
                                       {"tradable", false}}}},
  }));
  PlayerItemGridWidget grid(PlayerItemGridWidget::Kind::Inventory);
  QSignalSpy quotes(&grid, &PlayerItemGridWidget::quotesNeeded);
  grid.setModel(&model);
  grid.resize(800, 600);
  grid.show();
  QCoreApplication::processEvents();

  QTRY_VERIFY(!quotes.isEmpty());
  const QList<QVariant> initial = quotes.takeLast();
  QCOMPARE(initial.at(0).toStringList(), QStringList{"Saryn Prime Chassis"});
  QCOMPARE(initial.at(1).toBool(), false);

  quotes.clear();
  grid.refreshVisibleQuotes();
  QCOMPARE(quotes.count(), 1);
  QCOMPARE(quotes.takeFirst().at(1).toBool(), true);
}

void RelicModelTest::ownershipFilterKeepsVisibleCardsStable() {
  QJsonObject data = recommendations();
  QJsonArray items = data.value("items").toArray();
  QJsonObject unowned = items.at(1).toObject();
  unowned.insert("amount_owned", 0);
  items.replace(1, unowned);
  data.insert("items", items);

  RelicModel model;
  QVERIFY(model.replace(data));
  RelicFilterModel filter;
  filter.setSourceModel(&model);
  RelicGridWidget grid;
  grid.setModel(&filter);
  grid.resize(900, 500);
  grid.show();
  QCoreApplication::processEvents();

  const auto initial = grid.findChildren<QWidget *>("relicCardCanvas",
                                                    Qt::FindDirectChildrenOnly);
  QCOMPARE(initial.size(), 1);
  HideCounter hides;
  initial.front()->installEventFilter(&hides);

  filter.setOnlyOwned(false);
  QTRY_COMPARE(filter.rowCount(), 2);
  QTRY_COMPARE(grid.findChildren<QWidget *>("relicCardCanvas",
                                            Qt::FindDirectChildrenOnly)
                   .size(),
               2);
  QCOMPARE(hides.count, 0);
}

void RelicModelTest::thumbnailCacheRespectsSizeAndDpr() {
  QTemporaryDir directory;
  QVERIFY(directory.isValid());
  const QString path = directory.filePath("asset.png");
  QImage source(80, 40, QImage::Format_ARGB32_Premultiplied);
  source.fill(Qt::red);
  QVERIFY(source.save(path));

  QImage target(64, 64, QImage::Format_ARGB32_Premultiplied);
  QPainter painter(&target);
  const QPixmap first = wfgui::cachedThumbnail(painter, path, QSize(20, 20));
  const QPixmap cached = wfgui::cachedThumbnail(painter, path, QSize(20, 20));
  QCOMPARE(first.size(), QSize(20, 10));
  QCOMPARE(first.deviceIndependentSize(), QSizeF(20, 10));
  QCOMPARE(cached.cacheKey(), first.cacheKey());

  QImage highDpiTarget(128, 128, QImage::Format_ARGB32_Premultiplied);
  highDpiTarget.setDevicePixelRatio(2.0);
  QPainter highDpiPainter(&highDpiTarget);
  const QPixmap highDpi =
      wfgui::cachedThumbnail(highDpiPainter, path, QSize(20, 20));
  QCOMPARE(highDpi.size(), QSize(40, 20));
  QCOMPARE(highDpi.deviceIndependentSize(), QSizeF(20, 10));
  QCOMPARE(highDpi.devicePixelRatio(), 2.0);
  QVERIFY(highDpi.cacheKey() != first.cacheKey());
}

void RelicModelTest::widgetThumbnailDecodeCompletesOffPaintPath() {
  QTemporaryDir directory;
  QVERIFY(directory.isValid());
  const QString path = directory.filePath("async-asset.png");
  QImage source(80, 40, QImage::Format_ARGB32_Premultiplied);
  source.fill(Qt::green);
  QVERIFY(source.save(path));

  ThumbnailProbe probe(path);
  probe.resize(32, 32);
  probe.show();
  QTRY_VERIFY_WITH_TIMEOUT(!probe.thumbnail().isNull(), 2000);
  QCOMPARE(probe.thumbnail().deviceIndependentSize(), QSizeF(20, 10));
}

QTEST_MAIN(RelicModelTest)

#include "relic_model_test.moc"
