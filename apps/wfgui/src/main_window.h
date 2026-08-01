#pragma once

#include <QMainWindow>

#include "app_controller.h"

class QLabel;
class QButtonGroup;
class QStackedWidget;
class ActivityRailWidget;
class QResizeEvent;

class MainWindow final : public QMainWindow {
  Q_OBJECT

public:
  explicit MainWindow(QWidget *parent = nullptr);
  bool setPage(const QString &page);

private:
  void updateDaemonStatus();
  void selectPage(int page);
  void resizeEvent(QResizeEvent *event) override;

  AppController controller_;
  QLabel *daemonStatus_;
  QButtonGroup *navigation_;
  QStackedWidget *pages_;
  ActivityRailWidget *activityRail_;
};
