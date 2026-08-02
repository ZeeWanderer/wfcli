#pragma once

#include <QJsonArray>
#include <QListView>
#include <QStringList>

#include <utility>

class QTimer;

class PlayerItemGridWidget final : public QListView {
  Q_OBJECT

public:
  enum class Kind { Foundry, Inventory, Mastery };

  explicit PlayerItemGridWidget(Kind kind, QWidget *parent = nullptr);
  void setModel(QAbstractItemModel *model) override;
  void refreshVisibleQuotes();

signals:
  void assetsNeeded(const QJsonArray &assets);
  void quotesNeeded(const QStringList &items, bool refresh);
  void marketItemRequested(const QString &item, const QString &side);
  void relicRewardRequested(const QString &reward);

protected:
  void resizeEvent(QResizeEvent *event) override;

private:
  void updateGrid();
  void scheduleVisibleData();
  void requestVisibleData();
  void requestVisibleAssets();
  void requestVisibleQuotes(bool refresh = false);
  std::pair<int, int> visibleRows() const;
  void preserveScrollPosition();
  void restoreScrollPosition();

  Kind kind_;
  QTimer *visibleDataTimer_;
  int preservedScrollValue_ = -1;
  bool scrollRestoreScheduled_ = false;
};
