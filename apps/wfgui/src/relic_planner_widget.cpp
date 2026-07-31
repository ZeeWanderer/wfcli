#include "relic_planner_widget.h"

#include <QAbstractItemModel>
#include <QButtonGroup>
#include <QCheckBox>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QProgressBar>
#include <QPushButton>
#include <QScrollArea>
#include <QStackedLayout>
#include <QVBoxLayout>

#include <array>
#include <utility>

#include "app_controller.h"
#include "relic_grid_widget.h"
#include "relic_model.h"

namespace {
constexpr std::array<std::pair<const char *, const char *>, 5> Eras{{
    {"All", "all"},
    {"Lith", "lith"},
    {"Meso", "meso"},
    {"Neo", "neo"},
    {"Axi", "axi"},
}};
} // namespace

RelicPlannerWidget::RelicPlannerWidget(AppController *controller,
                                       QWidget *parent)
    : QWidget(parent), controller_(controller), traceCount_(new QLabel),
      priceProgress_(new QProgressBar), emptyState_(new QLabel),
      relics_(new RelicGridWidget), refresh_(new QPushButton("Refresh")),
      content_(new QStackedLayout) {
  setObjectName("page");
  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(24, 22, 24, 0);
  layout->setSpacing(16);

  auto *header = new QHBoxLayout;
  auto *heading = new QVBoxLayout;
  auto *title = new QLabel("Relic Planner");
  title->setObjectName("pageTitle");
  traceCount_->setObjectName("secondaryText");
  heading->addWidget(title);
  heading->addWidget(traceCount_);
  header->addLayout(heading);
  header->addStretch();

  auto *filter = new QLineEdit;
  filter->setPlaceholderText("Filter relics");
  filter->setClearButtonEnabled(true);
  filter->setMinimumWidth(260);
  filter->setMaximumWidth(360);
  header->addWidget(filter);
  header->addWidget(refresh_);
  layout->addLayout(header);

  auto *eras = new QHBoxLayout;
  eras->setSpacing(6);
  auto *eraGroup = new QButtonGroup(this);
  eraGroup->setExclusive(true);
  int eraId = 0;
  for (const auto &[label, value] : Eras) {
    auto *button = new QPushButton(label);
    button->setCheckable(true);
    button->setProperty("era", value);
    eraGroup->addButton(button, eraId++);
    eras->addWidget(button);
  }
  eras->addStretch();
  auto *onlyOwned = new QCheckBox("Only owned");
  onlyOwned->setChecked(controller_->onlyOwned());
  eras->addWidget(onlyOwned);
  layout->addLayout(eras);

  priceProgress_->setObjectName("priceProgress");
  priceProgress_->setRange(0, 1);
  priceProgress_->setValue(0);
  priceProgress_->setTextVisible(false);
  priceProgress_->setFixedHeight(2);

  relics_->setModel(controller_->relics());
  auto *scroll = new QScrollArea;
  scroll->setObjectName("relicScroll");
  scroll->setWidgetResizable(true);
  scroll->setFrameShape(QFrame::NoFrame);
  scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
  scroll->setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOn);
  scroll->setWidget(relics_);

  auto *loading = new QWidget;
  auto *loadingLayout = new QVBoxLayout(loading);
  loadingLayout->addStretch();
  auto *progress = new QProgressBar;
  progress->setRange(0, 0);
  progress->setMaximumWidth(240);
  loadingLayout->addWidget(progress, 0, Qt::AlignHCenter);
  loadingLayout->addStretch();

  emptyState_->setObjectName("emptyState");
  emptyState_->setAlignment(Qt::AlignCenter);
  emptyState_->setWordWrap(true);

  auto *contentFrame = new QWidget;
  contentFrame->setObjectName("contentFrame");
  auto *contentHost = new QWidget;
  contentHost->setLayout(content_);
  content_->setContentsMargins(0, 0, 0, 0);
  content_->addWidget(scroll);
  content_->addWidget(loading);
  content_->addWidget(emptyState_);
  auto *contentLayout = new QVBoxLayout(contentFrame);
  contentLayout->setContentsMargins(0, 0, 0, 0);
  contentLayout->setSpacing(0);
  contentLayout->addWidget(priceProgress_);
  contentLayout->addWidget(contentHost, 1);
  layout->addWidget(contentFrame, 1);

  connect(filter, &QLineEdit::textChanged, controller_,
          &AppController::setFilterText);
  connect(refresh_, &QPushButton::clicked, controller_,
          &AppController::refresh);
  connect(onlyOwned, &QCheckBox::toggled, controller_,
          &AppController::setOnlyOwned);
  connect(
      eraGroup, &QButtonGroup::idClicked, this, [controller, eraGroup](int id) {
        controller->selectEra(eraGroup->button(id)->property("era").toString());
      });
  connect(controller_, &AppController::selectedEraChanged, this,
          &RelicPlannerWidget::updateEra);
  connect(controller_, &AppController::onlyOwnedChanged, this,
          &RelicPlannerWidget::updateContent);
  connect(controller_, &AppController::loadingChanged, this,
          &RelicPlannerWidget::updateContent);
  connect(controller_, &AppController::pricingChanged, this,
          &RelicPlannerWidget::updateContent);
  connect(controller_, &AppController::errorChanged, this,
          &RelicPlannerWidget::updateContent);
  connect(controller_, &AppController::traceCountChanged, this,
          &RelicPlannerWidget::updateContent);
  connect(controller_->relics(), &QAbstractItemModel::modelReset, this,
          &RelicPlannerWidget::updateContent);
  connect(controller_->relics(), &QAbstractItemModel::rowsInserted, this,
          &RelicPlannerWidget::updateContent);
  connect(controller_->relics(), &QAbstractItemModel::rowsRemoved, this,
          &RelicPlannerWidget::updateContent);

  updateEra();
  updateContent();
}

void RelicPlannerWidget::updateContent() {
  traceCount_->setText(
      QString("%1 Void Traces").arg(controller_->traceCount()));
  const bool pricing =
      controller_->pricing() && controller_->relics()->rowCount() > 0;
  priceProgress_->setRange(0, pricing ? 0 : 1);
  if (!pricing) {
    priceProgress_->setValue(0);
  }
  refresh_->setEnabled(!controller_->loading());

  const int count = controller_->relics()->rowCount();
  if (count > 0) {
    content_->setCurrentIndex(0);
  } else if (controller_->loading()) {
    content_->setCurrentIndex(1);
  } else {
    emptyState_->setText(
        controller_->error().isEmpty()
            ? (controller_->onlyOwned()
                   ? QString("No owned relics found for this era.")
                   : QString("No relics found for this era."))
            : controller_->error());
    content_->setCurrentIndex(2);
  }
}

void RelicPlannerWidget::updateEra() {
  for (QPushButton *button : findChildren<QPushButton *>()) {
    if (button->property("era").toString() == controller_->selectedEra()) {
      button->setChecked(true);
      break;
    }
  }
}
