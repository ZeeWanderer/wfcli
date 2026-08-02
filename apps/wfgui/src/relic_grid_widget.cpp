#include "relic_grid_widget.h"

#include <QAbstractItemModel>
#include <QEnterEvent>
#include <QFontMetrics>
#include <QGridLayout>
#include <QHelpEvent>
#include <QMouseEvent>
#include <QPainter>
#include <QPainterPath>
#include <QPersistentModelIndex>
#include <QPixmap>
#include <QResizeEvent>
#include <QSet>
#include <QTimer>
#include <QToolTip>
#include <QVariantList>
#include <QVariantMap>

#include <algorithm>
#include <functional>
#include <utility>

#include "display_metrics.h"
#include "image_cache.h"
#include "relic_card_layout.h"
#include "relic_model.h"
#include "widget_capture.h"

namespace {
constexpr int CardHeight = 108;
constexpr int GridMargin = 8;
constexpr int GridGap = 8;
constexpr int MaximumTrackWidth = 620;

QRect overscan(const QRect &rect, int percent) {
  const QSize size(rect.width() * percent / 100, rect.height() * percent / 100);
  return {QPoint(rect.center().x() - size.width() / 2,
                 rect.center().y() - size.height() / 2),
          size};
}

class RelicCardWidget final : public QWidget {
public:
  explicit RelicCardWidget(
      const QModelIndex &index,
      std::function<void(const QString &, const QString &)> marketRequest,
      QWidget *parent = nullptr)
      : QWidget(parent), marketRequest_(std::move(marketRequest)) {
    setObjectName("relicCardCanvas");
    wfgui::setCaptureItem(this);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
    setAttribute(Qt::WA_Hover);
    setScale(1.0);
    setIndex(index);
  }

  void setIndex(const QModelIndex &index) {
    index_ = index;
    setToolTip(index_.data(RelicModel::NameRole).toString());
    update();
  }

  void setScale(qreal scale) {
    if (scale_ == scale) {
      return;
    }
    scale_ = scale;
    setFixedHeight(wfgui::scaled(CardHeight, scale_));
    update();
  }

protected:
  bool event(QEvent *event) override {
    if (event->type() == QEvent::ToolTip && index_.isValid()) {
      auto *help = static_cast<QHelpEvent *>(event);
      const QVariantList rewards =
          index_.data(RelicModel::RewardsRole).toList();
      const QVariantList refinements =
          index_.data(RelicModel::RefinementsRole).toList();
      const wfgui::RelicCardLayout layout = wfgui::RelicCardLayout::calculate(
          rect(), static_cast<int>(refinements.size()),
          static_cast<int>(rewards.size()), scale_);
      const int count = std::min(static_cast<int>(layout.rewardCells.size()),
                                 static_cast<int>(rewards.size()));
      for (int rewardIndex = 0; rewardIndex < count; ++rewardIndex) {
        if (!layout.rewardCells.at(rewardIndex).contains(help->pos())) {
          continue;
        }
        const QString name =
            rewards.at(rewardIndex).toMap().value("name").toString();
        QToolTip::showText(mapToGlobal(help->pos()), name, this,
                           layout.rewardCells.at(rewardIndex));
        return true;
      }
    }
    return QWidget::event(event);
  }

  void enterEvent(QEnterEvent *event) override {
    hovered_ = true;
    update();
    QWidget::enterEvent(event);
  }

  void leaveEvent(QEvent *event) override {
    hovered_ = false;
    update();
    QWidget::leaveEvent(event);
  }

  void mouseReleaseEvent(QMouseEvent *event) override {
    if (!index_.isValid() || event->button() != Qt::LeftButton) {
      QWidget::mouseReleaseEvent(event);
      return;
    }
    const QVariantList rewards = index_.data(RelicModel::RewardsRole).toList();
    const QVariantList refinements =
        index_.data(RelicModel::RefinementsRole).toList();
    const wfgui::RelicCardLayout layout = wfgui::RelicCardLayout::calculate(
        rect(), static_cast<int>(refinements.size()),
        static_cast<int>(rewards.size()), scale_);
    for (int reward = 0;
         reward < std::min(static_cast<int>(layout.rewardCells.size()),
                           static_cast<int>(rewards.size()));
         ++reward) {
      if (!layout.rewardCells.at(reward).contains(
              event->position().toPoint())) {
        continue;
      }
      const QVariantMap data = rewards.at(reward).toMap();
      marketRequest_(data.value("name").toString(),
                     data.value("owned").toInt() > 0 ? "sell" : "buy");
      event->accept();
      return;
    }
    const QPoint position = event->position().toPoint();
    if (layout.image.contains(position) || layout.title.contains(position)) {
      marketRequest_(index_.data(RelicModel::NameRole).toString(),
                     index_.data(RelicModel::AmountOwnedRole).toInt() > 0
                         ? "sell"
                         : "buy");
      event->accept();
      return;
    }
    QWidget::mouseReleaseEvent(event);
  }

