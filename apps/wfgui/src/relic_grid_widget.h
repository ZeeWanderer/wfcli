#pragma once

#include <QHash>
#include <QList>
#include <QString>
#include <QWidget>

class QAbstractItemModel;
class QGridLayout;
class QModelIndex;
class QResizeEvent;

class RelicGridWidget final : public QWidget {
  Q_OBJECT

public:
  explicit RelicGridWidget(QWidget *parent = nullptr);

  void setModel(QAbstractItemModel *model);

signals:
  void marketItemRequested(const QString &item, const QString &side);
  void rewardFilterRequested(const QString &reward);
  void foundryItemRequested(const QString &item);

protected:
  void resizeEvent(QResizeEvent *event) override;

private:
  void scheduleRebuild();
  void rebuild();
  void resetCards();
  void relayout();
  void updateRows(const QModelIndex &topLeft, const QModelIndex &bottomRight);

  QAbstractItemModel *model_ = nullptr;
  QGridLayout *grid_;
  QList<QWidget *> cards_;
  QHash<QString, QWidget *> cardCache_;
  int columns_ = 0;
  qreal scale_ = 0.0;
  bool rebuildPending_ = false;
};
