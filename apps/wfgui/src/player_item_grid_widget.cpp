#include "player_item_grid_widget.h"

#include <QAbstractItemView>
#include <QFontMetrics>
#include <QHelpEvent>
#include <QPainter>
#include <QPainterPath>
#include <QResizeEvent>
#include <QScrollBar>
#include <QStyleOptionViewItem>
#include <QStyledItemDelegate>
#include <QTimer>
#include <QToolTip>
#include <QVariantList>
#include <QVariantMap>

#include <algorithm>
#include <utility>

#include "display_metrics.h"
#include "image_cache.h"
#include "player_item_model.h"

namespace {
constexpr int Gap = 8;
constexpr int MaxTrack = 620;
constexpr int InventoryMinTrack = 380;
constexpr int MasteryMinTrack = 370;

QList<QRect> componentRects(const QRect &content, int componentCount,
                            PlayerItemGridWidget::Kind kind, qreal scale) {
  const int count = std::min(4, componentCount);
  const int size = wfgui::scaled(
      kind == PlayerItemGridWidget::Kind::Mastery ? 30 : 34, scale);
  const int gap = wfgui::scaled(5, scale);
  const int start = content.right() - count * (size + gap) + gap;
  const int top = kind == PlayerItemGridWidget::Kind::Mastery
                      ? content.center().y() - size / 2
                      : content.bottom() - size;
  QList<QRect> result;
  result.reserve(count);
  for (int index = 0; index < count; ++index) {
    result.append({start + index * (size + gap), top, size, size});
  }
  return result;
}

QRect contentRect(const QRect &itemRect, PlayerItemGridWidget::Kind kind,
                  qreal scale) {
  const int inset = wfgui::scaled(4, scale);
  const QRect card = itemRect.adjusted(inset, inset, -inset, -inset);
  const int padding = wfgui::scaled(
      kind == PlayerItemGridWidget::Kind::Inventory ? 10 : 8, scale);
  return card.adjusted(padding, padding, -padding, -padding);
}

QRect masteredBadgeRect(const QRect &content, int textLeft, qreal scale) {
  const int size = wfgui::scaled(27, scale);
  return {textLeft + wfgui::scaled(46, scale),
          content.top() + wfgui::scaled(52, scale), size, size};
}

class PlayerItemDelegate final : public QStyledItemDelegate {
public:
  explicit PlayerItemDelegate(PlayerItemGridWidget::Kind kind, QObject *parent)
      : QStyledItemDelegate(parent), kind_(kind) {}

  QSize sizeHint(const QStyleOptionViewItem &,
                 const QModelIndex &) const override {
    const auto *view = qobject_cast<const QListView *>(parent());
    return view ? view->gridSize() : QSize(400, 150);
  }