  void paintEvent(QPaintEvent *) override {
    if (!index_.isValid()) {
      return;
    }

    QPainter painter(this);
    painter.setRenderHint(QPainter::Antialiasing);
    painter.setRenderHint(QPainter::SmoothPixmapTransform);

    const QVariantList refinements =
        index_.data(RelicModel::RefinementsRole).toList();
    const QVariantList rewards = index_.data(RelicModel::RewardsRole).toList();
    const wfgui::RelicCardLayout layout = wfgui::RelicCardLayout::calculate(
        rect(), static_cast<int>(refinements.size()),
        static_cast<int>(rewards.size()), scale_);
    const QRect &card = layout.card;
    painter.setPen(Qt::NoPen);
    painter.setBrush(hovered_ ? QColor("#272f47") : QColor("#20283e"));
    painter.drawRoundedRect(card, wfgui::scaled(12, scale_),
                            wfgui::scaled(12, scale_));

    const QPixmap relicPixmap = wfgui::cachedThumbnail(
        painter, index_.data(RelicModel::RelicImageRole).toString(),
        layout.relicArt.size());
    if (relicPixmap.isNull()) {
      painter.setPen(QPen(QColor("#8a8c95"), 1.5 * scale_));
      const QRectF glyph = layout.image.adjusted(
          wfgui::scaled(17, scale_), wfgui::scaled(11, scale_),
          -wfgui::scaled(17, scale_), -wfgui::scaled(11, scale_));
      painter.drawEllipse(glyph);
      QPainterPath diamond;
      diamond.moveTo(glyph.center().x(), glyph.top());
      diamond.lineTo(glyph.right(), glyph.center().y());
      diamond.lineTo(glyph.center().x(), glyph.bottom());
      diamond.lineTo(glyph.left(), glyph.center().y());
      diamond.closeSubpath();
      painter.drawPath(diamond);
    } else {
      wfgui::drawContained(painter, layout.relicArt, relicPixmap);
    }

    QFont badgeFont = font();
    badgeFont.setPixelSize(wfgui::scaled(15, scale_));
    badgeFont.setWeight(QFont::DemiBold);
    painter.setFont(badgeFont);
    painter.setPen(QColor("#ffffff"));
    painter.setBrush(Qt::NoBrush);
    painter.drawText(
        layout.amountBadge, Qt::AlignCenter,
        QString("x%1").arg(index_.data(RelicModel::AmountOwnedRole).toInt()));

    if (index_.data(RelicModel::VaultedRole).toBool()) {
      const QRect badge = overscan(layout.vaultedBadge, 125);
      wfgui::drawContained(painter, badge,
                           wfgui::cachedThumbnail(
                               painter, ":/assets/vaulted.png", badge.size()));
    }

    QFont nameFont = font();
    nameFont.setPixelSize(wfgui::scaled(19, scale_));
    nameFont.setWeight(QFont::Medium);
    painter.setFont(nameFont);
    painter.setPen(QColor("#ffffff"));
    const QString name = index_.data(RelicModel::NameRole).toString();
    painter.drawText(layout.title, Qt::AlignLeft | Qt::AlignVCenter,
                     QFontMetrics(nameFont).elidedText(name, Qt::ElideRight,
                                                       layout.title.width()));

    const QRect platinumHeader = layout.platinumHeader.adjusted(
        wfgui::scaled(8, scale_), wfgui::scaled(2, scale_),
        -wfgui::scaled(8, scale_), -wfgui::scaled(2, scale_));
    const QRect ducatHeader = layout.ducatHeader.adjusted(
        wfgui::scaled(8, scale_), wfgui::scaled(2, scale_),
        -wfgui::scaled(8, scale_), -wfgui::scaled(2, scale_));
    wfgui::drawContained(painter, platinumHeader,
                         wfgui::cachedThumbnail(painter,
                                                ":/assets/platinum.png",
                                                platinumHeader.size()));
    wfgui::drawContained(painter, ducatHeader,
                         wfgui::cachedThumbnail(painter, ":/assets/ducats.png",
                                                ducatHeader.size()));

    const int rows = static_cast<int>(layout.refinementRows.size());
    QFont valueFont = font();
    valueFont.setPointSizeF((rows >= 4 ? 9.0 : 10.0) * scale_);
    painter.setFont(valueFont);
    for (int row = 0; row < rows; ++row) {
      const QVariantMap refinement = row < refinements.size()
                                         ? refinements.at(row).toMap()
                                         : QVariantMap{};
      const auto &rowLayout = layout.refinementRows.at(row);
      painter.setPen(QColor("#ffffff"));
      const QString label =
          refinement.isEmpty()
              ? QString()
              : QString("%1x %2")
                    .arg(refinement.value("amountOwned").toInt())
                    .arg(refinement.value("name").toString());
      painter.drawText(rowLayout.label, Qt::AlignLeft | Qt::AlignVCenter,
                       QFontMetrics(valueFont).elidedText(
                           label, Qt::ElideRight, rowLayout.label.width()));
      const bool hasPrice = refinement.value("hasPrice").toBool();
      const bool complete = refinement.value("priceComplete").toBool();
      painter.setPen(hasPrice ? QColor("#ffffff") : QColor("#8a8c95"));
      painter.drawText(
          rowLayout.platinum, Qt::AlignCenter,
          hasPrice ? QString("%1%2")
                         .arg(complete ? QString() : QString("~"))
                         .arg(refinement.value("expectedPlatinum").toInt())
                   : QString("--"));
      painter.setPen(QColor("#ffffff"));
      painter.drawText(
          rowLayout.ducats, Qt::AlignCenter,
          QString::number(refinement.value("expectedDucats").toInt()));
    }

    for (int rewardIndex = 0;
         rewardIndex < static_cast<int>(layout.rewardCells.size());
         ++rewardIndex) {
      const QVariantMap reward = rewards.at(rewardIndex).toMap();
      const QRect &rewardRect = layout.rewardCells.at(rewardIndex);
      painter.setBrush(QColor(255, 255, 255, 0x12));
      painter.setPen(Qt::NoPen);
      painter.drawEllipse(rewardRect);
      const int imageInset = wfgui::scaled(2, scale_);
      const QRect rewardImageRect =
          rewardRect.adjusted(imageInset, imageInset, -imageInset, -imageInset);
      const QPixmap rewardImage = wfgui::cachedThumbnail(
          painter, reward.value("image").toString(), rewardImageRect.size());
      if (rewardImage.isNull()) {
        painter.setPen(QPen(QColor("#8a8c95"), wfgui::scaled(1, scale_)));
        const int placeholderInset = wfgui::scaled(9, scale_);
        painter.drawEllipse(
            rewardRect.adjusted(placeholderInset, placeholderInset,
                                -placeholderInset, -placeholderInset));
      } else {
        painter.save();
        QPainterPath clip;
        clip.addEllipse(rewardImageRect);
        painter.setClipPath(clip);
        wfgui::drawContained(painter, rewardImageRect, rewardImage);
        painter.restore();
      }
      if (reward.value("owned").toInt() > 0) {
        painter.setPen(QPen(QColor("#46d234"), wfgui::scaled(2, scale_)));
        painter.setBrush(QColor(0x6e, 0x9b, 0x68, 0x78));
        const int ownedInset = wfgui::scaled(2, scale_);
        painter.drawEllipse(rewardRect.adjusted(ownedInset, ownedInset,
                                                -ownedInset, -ownedInset));
      }
    }
  }

private:
  QPersistentModelIndex index_;
  qreal scale_ = 0.0;
  bool hovered_ = false;
  std::function<void(const QString &, const QString &)> marketRequest_;
};
} // namespace

