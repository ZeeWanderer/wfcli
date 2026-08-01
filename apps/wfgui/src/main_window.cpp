#include "main_window.h"

#include <QHBoxLayout>
#include <QLabel>
#include <QButtonGroup>
#include <QPushButton>
#include <QResizeEvent>
#include <QSizePolicy>
#include <QStackedWidget>
#include <QStyle>
#include <QVBoxLayout>
#include <QWidget>

#include "activity_rail_widget.h"
#include "foundry_widget.h"
#include "inventory_widget.h"
#include "mastery_planner_widget.h"
#include "relic_planner_widget.h"

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent), controller_(this), daemonStatus_(new QLabel),
      navigation_(new QButtonGroup(this)),
      pages_(new QStackedWidget),
      activityRail_(new ActivityRailWidget(&controller_)) {
  setWindowTitle("wfcli");
  resize(1280, 800);
  setMinimumSize(900, 600);

  auto *central = new QWidget;
  auto *layout = new QHBoxLayout(central);
  layout->setContentsMargins(6, 6, 6, 0);
  layout->setSpacing(7);

  auto *sidebar = new QWidget;
  sidebar->setObjectName("sidebar");
  sidebar->setFixedWidth(135);
  auto *sidebarLayout = new QVBoxLayout(sidebar);
  sidebarLayout->setContentsMargins(8, 14, 8, 12);
  sidebarLayout->setSpacing(8);

  auto *brand = new QLabel("wfcli");
  brand->setObjectName("brand");
  sidebarLayout->addWidget(brand);
  sidebarLayout->addSpacing(18);

  navigation_->setExclusive(true);
  const QStringList labels = {"Foundry", "Mastery Helper", "Inventory",
                              "Relic Planner"};
  for (int page = 0; page < labels.size(); ++page) {
    auto *button = new QPushButton(labels.at(page));
    button->setObjectName("navigation");
    button->setCheckable(true);
    button->setChecked(page == 0);
    button->setProperty("page", page);
    navigation_->addButton(button, page);
    sidebarLayout->addWidget(button);
  }
  sidebarLayout->addStretch();

  daemonStatus_->setObjectName("daemonStatus");
  daemonStatus_->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
  sidebarLayout->addWidget(daemonStatus_);

  layout->addWidget(sidebar);
  pages_->addWidget(new FoundryWidget(&controller_));
  pages_->addWidget(new MasteryPlannerWidget(&controller_));
  pages_->addWidget(new InventoryWidget(&controller_));
  pages_->addWidget(new RelicPlannerWidget(&controller_));
  pages_->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Expanding);
  pages_->setMinimumWidth(0);
  layout->addWidget(pages_, 1);
  layout->addWidget(activityRail_);
  setCentralWidget(central);

  connect(navigation_, &QButtonGroup::idClicked, this,
          &MainWindow::selectPage);

  connect(&controller_, &AppController::statusChanged, this,
          &MainWindow::updateDaemonStatus);
  connect(&controller_, &AppController::connectedChanged, this,
          &MainWindow::updateDaemonStatus);
  updateDaemonStatus();
}

bool MainWindow::setPage(const QString &page) {
  const QStringList names = {"foundry", "mastery", "inventory", "relic"};
  const int index = names.indexOf(page.toLower());
  if (index < 0) {
    return false;
  }
  selectPage(index);
  navigation_->button(index)->setChecked(true);
  return true;
}

void MainWindow::selectPage(int page) {
  pages_->setCurrentIndex(page);
  if (page == 0) {
    controller_.ensureFoundry();
  } else if (page == 1) {
    controller_.ensureMastery();
  } else if (page == 2) {
    controller_.ensureInventory();
  } else if (page == 3) {
    controller_.ensureRelics();
  }
}

void MainWindow::resizeEvent(QResizeEvent *event) {
  QMainWindow::resizeEvent(event);
  activityRail_->setVisible(event->size().width() >= 1180);
}

void MainWindow::updateDaemonStatus() {
  daemonStatus_->setText(controller_.status());
  daemonStatus_->setToolTip(controller_.status());
  daemonStatus_->setProperty("connected", controller_.connected());
  daemonStatus_->style()->unpolish(daemonStatus_);
  daemonStatus_->style()->polish(daemonStatus_);
}
