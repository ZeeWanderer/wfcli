#pragma once

#include <QJsonArray>
#include <QListView>
#include <QStringList>

#include <utility>

class QTimer;

class PlayerItemGridWidget final : public QListView {
  Q_OBJECT

public:
  enum class Kind { Inventory, Mastery };

  explicit PlayerItemGridWidget(Kind kind, QWidget *parent = nullptr);
  void setModel(QAbstractItemModel *model) override;
  void refreshVisibleQuotes();

signals:
  void assetsNeeded(const QJsonArray &assets);
  void quotesNeeded(const QStringList &items, bool refresh);

protected:
  void resizeEvent(QResizeEvent *event) override;

private:
  void updateGrid();
  void scheduleVisibleData();
  void requestVisibleData();
  void requestVisibleAssets();
  void requestVisibleQuotes(bool refresh = false);
  std::pair<int, int> visibleRows() const;

  Kind kind_;
  QTimer *visibleDataTimer_;
};