RelicGridWidget::RelicGridWidget(QWidget *parent)
    : QWidget(parent), grid_(new QGridLayout(this)) {
  setObjectName("relicGrid");
  wfgui::setCaptureTarget(this, "relic-planner.grid", true);
  grid_->setContentsMargins(GridMargin, GridMargin, GridMargin, GridMargin);
  grid_->setHorizontalSpacing(GridGap);
  grid_->setVerticalSpacing(0);
  grid_->setAlignment(Qt::AlignTop);
  setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Preferred);
}

void RelicGridWidget::setModel(QAbstractItemModel *model) {
  if (model_ == model) {
    return;
  }
  if (model_) {
    disconnect(model_, nullptr, this, nullptr);
  }
  model_ = model;
  if (model_) {
    connect(model_, &QAbstractItemModel::modelReset, this,
            &RelicGridWidget::resetCards);
    connect(model_, &QAbstractItemModel::rowsInserted, this,
            &RelicGridWidget::scheduleRebuild);
    connect(model_, &QAbstractItemModel::rowsRemoved, this,
            &RelicGridWidget::scheduleRebuild);
    connect(model_, &QAbstractItemModel::layoutChanged, this,
            &RelicGridWidget::scheduleRebuild);
    connect(model_, &QAbstractItemModel::dataChanged, this,
            &RelicGridWidget::updateRows);
    connect(model_, &QObject::destroyed, this, [this] {
      model_ = nullptr;
      rebuild();
    });
  }
  rebuild();
}