  void paint(QPainter *painter, const QStyleOptionViewItem &option,
             const QModelIndex &index) const override {
    painter->save();
    painter->setRenderHint(QPainter::Antialiasing);
    painter->setRenderHint(QPainter::SmoothPixmapTransform);
    const qreal scale =
        wfgui::displayScale(qobject_cast<const QWidget *>(parent()));
    const int inset = wfgui::scaled(4, scale);
    const QRect card = option.rect.adjusted(inset, inset, -inset, -inset);
    painter->setPen(Qt::NoPen);
    painter->setBrush(option.state & QStyle::State_MouseOver
                          ? QColor("#272f47")
                          : QColor("#20283e"));
    painter->drawRoundedRect(card, wfgui::scaled(12, scale),
                             wfgui::scaled(12, scale));

    const QRect content = contentRect(option.rect, kind_, scale);
    const int imageSize = wfgui::scaled(
        kind_ == PlayerItemGridWidget::Kind::Mastery ? 76 : 88, scale);
    const QRect imageRect(content.left(), content.top(), imageSize, imageSize);
    wfgui::drawContained(
        *painter, imageRect,
        wfgui::cachedThumbnail(
            *painter, index.data(PlayerItemModel::AssetPathRole).toString(),
            imageRect.size()));

    QVariantList components =
        index.data(PlayerItemModel::ComponentsRole).toList();
    if (kind_ == PlayerItemGridWidget::Kind::Mastery &&
        index.data(PlayerItemModel::OwnedRole).toBool()) {
      components.clear();
    }
    const QList<QRect> componentsLayout = componentRects(
        content, static_cast<int>(components.size()), kind_, scale);
    const int textLeft = imageRect.right() + wfgui::scaled(12, scale);
    const int textRight =
        kind_ == PlayerItemGridWidget::Kind::Mastery &&
                !componentsLayout.empty()
            ? componentsLayout.front().left() - wfgui::scaled(8, scale)
            : content.right();
    QFont titleFont = option.font;
    titleFont.setPointSizeF(13.5 * scale);
    titleFont.setWeight(QFont::DemiBold);
    painter->setFont(titleFont);
    painter->setPen(QColor("#ffffff"));
    painter->drawText(QRect(textLeft, content.top(), textRight - textLeft,
                            wfgui::scaled(26, scale)),
                      Qt::AlignLeft | Qt::AlignVCenter,
                      QFontMetrics(titleFont).elidedText(
                          index.data(PlayerItemModel::NameRole).toString(),
                          Qt::ElideRight, textRight - textLeft));

    QFont detailFont = option.font;
    detailFont.setPointSizeF(10.5 * scale);
    painter->setFont(detailFont);
    painter->setPen(QColor("#aeb5c7"));
    if (kind_ == PlayerItemGridWidget::Kind::Inventory) {
      painter->drawText(QRect(textLeft,
                              content.top() + wfgui::scaled(27, scale),
                              textRight - textLeft, wfgui::scaled(22, scale)),
                        Qt::AlignLeft | Qt::AlignVCenter,
                        index.data(PlayerItemModel::CategoryRole).toString());
      paintInventory(*painter, content, textLeft, index, detailFont, scale);
    } else {
      paintMastery(*painter, content, imageRect, textLeft, index, detailFont,
                   scale);
    }
    painter->restore();
  }

