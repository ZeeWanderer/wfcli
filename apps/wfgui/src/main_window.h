#pragma once

#include <QMainWindow>

#include "app_controller.h"

class QLabel;
class QButtonGroup;
class QStackedWidget;

class MainWindow final : public QMainWindow {
  Q_OBJECT

public:
  explicit MainWindow(QWidget *parent = nullptr);
  bool setPage(const QString &page);

private:
  void updateDaemonStatus();
  void selectPage(int page);

  AppController controller_;
  QLabel *daemonStatus_;
  QButtonGroup *navigation_;
  QStackedWidget *pages_;
};
