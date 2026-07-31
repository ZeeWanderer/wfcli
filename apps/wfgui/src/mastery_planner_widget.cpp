#include "mastery_planner_widget.h"

#include <QAbstractItemModel>
#include <QButtonGroup>
#include <QHBoxLayout>
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
#include "player_item_grid_widget.h"
#include "player_item_model.h"

namespace {
constexpr std::array<std::pair<const char *, const char *>, 3> Modes{{
    {"Easy", "easy"},
    {"From relics", "relics"},
    {"With platinum", "platinum"},
}};
constexpr std::array<std::pair<const char *, const char *>, 4> Groups{{
    {"All", "all"},
    {"Warframes", "warframes"},
    {"Weapons", "weapons"},
    {"Companions", "companions"},
}};

QWidget *summaryPanel(const QString &title, QLabel *value) {
  auto *panel = new QWidget;
  panel->setObjectName("summaryPanel");
  auto *layout = new QVBoxLayout(panel);
  layout->setContentsMargins(14, 10, 14, 10);
  auto *heading = new QLabel(title);
  heading->setObjectName("secondaryText");
  value->setObjectName("summaryValue");
  layout->addWidget(heading);
  layout->addWidget(value);
  return panel;
}
} // namespace

MasteryPlannerWidget::MasteryPlannerWidget(AppController *controller,
                                           QWidget *parent)
    : QWidget(parent), controller_(controller),
      items_(new PlayerItemFilterModel(this)),
      grid_(new PlayerItemGridWidget(PlayerItemGridWidget::Kind::Mastery)),
      rank_(new QLabel), completion_(new QLabel), warframes_(new QLabel),
      weapons_(new QLabel), companions_(new QLabel), emptyState_(new QLabel),
      completionBar_(new QProgressBar), loadingBar_(new QProgressBar),
      refresh_(new QPushButton("Refresh")), content_(new QStackedLayout) {
  setObjectName("page");
  items_->setSourceModel(controller_->masteryItems());
  items_->setMode("easy");
  grid_->setModel(items_);

  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(24, 22, 24, 0);
  layout->setSpacing(14);

  auto *header = new QHBoxLayout;
  auto *heading = new QVBoxLayout;
  auto *title = new QLabel("Mastery Planner");
  title->setObjectName("pageTitle");
  rank_->setObjectName("secondaryText");
  heading->addWidget(title);
  heading->addWidget(rank_);
  header->addLayout(heading);
  header->addStretch();
  auto *search = new QLineEdit;
  search->setPlaceholderText("Filter equipment");
  search->setClearButtonEnabled(true);
  search->setMinimumWidth(260);
  search->setMaximumWidth(360);
  header->addWidget(search);
  header->addWidget(refresh_);
  layout->addLayout(header);

  auto *summary = new QHBoxLayout;
  completion_->setObjectName("summaryValue");
  auto *completionPanel = new QWidget;
  completionPanel->setObjectName("summaryPanel");
  auto *completionLayout = new QVBoxLayout(completionPanel);
  completionLayout->setContentsMargins(14, 10, 14, 10);
  auto *completionTitle = new QLabel("Equipment completion");
  completionTitle->setObjectName("secondaryText");
  completionBar_->setTextVisible(false);
  completionBar_->setRange(0, 100);
  completionLayout->addWidget(completionTitle);
  completionLayout->addWidget(completion_);
  completionLayout->addWidget(completionBar_);
  summary->addWidget(completionPanel, 2);
  summary->addWidget(summaryPanel("Warframes / Archwings", warframes_), 1);
  summary->addWidget(summaryPanel("Weapons", weapons_), 1);
  summary->addWidget(summaryPanel("Companions", companions_), 1);
  layout->addLayout(summary);

  auto *filters = new QHBoxLayout;
  filters->setSpacing(6);
  auto *modeButtons = new QButtonGroup(this);
  modeButtons->setExclusive(true);
  int id = 0;
  for (const auto &[label, value] : Modes) {
    auto *button = new QPushButton(label);
    button->setCheckable(true);
    button->setProperty("mode", value);
    button->setChecked(id == 0);
    modeButtons->addButton(button, id++);
    filters->addWidget(button);
  }
  filters->addSpacing(12);
  auto *groupButtons = new QButtonGroup(this);
  groupButtons->setExclusive(true);
  id = 0;
  for (const auto &[label, value] : Groups) {
    auto *button = new QPushButton(label);
    button->setCheckable(true);
    button->setProperty("group", value);
    button->setChecked(id == 0);
    groupButtons->addButton(button, id++);
    filters->addWidget(button);
  }
  filters->addStretch();
  layout->addLayout(filters);

  loadingBar_->setObjectName("priceProgress");
  loadingBar_->setTextVisible(false);
  loadingBar_->setFixedHeight(2);
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
  frameLayout->addWidget(loadingBar_);
  frameLayout->addWidget(host, 1);
  layout->addWidget(frame, 1);

  connect(search, &QLineEdit::textChanged, items_,
          &PlayerItemFilterModel::setText);
  connect(search, &QLineEdit::textChanged, this,
          &MasteryPlannerWidget::updateContent);
  connect(modeButtons, &QButtonGroup::idClicked, this,
          [this, modeButtons](int buttonId) {
            items_->setMode(
                modeButtons->button(buttonId)->property("mode").toString());
            updateContent();
          });
  connect(groupButtons, &QButtonGroup::idClicked, this,
          [this, groupButtons](int buttonId) {
            items_->setGroup(
                groupButtons->button(buttonId)->property("group").toString());
            updateContent();
          });
  connect(refresh_, &QPushButton::clicked, controller_,
          &AppController::refreshMastery);
  connect(grid_, &PlayerItemGridWidget::assetsNeeded, controller_,
          &AppController::resolveAssets);
  connect(controller_, &AppController::masteryStateChanged, this,
          &MasteryPlannerWidget::updateContent);
  connect(items_, &QAbstractItemModel::modelReset, this,
          &MasteryPlannerWidget::updateContent);
  connect(items_, &QAbstractItemModel::rowsInserted, this,
          &MasteryPlannerWidget::updateContent);
  connect(items_, &QAbstractItemModel::rowsRemoved, this,
          &MasteryPlannerWidget::updateContent);
  updateContent();
}

