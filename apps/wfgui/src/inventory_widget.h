#pragma once

#include <QWidget>

class AppController;
class QLabel;
class PlayerItemFilterModel;
class PlayerItemGridWidget;
class QProgressBar;
class QPushButton;
class QStackedLayout;

class InventoryWidget final : public QWidget {
  Q_OBJECT

public:
  explicit InventoryWidget(AppController *controller,
                           QWidget *parent = nullptr);

private:
  void updateContent();

  AppController *controller_;
  PlayerItemFilterModel *items_;
  PlayerItemGridWidget *grid_;
  QLabel *summary_;
  QLabel *emptyState_;
  QProgressBar *progress_;
  QPushButton *refresh_;
  QStackedLayout *content_;
};
