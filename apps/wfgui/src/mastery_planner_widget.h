#pragma once

#include <QWidget>

class AppController;
class QLabel;
class PlayerItemFilterModel;
class PlayerItemGridWidget;
class QProgressBar;
class QPushButton;
class QStackedLayout;

class MasteryPlannerWidget final : public QWidget {
  Q_OBJECT

public:
  explicit MasteryPlannerWidget(AppController *controller,
                                QWidget *parent = nullptr);

private:
  void updateContent();

  AppController *controller_;
  PlayerItemFilterModel *items_;
  PlayerItemGridWidget *grid_;
  QLabel *rank_;
  QLabel *completion_;
  QLabel *warframes_;
  QLabel *weapons_;
  QLabel *companions_;
  QLabel *emptyState_;
  QProgressBar *completionBar_;
  QProgressBar *loadingBar_;
  QPushButton *refresh_;
  QStackedLayout *content_;
};
