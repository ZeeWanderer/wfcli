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
constexpr int FoundryMinTrack = 270;
constexpr int InventoryMinTrack = 420;
constexpr int MasteryMinTrack = 370;

QList<QRect> componentRects(const QRect &content, int componentCount,
                            PlayerItemGridWidget::Kind kind, qreal scale) {
  const int count = std::min(
      kind == PlayerItemGridWidget::Kind::Foundry ? 6 : 4, componentCount);
  const int size = wfgui::scaled(
      kind == PlayerItemGridWidget::Kind::Mastery
          ? 30
          : (kind == PlayerItemGridWidget::Kind::Foundry ? 36 : 34),
      scale);
  const int gap = wfgui::scaled(5, scale);
  if (kind == PlayerItemGridWidget::Kind::Foundry) {
    const int columns = 3;
    const int width = columns * size + (columns - 1) * gap;
    const int start = content.right() - width + 1;
    const int top = content.top() + wfgui::scaled(38, scale);
    QList<QRect> result;
    result.reserve(count);
    for (int index = 0; index < count; ++index) {
      result.append({start + (index % columns) * (size + gap),
                     top + (index / columns) * (size + gap), size, size});
    }
    return result;
  }
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

QRect masteredBadgeRect(const QRect &content, qreal scale) {
  const int size = wfgui::scaled(27, scale);
  return {content.right() - size + 1,
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
    const bool foundryOwned =
        kind_ == PlayerItemGridWidget::Kind::Foundry &&
        index.data(PlayerItemModel::OwnedRole).toBool();
    painter->setPen(foundryOwned
                        ? QPen(QColor("#248444"), wfgui::scaled(2, scale))
                        : Qt::NoPen);
    painter->setBrush(foundryOwned
                          ? QColor(option.state & QStyle::State_MouseOver
                                       ? "#24523f"
                                       : "#204638")
                          : QColor(option.state & QStyle::State_MouseOver
                                       ? "#272f47"
                                       : "#20283e"));
    painter->drawRoundedRect(card, wfgui::scaled(12, scale),
                             wfgui::scaled(12, scale));

    const QRect content = contentRect(option.rect, kind_, scale);
    if (kind_ == PlayerItemGridWidget::Kind::Foundry) {
      paintFoundry(*painter, content, index, option.font, scale);
      painter->restore();
      return;
    }
    const int imageSize = wfgui::scaled(
        kind_ == PlayerItemGridWidget::Kind::Mastery ? 72 : 80, scale);
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
      if (kind_ == PlayerItemGridWidget::Kind::Inventory &&
          index.data(PlayerItemModel::MasteredRole).toBool()) {
        const QRect badge = masteredBadgeRect(content, scale);
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
  static void paintFoundry(QPainter &painter, const QRect &content,
                           const QModelIndex &index, const QFont &baseFont,
                           qreal scale) {
    QFont titleFont = baseFont;
    titleFont.setPointSizeF(12.5 * scale);
    titleFont.setWeight(QFont::DemiBold);
    painter.setFont(titleFont);
    painter.setPen(QColor("#ffffff"));
    painter.drawText(
        QRect(content.left(), content.top(), content.width(),
              wfgui::scaled(27, scale)),
        Qt::AlignCenter,
        QFontMetrics(titleFont).elidedText(
            index.data(PlayerItemModel::NameRole).toString(), Qt::ElideRight,
            content.width() - wfgui::scaled(8, scale)));

    const int imageSize = wfgui::scaled(108, scale);
    const QRect imageRect(content.left() + wfgui::scaled(3, scale),
                          content.top() + wfgui::scaled(31, scale), imageSize,
                          imageSize);
    wfgui::drawContained(
        painter, imageRect,
        wfgui::cachedThumbnail(
            painter, index.data(PlayerItemModel::AssetPathRole).toString(),
            imageRect.size()));
    paintComponents(painter, content,
                    index.data(PlayerItemModel::ComponentsRole).toList(),
                    PlayerItemGridWidget::Kind::Foundry, scale);

    QFont detailFont = baseFont;
    detailFont.setPointSizeF(9.5 * scale);
    painter.setFont(detailFont);
    const bool owned = index.data(PlayerItemModel::OwnedRole).toBool();
    const bool pending = index.data(PlayerItemModel::PendingRole).toBool();
    const bool ready = index.data(PlayerItemModel::ReadyToBuildRole).toBool();
    QString status;
    QColor statusColor("#aeb5c7");
    if (owned) {
      status = "Owned";
      statusColor = QColor("#69d879");
    } else if (pending) {
      status = "Building";
      statusColor = QColor("#d8bf74");
    } else if (ready) {
      status = "Ready to build";
      statusColor = QColor("#69d879");
    } else if (index.data(PlayerItemModel::MasteredRole).toBool()) {
      status = "Mastered";
    }
    const int statusTop = content.bottom() - wfgui::scaled(22, scale);
    painter.setPen(statusColor);
    painter.drawText(QRect(content.left(), statusTop, content.width(),
                           wfgui::scaled(22, scale)),
                     Qt::AlignCenter, status);
    const int mastery =
        index.data(PlayerItemModel::MasteryRequirementRole).toInt();
    if (mastery > 0) {
      painter.setPen(QColor("#aeb5c7"));
      painter.drawText(QRect(content.left(), statusTop,
                             wfgui::scaled(55, scale),
                             wfgui::scaled(22, scale)),
                       Qt::AlignLeft | Qt::AlignVCenter,
                       QString("MR %1").arg(mastery));
    }
  }

  static void paintInventory(QPainter &painter, const QRect &content,
                             int textLeft, const QModelIndex &index,
                             const QFont &font, qreal scale) {
    painter.setFont(font);
    painter.setPen(QColor("#ffffff"));
    painter.drawText(QRect(textLeft,
                           content.top() + wfgui::scaled(30, scale),
                           wfgui::scaled(80, scale),
                           wfgui::scaled(22, scale)),
                     Qt::AlignLeft | Qt::AlignVCenter,
                     QString("x%1").arg(
                         index.data(PlayerItemModel::QuantityRole).toInt()));
    const int ducats = index.data(PlayerItemModel::DucatsRole).toInt();
    const bool tradable = index.data(PlayerItemModel::TradableRole).toBool();
    const int bottom = content.bottom() - wfgui::scaled(28, scale);
    if (ducats > 0) {
      const int iconSize = wfgui::scaled(18, scale);
      const QRect icon(content.left(), bottom + wfgui::scaled(4, scale),
                       iconSize, iconSize);
      wfgui::drawContained(
          painter, icon,
          wfgui::cachedThumbnail(painter, ":/assets/ducats.png", icon.size()));
      painter.drawText(QRect(icon.right() + wfgui::scaled(3, scale), icon.top(),
                             wfgui::scaled(32, scale), icon.height()),
                       Qt::AlignLeft | Qt::AlignVCenter,
                       QString::number(ducats));
    }
    if (tradable) {
      const int gap = wfgui::scaled(8, scale);
      const int available = content.right() - textLeft + 1;
      const int width = (available - gap) / 2;
      const QString state = index.data(PlayerItemModel::PriceStateRole).toString();
      const auto priceText = [&index, &state](int role) {
        return state == "loading"
                   ? QString("...")
                   : (state == "ready" && index.data(role).isValid()
                          ? index.data(role).toString()
                          : QString("--"));
      };
      paintQuotePill(painter, {textLeft, bottom, width, wfgui::scaled(27, scale)},
                     "WTS", priceText(PlayerItemModel::PlatinumRole),
                     QColor("#6f2e43"), scale);
      paintQuotePill(
          painter,
          {textLeft + width + gap, bottom, width, wfgui::scaled(27, scale)},
          "WTB", priceText(PlayerItemModel::BuyPlatinumRole),
          QColor("#1e5b50"), scale);
    }
    if (index.data(PlayerItemModel::MasteredRole).toBool()) {
      const QRect badge = masteredBadgeRect(content, scale);
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

  static void paintQuotePill(QPainter &painter, const QRect &rect,
                             const QString &label, const QString &price,
                             const QColor &color, qreal scale) {
    painter.setPen(Qt::NoPen);
    painter.setBrush(color);
    painter.drawRoundedRect(rect, rect.height() / 2, rect.height() / 2);
    painter.setPen(QColor("#ffffff"));
    painter.drawText(rect.adjusted(wfgui::scaled(10, scale), 0, 0, 0),
                     Qt::AlignLeft | Qt::AlignVCenter, label);
    const int iconSize = wfgui::scaled(16, scale);
    const int priceWidth = QFontMetrics(painter.font()).horizontalAdvance(price);
    const int groupWidth = priceWidth + wfgui::scaled(3, scale) + iconSize;
    const int left = rect.right() - wfgui::scaled(10, scale) - groupWidth + 1;
    painter.drawText(QRect(left, rect.top(), priceWidth, rect.height()),
                     Qt::AlignCenter, price);
    const QRect icon(left + priceWidth + wfgui::scaled(3, scale),
                     rect.center().y() - iconSize / 2, iconSize, iconSize);
    wfgui::drawContained(
        painter, icon,
        wfgui::cachedThumbnail(painter, ":/assets/platinum.png", icon.size()));
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
    const int missingParts =
        index.data(PlayerItemModel::MissingPartsRole).toInt();
    const QString status =
        owned
            ? QString("Level %1/%2")
                  .arg(index.data(PlayerItemModel::RankRole).toInt())
                  .arg(index.data(PlayerItemModel::MaxRankRole).toInt())
            : (pending
                   ? QString("Building")
                   : (components.isEmpty()
                          ? QString("Not owned")
                          : (missingParts == 0
                                 ? QString("Ready to build")
                                 : QString("%1 parts missing")
                                       .arg(missingParts))));
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
      if (kind == PlayerItemGridWidget::Kind::Foundry) {
        const int owned = component.value("owned").toInt();
        if (owned > 0) {
          QFont countFont = painter.font();
          countFont.setPointSizeF(8.5 * scale);
          countFont.setWeight(QFont::DemiBold);
          painter.setFont(countFont);
          painter.setPen(QColor("#ffffff"));
          painter.drawText(circle.adjusted(0, 0, -wfgui::scaled(2, scale),
                                           -wfgui::scaled(1, scale)),
                           Qt::AlignRight | Qt::AlignBottom,
                           QString::number(owned));
        }
      }
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
      kind_ == Kind::Foundry
          ? FoundryMinTrack
          : (kind_ == Kind::Inventory ? InventoryMinTrack : MasteryMinTrack),
      scale);
  const int columns = std::max(1, (width + gap) / (minimumTrack + gap));
  const int track =
      std::min(wfgui::scaled(MaxTrack, scale),
               std::max(1, (width - 1 - columns * gap) / columns));
  const int height = wfgui::scaled(
      kind_ == Kind::Foundry ? 198 : (kind_ == Kind::Mastery ? 91 : 142),
      scale);
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
