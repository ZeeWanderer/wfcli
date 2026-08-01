#include "main_window.h"

#include <QButtonGroup>
#include <QHBoxLayout>
#include <QIcon>
#include <QLabel>
#include <QPainter>
#include <QPixmap>
#include <QPushButton>
#include <QResizeEvent>
#include <QSizePolicy>
#include <QStackedWidget>
#include <QStyle>
#include <QVBoxLayout>
#include <QWidget>

#include <array>

#include "activity_rail_widget.h"
#include "foundry_widget.h"
#include "inventory_widget.h"
#include "mastery_planner_widget.h"
#include "relic_planner_widget.h"

namespace {
QPixmap tintedPixmap(const QString &path, const QColor &color) {
  const QPixmap source(path);
  QPixmap result(source.size());
  result.fill(Qt::transparent);
  QPainter painter(&result);
  painter.drawPixmap(0, 0, source);
  painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
  painter.fillRect(result.rect(), color);
  return result;
}

QIcon navigationIcon(const QString &path) {
  QIcon icon;
  icon.addPixmap(tintedPixmap(path, QColor("#8a8c95")), QIcon::Normal,
                 QIcon::Off);
  icon.addPixmap(tintedPixmap(path, QColor("#d8dbea")), QIcon::Active,
                 QIcon::Off);
  icon.addPixmap(tintedPixmap(path, Qt::white), QIcon::Normal, QIcon::On);
  return icon;
}
} // namespace

MainWindow::MainWindow(QWidget *parent)
    : QMainWindow(parent), controller_(this), daemonStatus_(new QLabel),
      navigation_(new QButtonGroup(this)), pages_(new QStackedWidget),
      activityRail_(new ActivityRailWidget(&controller_)) {
  setWindowTitle("wfcli");
  resize(1280, 800);
  setMinimumSize(900, 600);

  auto *central = new QWidget;
  central->setObjectName("appRoot");
  auto *layout = new QHBoxLayout(central);
  layout->setContentsMargins(6, 6, 6, 0);
  layout->setSpacing(7);

  auto *sidebar = new QWidget;
  sidebar->setObjectName("sidebar");
  sidebar->setFixedWidth(142);
  auto *sidebarLayout = new QVBoxLayout(sidebar);
  sidebarLayout->setContentsMargins(8, 14, 8, 12);
  sidebarLayout->setSpacing(8);

  auto *brand = new QLabel("wfcli");
  brand->setObjectName("brand");
  sidebarLayout->addWidget(brand);
  sidebarLayout->addSpacing(18);

  navigation_->setExclusive(true);
  struct NavigationItem {
    const char *label;
    const char *icon;
  };
  constexpr std::array<NavigationItem, 4> items{{
      {"Foundry", ":/resources/ui/nav_foundry.png"},
      {"Mastery\nHelper", ":/resources/ui/nav_mastery.png"},
      {"Inventory", ":/resources/ui/nav_inventory.png"},
      {"Relic\nPlanner", ":/resources/ui/nav_relic.png"},
  }};
  for (int page = 0; page < static_cast<int>(items.size()); ++page) {
    auto *button = new QPushButton(items.at(page).label);
    button->setObjectName("navigation");
    button->setIcon(navigationIcon(items.at(page).icon));
    button->setIconSize({24, 24});
    button->setCheckable(true);
    button->setChecked(page == 0);
    button->setProperty("page", page);
    button->setProperty("multiline",
                        QString(items.at(page).label).contains('\n'));
    navigation_->addButton(button, page);
    sidebarLayout->addWidget(button);
  }
  sidebarLayout->addStretch();

  daemonStatus_->setObjectName("daemonStatus");
  daemonStatus_->setWordWrap(true);
  daemonStatus_->setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Preferred);
  sidebarLayout->addWidget(daemonStatus_);

  layout->addWidget(sidebar);
  pages_->setObjectName("centerRail");
  pages_->addWidget(new FoundryWidget(&controller_));
  pages_->addWidget(new MasteryPlannerWidget(&controller_));
  pages_->addWidget(new InventoryWidget(&controller_));
  pages_->addWidget(new RelicPlannerWidget(&controller_));
  pages_->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Expanding);
  pages_->setMinimumWidth(0);
  layout->addWidget(pages_, 1);
  layout->addWidget(activityRail_);
  setCentralWidget(central);

  connect(navigation_, &QButtonGroup::idClicked, this, &MainWindow::selectPage);

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
