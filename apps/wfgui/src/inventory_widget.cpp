#include "inventory_widget.h"

#include <QAbstractItemModel>
#include <QButtonGroup>
#include <QHBoxLayout>
#include <QIcon>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QProgressBar>
#include <QPushButton>
#include <QStackedLayout>
#include <QVBoxLayout>

#include <array>
#include <utility>

#include "app_controller.h"
#include "compact_search.h"
#include "player_item_grid_widget.h"
#include "player_item_model.h"

namespace {
struct Filter {
  const char *label;
  const char *value;
  const char *icon;
};

constexpr std::array<Filter, 6> Groups{{
    {"All parts", "parts", ":/resources/categories/all.png"},
    {"Relics", "relics", ":/resources/categories/relics.png"},
    {"Mods", "mods", ":/resources/categories/mods.png"},
    {"Arcanes", "arcanes", ":/resources/categories/arcanes.png"},
    {"Misc", "misc", ":/resources/categories/misc.png"},
    {"Sets", "sets", ":/resources/categories/sets.png"},
}};

void updateFilterButtons(QButtonGroup *group) {
  for (auto *button : group->buttons()) {
    const QString label = button->property("label").toString();
    button->setText(button->isChecked() || button->icon().isNull() ? label
                                                                   : QString());
  }
}
} // namespace

InventoryWidget::InventoryWidget(AppController *controller, QWidget *parent)
    : QWidget(parent), controller_(controller),
      items_(new PlayerItemFilterModel(this)),
      grid_(new PlayerItemGridWidget(PlayerItemGridWidget::Kind::Inventory)),
      summary_(new QLabel), emptyState_(new QLabel),
      progress_(new QProgressBar), refresh_(new QPushButton),
      content_(new QStackedLayout) {
  setObjectName("page");
  items_->setSourceModel(controller_->inventoryItems());
  items_->setGroup("parts");
  grid_->setModel(items_);

  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(10, 10, 10, 0);
  layout->setSpacing(8);

  auto *groups = new QHBoxLayout;
  groups->setSpacing(6);
  auto *groupButtons = new QButtonGroup(this);
  groupButtons->setExclusive(true);
  int id = 0;
  for (const auto &[label, value, icon] : Groups) {
    auto *button = new QPushButton;
    button->setObjectName("filterChip");
    button->setCheckable(true);
    button->setProperty("group", value);
    button->setProperty("label", label);
    button->setIcon(QIcon(icon));
    button->setIconSize({22, 22});
    button->setToolTip(label);
    button->setChecked(id == 0);
    groupButtons->addButton(button, id++);
    groups->addWidget(button);
  }
  groups->addStretch();
  auto *compactSearch = new CompactSearch("Search inventory");
  auto *search = compactSearch->editor();
  groups->addWidget(compactSearch);
  refresh_->setObjectName("compactTool");
  refresh_->setIcon(QIcon(":/resources/ui/refresh.png"));
  refresh_->setIconSize({20, 20});
  refresh_->setToolTip("Refresh inventory data");
  groups->addWidget(refresh_);
  layout->addLayout(groups);
  updateFilterButtons(groupButtons);

  progress_->setObjectName("priceProgress");
  progress_->setTextVisible(false);
  progress_->setFixedHeight(2);

  emptyState_->setObjectName("emptyState");
  emptyState_->setAlignment(Qt::AlignCenter);
  emptyState_->setWordWrap(true);

  auto *loading = new QWidget;
  auto *loadingLayout = new QVBoxLayout(loading);
  loadingLayout->addStretch();
  auto *loadingProgress = new QProgressBar;
  loadingProgress->setRange(0, 0);
  loadingProgress->setMaximumWidth(240);
  loadingLayout->addWidget(loadingProgress, 0, Qt::AlignHCenter);
  loadingLayout->addStretch();

  auto *host = new QWidget;
  host->setLayout(content_);
  content_->setContentsMargins(0, 0, 0, 0);
  content_->addWidget(grid_);
  content_->addWidget(loading);
  content_->addWidget(emptyState_);
  auto *frame = new QWidget;
  frame->setObjectName("contentFrame");
  auto *frameLayout = new QVBoxLayout(frame);
  frameLayout->setContentsMargins(0, 0, 0, 0);
  frameLayout->setSpacing(0);
  frameLayout->addWidget(progress_);
  frameLayout->addWidget(host, 1);
  layout->addWidget(frame, 1);
  summary_->setObjectName("inventoryTotals");
  summary_->setAlignment(Qt::AlignRight | Qt::AlignVCenter);
  layout->addWidget(summary_);

  connect(search, &QLineEdit::textChanged, items_,
          &PlayerItemFilterModel::setText);
  connect(search, &QLineEdit::textChanged, this,
          &InventoryWidget::updateContent);
  connect(groupButtons, &QButtonGroup::idClicked, this,
          [this, groupButtons](int buttonId) {
            items_->setGroup(
                groupButtons->button(buttonId)->property("group").toString());
            updateFilterButtons(groupButtons);
            updateContent();
          });
  connect(refresh_, &QPushButton::clicked, this, [this] {
    controller_->refreshInventory();
    grid_->refreshVisibleQuotes();
  });
  connect(grid_, &PlayerItemGridWidget::assetsNeeded, controller_,
          &AppController::resolveAssets);
  connect(grid_, &PlayerItemGridWidget::quotesNeeded, controller_,
          &AppController::resolveMarketQuotes);
  connect(controller_, &AppController::inventoryStateChanged, this,
          &InventoryWidget::updateContent);
  connect(items_, &QAbstractItemModel::modelReset, this,
          &InventoryWidget::updateContent);
  connect(items_, &QAbstractItemModel::rowsInserted, this,
          &InventoryWidget::updateContent);
  connect(items_, &QAbstractItemModel::rowsRemoved, this,
          &InventoryWidget::updateContent);
  updateContent();
}

void InventoryWidget::updateContent() {
  const QJsonObject totals = controller_->inventorySummary();
  summary_->setText(
      QString("%1 item types").arg(totals.value("total").toInt()));
  const bool loading = controller_->inventoryLoading();
  progress_->setRange(0, loading ? 0 : 1);
  if (!loading) {
    progress_->setValue(0);
  }
  refresh_->setEnabled(!loading);
  if (items_->rowCount() > 0) {
    content_->setCurrentIndex(0);
  } else if (loading && !controller_->inventoryLoaded()) {
    content_->setCurrentIndex(1);
  } else {
    emptyState_->setText(controller_->inventoryError().isEmpty()
                             ? "No matching inventory items."
                             : controller_->inventoryError());
    content_->setCurrentIndex(2);
  }
}