void MasteryPlannerWidget::updateContent() {
  const QJsonObject summary = controller_->masterySummary();
  const int mastered = summary.value("mastered").toInt();
  const int total = summary.value("total").toInt();
  const int percent = summary.value("percent").toInt();
  rank_->setText(QString("Mastery Rank %1")
                     .arg(summary.value("player_level").toInt()));
  completion_->setText(QString("%1% · %2 / %3").arg(percent).arg(mastered).arg(total));
  completionBar_->setValue(percent);
  const auto categoryText = [](const QJsonObject &value) {
    return QString("%1 / %2")
        .arg(value.value("mastered").toInt())
        .arg(value.value("total").toInt());
  };
  warframes_->setText(categoryText(summary.value("warframes").toObject()));
  weapons_->setText(categoryText(summary.value("weapons").toObject()));
  companions_->setText(categoryText(summary.value("companions").toObject()));

  const bool loading = controller_->masteryLoading();
  loadingBar_->setRange(0, loading ? 0 : 1);
  if (!loading) {
    loadingBar_->setValue(0);
  }
  refresh_->setEnabled(!loading);
  if (items_->rowCount() > 0) {
    content_->setCurrentIndex(0);
  } else if (loading && !controller_->masteryLoaded()) {
    content_->setCurrentIndex(1);
  } else {
    emptyState_->setText(controller_->masteryError().isEmpty()
                             ? "No matching mastery items."
                             : controller_->masteryError());
    content_->setCurrentIndex(2);
  }
}