  bool helpEvent(QHelpEvent *event, QAbstractItemView *view,
                 const QStyleOptionViewItem &option,
                 const QModelIndex &index) override {
    if (event->type() == QEvent::ToolTip) {
      const qreal scale = wfgui::displayScale(view);
      const QRect content = contentRect(option.rect, kind_, scale);
      const int imageSize = wfgui::scaled(
          kind_ == PlayerItemGridWidget::Kind::Mastery ? 76 : 88, scale);
      const int textLeft =
          content.left() + imageSize + wfgui::scaled(12, scale);
      if (kind_ == PlayerItemGridWidget::Kind::Inventory &&
          index.data(PlayerItemModel::MasteredRole).toBool()) {
        const QRect badge = masteredBadgeRect(content, textLeft, scale);
        if (badge.contains(event->pos())) {
          QToolTip::showText(event->globalPos(), "Item owned/mastered",
                             view->viewport(), badge);
          return true;
        }
      }
      QVariantList components =
          index.data(PlayerItemModel::ComponentsRole).toList();
      if (kind_ == PlayerItemGridWidget::Kind::Mastery &&
          index.data(PlayerItemModel::OwnedRole).toBool()) {
        components.clear();
      }
      const QList<QRect> rects = componentRects(
          content, static_cast<int>(components.size()), kind_, scale);
      for (int componentIndex = 0; componentIndex < rects.size();
           ++componentIndex) {
        if (!rects.at(componentIndex).contains(event->pos())) {
          continue;
        }
        const QVariantMap component = components.at(componentIndex).toMap();
        QString text = component.value("name").toString();
        const int required = component.value("required").toInt();
        if (required > 0) {
          text += QString("\nOwned: %1/%2")
                      .arg(component.value("owned").toInt())
                      .arg(required);
        }
        QToolTip::showText(event->globalPos(), text, view->viewport(),
                           rects.at(componentIndex));
        return true;
      }
    }
    return QStyledItemDelegate::helpEvent(event, view, option, index);
  }

private:
  static void paintInventory(QPainter &painter, const QRect &content,
                             int textLeft, const QModelIndex &index,
                             const QFont &font, qreal scale) {
    painter.setFont(font);
    painter.setPen(QColor("#ffffff"));
    painter.drawText(
        QRect(textLeft, content.top() + wfgui::scaled(54, scale),
              wfgui::scaled(100, scale), wfgui::scaled(24, scale)),
        Qt::AlignLeft | Qt::AlignVCenter,
        QString("x%1").arg(index.data(PlayerItemModel::QuantityRole).toInt()));
    const int ducats = index.data(PlayerItemModel::DucatsRole).toInt();
    const bool tradable = index.data(PlayerItemModel::TradableRole).toBool();
    const int platinumWidth = tradable ? wfgui::scaled(64, scale) : 0;
    const int ducatWidth = ducats > 0 ? wfgui::scaled(58, scale) : 0;
    int coinLeft =
        content.right() - platinumWidth - ducatWidth -
        (platinumWidth > 0 && ducatWidth > 0 ? wfgui::scaled(8, scale) : 0) + 1;
    const int coinTop = content.top() + wfgui::scaled(52, scale);
    if (tradable) {
      const int iconSize = wfgui::scaled(22, scale);
      const QRect icon(coinLeft, coinTop, iconSize, iconSize);
      wfgui::drawContained(painter, icon,
                           wfgui::cachedThumbnail(
                               painter, ":/assets/platinum.png", icon.size()));
      const QString state =
          index.data(PlayerItemModel::PriceStateRole).toString();
      const QString value =
          state == "ready"
              ? index.data(PlayerItemModel::PlatinumRole).toString()
              : (state == "loading" ? "..." : "--");
      painter.drawText(QRect(icon.right() + wfgui::scaled(3, scale), icon.top(),
                             wfgui::scaled(38, scale), icon.height()),
                       Qt::AlignLeft | Qt::AlignVCenter, value);
      coinLeft +=
          platinumWidth + (ducatWidth > 0 ? wfgui::scaled(8, scale) : 0);
    }
    if (ducats > 0) {
      const int iconSize = wfgui::scaled(22, scale);
      const QRect icon(coinLeft, coinTop, iconSize, iconSize);
      wfgui::drawContained(
          painter, icon,
          wfgui::cachedThumbnail(painter, ":/assets/ducats.png", icon.size()));
      painter.drawText(QRect(icon.right() + wfgui::scaled(3, scale), icon.top(),
                             wfgui::scaled(32, scale), icon.height()),
                       Qt::AlignLeft | Qt::AlignVCenter,
                       QString::number(ducats));
    }
    if (index.data(PlayerItemModel::MasteredRole).toBool()) {
      const QRect badge = masteredBadgeRect(content, textLeft, scale);
      const int markSize = qRound(badge.width() * 0.74);
      const QRect mark(badge.center().x() - markSize / 2,
                       badge.center().y() - markSize / 2, markSize, markSize);
      painter.setPen(Qt::NoPen);
      painter.setBrush(QColor("#3bb54a"));
      painter.drawEllipse(mark);
      QPen check(QColor("#d4e1f4"), std::max(1.5, 2.0 * scale));
      check.setCapStyle(Qt::RoundCap);
      check.setJoinStyle(Qt::RoundJoin);
      painter.setPen(check);
      QPainterPath path;
      path.moveTo(mark.left() + mark.width() * 0.24,
                  mark.top() + mark.height() * 0.51);
      path.lineTo(mark.left() + mark.width() * 0.43,
                  mark.top() + mark.height() * 0.69);
      path.lineTo(mark.left() + mark.width() * 0.76,
                  mark.top() + mark.height() * 0.31);
      painter.drawPath(path);
    }
    paintComponents(painter, content,
                    index.data(PlayerItemModel::ComponentsRole).toList(),
                    PlayerItemGridWidget::Kind::Inventory, scale);
  }

