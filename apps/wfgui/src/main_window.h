#pragma once

#include <QList>
#include <QMainWindow>

#include <functional>

#include "app_controller.h"

class QLabel;
class QButtonGroup;
class QEvent;
class QPushButton;
class QStackedWidget;
class ActivityRailWidget;
class PlayerIdentityWidget;
class QResizeEvent;
class TitleBarWidget;

class MainWindow final : public QMainWindow {
  Q_OBJECT

public:
  explicit MainWindow(QWidget *parent = nullptr);
  bool setPage(const QString &page);

private:
  void updateDaemonStatus();
  void selectPage(int page);
  void changeUiScale(int delta);
  void toggleLeftRail();
  void toggleRightRail();
  void animateRail(QWidget *rail, int targetWidth, bool hideAfter,
                   const std::function<void()> &finished);
  QString currentPageName() const;
  void positionResizeHandles();
  void changeEvent(QEvent *event) override;
  void resizeEvent(QResizeEvent *event) override;

  AppController controller_;
  QWidget *sidebar_;
  PlayerIdentityWidget *playerIdentity_;
  QLabel *daemonStatus_;
  QButtonGroup *navigation_;
  QList<QPushButton *> navigationButtons_;
  QStringList navigationLabels_;
  QStackedWidget *pages_;
  ActivityRailWidget *activityRail_;
  TitleBarWidget *titleBar_;
  QList<QWidget *> resizeHandles_;
  bool leftRailCollapsed_ = false;
  bool rightRailCollapsed_ = false;
  bool leftRailAnimating_ = false;
  bool rightRailAnimating_ = false;
};