void RelicGridWidget::resizeEvent(QResizeEvent *event) {
  QWidget::resizeEvent(event);
  relayout();
}

void RelicGridWidget::scheduleRebuild() {
  if (rebuildPending_) {
    return;
  }
  rebuildPending_ = true;
  QTimer::singleShot(0, this, [this] {
    rebuildPending_ = false;
    rebuild();
  });
}

void RelicGridWidget::rebuild() {
  setUpdatesEnabled(false);
  const QList<QWidget *> previousCards = cards_;
  while (QLayoutItem *item = grid_->takeAt(0)) {
    delete item;
  }
  cards_.clear();
  columns_ = 0;
  if (model_) {
    cards_.reserve(model_->rowCount());
    for (int row = 0; row < model_->rowCount(); ++row) {
      const QModelIndex index = model_->index(row, 0);
      const QString key = index.data(RelicModel::NameRole).toString();
      auto *card = static_cast<RelicCardWidget *>(cardCache_.value(key));
      if (!card) {
        card = new RelicCardWidget(
            index,
            [this](const QString &item, const QString &side) {
              emit marketItemRequested(item, side);
            },
            this);
        cardCache_.insert(key, card);
      } else {
        card->setIndex(index);
      }
      card->show();
      cards_.append(card);
    }
  }
  QSet<QWidget *> visibleCards;
  for (QWidget *card : std::as_const(cards_)) {
    visibleCards.insert(card);
  }
  for (QWidget *card : previousCards) {
    if (!visibleCards.contains(card)) {
      card->hide();
    }
  }
  relayout();
  setUpdatesEnabled(true);
  update();
}

void RelicGridWidget::resetCards() {
  while (QLayoutItem *item = grid_->takeAt(0)) {
    delete item;
  }
  qDeleteAll(cardCache_);
  cardCache_.clear();
  cards_.clear();
  columns_ = 0;
  rebuild();
}

void RelicGridWidget::relayout() {
  const qreal scale = wfgui::displayScale(this);
  const int margin = wfgui::scaled(GridMargin, scale);
  const int gap = wfgui::scaled(GridGap, scale);
  const int columns = wfgui::relicGridColumns(width(), scale);
  const int availableWidth = std::max(0, width() - 2 * margin);
  const int maximumGridWidth =
      columns * wfgui::scaled(MaximumTrackWidth, scale) + (columns - 1) * gap;
  const int extraWidth = std::max(0, availableWidth - maximumGridWidth);
  const int leftMargin = margin + extraWidth / 2;
  const int rightMargin = margin + extraWidth - extraWidth / 2;
  grid_->setContentsMargins(leftMargin, margin, rightMargin, margin);
  grid_->setHorizontalSpacing(gap);
  for (QWidget *card : std::as_const(cards_)) {
    static_cast<RelicCardWidget *>(card)->setScale(scale);
  }

  if (columns_ == columns && scale_ == scale &&
      grid_->count() == cards_.size()) {
    return;
  }

  setUpdatesEnabled(false);
  while (QLayoutItem *item = grid_->takeAt(0)) {
    delete item;
  }
  for (int column = 0; column < std::max(columns_, columns); ++column) {
    grid_->setColumnStretch(column, column < columns ? 1 : 0);
  }
  for (int index = 0; index < static_cast<int>(cards_.size()); ++index) {
    grid_->addWidget(cards_.at(index), index / columns, index % columns);
  }
  columns_ = columns;
  scale_ = scale;
  grid_->activate();
  setUpdatesEnabled(true);
  updateGeometry();
  update();
}

void RelicGridWidget::updateRows(const QModelIndex &topLeft,
                                 const QModelIndex &bottomRight) {
  const int first = std::max(0, topLeft.row());
  const int last =
      std::min(bottomRight.row(), static_cast<int>(cards_.size()) - 1);
  for (int row = first; row <= last; ++row) {
    cards_.at(row)->update();
  }
}