  static void paintMastery(QPainter &painter, const QRect &content,
                           const QRect &imageRect, int textLeft,
                           const QModelIndex &index, const QFont &font,
                           qreal scale) {
    painter.setFont(font);
    painter.setPen(QColor("#ffffff"));
    const bool owned = index.data(PlayerItemModel::OwnedRole).toBool();
    const bool pending = index.data(PlayerItemModel::PendingRole).toBool();
    const QVariantList components =
        index.data(PlayerItemModel::ComponentsRole).toList();
    const QString status =
        owned
            ? QString("Level %1/%2")
                  .arg(index.data(PlayerItemModel::RankRole).toInt())
                  .arg(index.data(PlayerItemModel::MaxRankRole).toInt())
            : (pending
                   ? QString("Building")
                   : (components.isEmpty()
                          ? QString("Not owned")
                          : QString("%1 parts missing")
                                .arg(
                                    index
                                        .data(PlayerItemModel::MissingPartsRole)
                                        .toInt())));
    const QList<QRect> componentLayout =
        componentRects(content, owned ? 0 : static_cast<int>(components.size()),
                       PlayerItemGridWidget::Kind::Mastery, scale);
    const int statusRight =
        componentLayout.empty()
            ? content.right()
            : componentLayout.front().left() - wfgui::scaled(8, scale);
    painter.drawText(QRect(textLeft, content.top() + wfgui::scaled(32, scale),
                           statusRight - textLeft, wfgui::scaled(22, scale)),
                     Qt::AlignLeft | Qt::AlignVCenter, status);

    const int xpHeight = wfgui::scaled(21, scale);
    const QRect xpBadge(imageRect.left(), imageRect.bottom() - xpHeight + 1,
                        imageRect.width(), xpHeight);
    painter.setPen(Qt::NoPen);
    painter.setBrush(QColor(0, 0, 0, 0x8a));
    painter.drawRoundedRect(xpBadge, wfgui::scaled(5, scale),
                            wfgui::scaled(5, scale));
    painter.setPen(QColor("#ffffff"));
    painter.drawText(xpBadge, Qt::AlignCenter,
                     QString("+%1 XP").arg(
                         index.data(PlayerItemModel::PotentialXpRole).toInt()));

    if (!owned) {
      paintComponents(painter, content, components,
                      PlayerItemGridWidget::Kind::Mastery, scale);
    }
  }

  static void paintComponents(QPainter &painter, const QRect &content,
                              const QVariantList &components,
                              PlayerItemGridWidget::Kind kind, qreal scale) {
    const QList<QRect> rects = componentRects(
        content, static_cast<int>(components.size()), kind, scale);
    for (int componentIndex = 0; componentIndex < rects.size();
         ++componentIndex) {
      const QVariantMap component = components.at(componentIndex).toMap();
      const QRect &circle = rects.at(componentIndex);
      painter.setBrush(QColor(255, 255, 255, 0x12));
      const bool enough = component.value("owned").toInt() >=
                          component.value("required").toInt();
      painter.setPen(QPen(enough ? QColor("#46d234") : QColor("#566078"),
                          wfgui::scaled(enough ? 2 : 1, scale)));
      painter.drawEllipse(circle);
      painter.save();
      QPainterPath clip;
      clip.addEllipse(circle.adjusted(2, 2, -2, -2));
      painter.setClipPath(clip);
      const QRect imageRect = circle.adjusted(2, 2, -2, -2);
      wfgui::drawContained(
          painter, imageRect,
          wfgui::cachedThumbnail(painter, component.value("image").toString(),
                                 imageRect.size()));
      painter.restore();
    }
  }

  PlayerItemGridWidget::Kind kind_;
};
} // namespace

PlayerItemGridWidget::PlayerItemGridWidget(Kind kind, QWidget *parent)
    : QListView(parent), kind_(kind), visibleDataTimer_(new QTimer(this)) {
  setObjectName("playerItemGrid");
  setItemDelegate(new PlayerItemDelegate(kind, this));
  setViewMode(QListView::IconMode);
  setFlow(QListView::LeftToRight);
  setWrapping(true);
  setResizeMode(QListView::Adjust);
  setLayoutMode(QListView::Batched);
  setBatchSize(64);
  setUniformItemSizes(true);
  setMouseTracking(true);
  setSelectionMode(QAbstractItemView::NoSelection);
  setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
  setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOn);
  setVerticalScrollMode(QAbstractItemView::ScrollPerPixel);
  setSpacing(0);
  visibleDataTimer_->setInterval(50);
  visibleDataTimer_->setSingleShot(true);
  connect(visibleDataTimer_, &QTimer::timeout, this,
          &PlayerItemGridWidget::requestVisibleData);
  connect(verticalScrollBar(), &QScrollBar::valueChanged, this,
          [this] { scheduleVisibleData(); });
}

void PlayerItemGridWidget::setModel(QAbstractItemModel *itemModel) {
  QListView::setModel(itemModel);
  if (itemModel) {
    const auto request = [this] { scheduleVisibleData(); };
    connect(itemModel, &QAbstractItemModel::modelReset, this, request);
    connect(itemModel, &QAbstractItemModel::rowsInserted, this, request);
    connect(itemModel, &QAbstractItemModel::layoutChanged, this, request);
  }
}

void PlayerItemGridWidget::resizeEvent(QResizeEvent *event) {
  QListView::resizeEvent(event);
  updateGrid();
}

void PlayerItemGridWidget::updateGrid() {
  const qreal scale = wfgui::displayScale(this);
  const int width = std::max(1, viewport()->width());
  const int gap = wfgui::scaled(Gap, scale);
  const int minimumTrack = wfgui::scaled(
      kind_ == Kind::Inventory ? InventoryMinTrack : MasteryMinTrack, scale);
  const int columns = std::max(1, (width + gap) / (minimumTrack + gap));
  const int track =
      std::min(wfgui::scaled(MaxTrack, scale),
               std::max(1, (width - 1 - columns * gap) / columns));
  const int height = wfgui::scaled(kind_ == Kind::Mastery ? 104 : 142, scale);
  setGridSize({track + gap, height + gap});
  scheduleDelayedItemsLayout();
  scheduleVisibleData();
}

void PlayerItemGridWidget::refreshVisibleQuotes() {
  requestVisibleQuotes(true);
}

void PlayerItemGridWidget::scheduleVisibleData() { visibleDataTimer_->start(); }

void PlayerItemGridWidget::requestVisibleData() {
  requestVisibleAssets();
  requestVisibleQuotes();
}

void PlayerItemGridWidget::requestVisibleAssets() {
  if (!model() || gridSize().height() <= 0 || gridSize().width() <= 0) {
    return;
  }
  QJsonArray assets;
  const auto [first, last] = visibleRows();
  for (int row = first; row <= last; ++row) {
    const QModelIndex item = model()->index(row, 0);
    const QVariantMap asset = item.data(PlayerItemModel::AssetSpecRole).toMap();
    if (!asset.value("id").toString().isEmpty()) {
      assets.append(QJsonObject::fromVariantMap(asset));
    }
    for (const QVariant &value :
         item.data(PlayerItemModel::ComponentsRole).toList()) {
      const QVariantMap componentAsset = value.toMap().value("asset").toMap();
      if (!componentAsset.value("id").toString().isEmpty()) {
        assets.append(QJsonObject::fromVariantMap(componentAsset));
      }
    }
  }
  if (!assets.isEmpty()) {
    emit assetsNeeded(assets);
  }
}

void PlayerItemGridWidget::requestVisibleQuotes(bool refresh) {
  if (kind_ != Kind::Inventory || !model()) {
    return;
  }
  const auto [first, last] = visibleRows();
  QStringList items;
  for (int row = first; row <= last; ++row) {
    const QModelIndex item = model()->index(row, 0);
    if (item.data(PlayerItemModel::TradableRole).toBool()) {
      items.append(item.data(PlayerItemModel::NameRole).toString());
    }
  }
  items.removeDuplicates();
  if (!items.isEmpty()) {
    emit quotesNeeded(items, refresh);
  }
}

std::pair<int, int> PlayerItemGridWidget::visibleRows() const {
  if (!model() || gridSize().height() <= 0 || gridSize().width() <= 0) {
    return {0, -1};
  }
  const int columns = std::max(1, viewport()->width() / gridSize().width());
  const int firstLine =
      std::max(0, verticalScrollBar()->value() / gridSize().height() - 1);
  const int lastLine = (verticalScrollBar()->value() + viewport()->height()) /
                           gridSize().height() +
                       1;
  return {firstLine * columns,
          std::min(model()->rowCount() - 1, (lastLine + 1) * columns - 1)};
}
