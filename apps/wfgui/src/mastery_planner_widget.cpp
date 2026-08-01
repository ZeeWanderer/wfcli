#include "mastery_planner_widget.h"

#include <QAbstractItemModel>
#include <QButtonGroup>
#include <QHBoxLayout>
#include <QIcon>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QProgressBar>
#include <QPushButton>
#include <QSizePolicy>
#include <QStackedLayout>
#include <QVBoxLayout>

#include <array>
#include <utility>

#include "app_controller.h"
#include "compact_search.h"
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

QWidget *summaryPanel(const QString &title, const QString &icon,
                      QLabel *value) {
  auto *panel = new QWidget;
  panel->setObjectName("summaryPanel");
  panel->setMinimumWidth(0);
  panel->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
  auto *layout = new QVBoxLayout(panel);
  layout->setContentsMargins(0, 0, 0, 8);
  layout->setSpacing(7);
  auto *header = new QWidget;
  header->setObjectName("summaryHeader");
  auto *headerLayout = new QHBoxLayout(header);
  headerLayout->setContentsMargins(8, 4, 8, 4);
  headerLayout->setSpacing(6);
  auto *iconLabel = new QLabel;
  iconLabel->setFixedSize(18, 18);
  iconLabel->setPixmap(QIcon(icon).pixmap(18, 18));
  headerLayout->addWidget(iconLabel);
  auto *heading = new QLabel(title);
  heading->setObjectName("summaryHeading");
  headerLayout->addWidget(heading);
  headerLayout->addStretch();
  value->setObjectName("summaryValue");
  value->setMinimumWidth(0);
  value->setAlignment(Qt::AlignCenter);
  value->setWordWrap(true);
  value->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
  layout->addWidget(header);
  layout->addWidget(value);
  return panel;
}
} // namespace

MasteryPlannerWidget::MasteryPlannerWidget(AppController *controller,
                                           QWidget *parent)
    : QWidget(parent), controller_(controller),
      items_(new PlayerItemFilterModel(this)),
      grid_(new PlayerItemGridWidget(PlayerItemGridWidget::Kind::Mastery)),
      rank_(new QLabel), completion_(new QLabel), gameContent_(new QLabel),
      starChart_(new QLabel), intrinsics_(new QLabel), emptyState_(new QLabel),
      completionBar_(new QProgressBar), loadingBar_(new QProgressBar),
      refresh_(new QPushButton), content_(new QStackedLayout) {
  setObjectName("page");
  items_->setSourceModel(controller_->masteryItems());
  items_->setMode("easy");
  grid_->setModel(items_);

  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(10, 10, 10, 0);
  layout->setSpacing(9);

  auto *header = new QHBoxLayout;
  rank_->setObjectName("masteryRank");
  header->addWidget(rank_);
  auto *rankProgress = new QVBoxLayout;
  completion_->setObjectName("secondaryText");
  rankProgress->addWidget(completion_);
  completionBar_->setTextVisible(false);
  completionBar_->setRange(0, 100);
  rankProgress->addWidget(completionBar_);
  header->addLayout(rankProgress, 1);
  auto *compactSearch = new CompactSearch("Filter equipment");
  auto *search = compactSearch->editor();
  header->addWidget(compactSearch);
  refresh_->setObjectName("compactTool");
  refresh_->setIcon(QIcon(":/resources/ui/refresh.png"));
  refresh_->setIconSize({20, 20});
  refresh_->setToolTip("Refresh mastery data");
  header->addWidget(refresh_);
  layout->addLayout(header);

  auto *summary = new QHBoxLayout;
  summary->setSpacing(12);
  summary->addWidget(summaryPanel("Game content",
                                  ":/resources/ui/summary_game.png",
                                  gameContent_),
                     1);
  summary->addWidget(
      summaryPanel("Star chart", ":/resources/ui/summary_star.png", starChart_),
      1);
  summary->addWidget(summaryPanel("Intrinsics",
                                  ":/resources/ui/summary_intrinsics.png",
                                  intrinsics_),
                     1);
  layout->addLayout(summary);

  auto *sectionTitle = new QLabel("Best ways to level up mastery");
  sectionTitle->setObjectName("sectionTitle");
  layout->addWidget(sectionTitle);

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
  rank_->setText(QString::number(summary.value("player_level").toInt()));
  completion_->setText(QString("%1%  ·  %2 / %3 equipment mastered")
                           .arg(percent)
                           .arg(mastered)
                           .arg(total));
  completionBar_->setValue(percent);
  const auto categoryText = [](const QJsonObject &value) {
    const int mastered = value.value("mastered").toInt();
    const int total = value.value("total").toInt();
    const int percent = total > 0 ? mastered * 100 / total : 0;
    return QString("%1%  %2 / %3").arg(percent).arg(mastered).arg(total);
  };
  gameContent_->setText(
      QString("Warframes / Archwings  %1\nWeapons  %2\nCompanions  %3")
          .arg(categoryText(summary.value("warframes").toObject()))
          .arg(categoryText(summary.value("weapons").toObject()))
          .arg(categoryText(summary.value("companions").toObject())));
  const QJsonObject star = summary.value("star_chart").toObject();
  const auto observed = [](const QJsonObject &value) {
    const int current = value.value("current").toInt();
    return value.value("total").isDouble()
               ? QString("%1 / %2").arg(current).arg(
                     value.value("total").toInt())
               : QString::number(current);
  };
  starChart_->setText(
      QString("Normal  %1\nJunctions  %2\nSteel Path  %3\nSteel junctions  %4")
          .arg(observed(star.value("normal").toObject()))
          .arg(observed(star.value("junctions").toObject()))
          .arg(observed(star.value("steel").toObject()))
          .arg(observed(star.value("steel_junctions").toObject())));
  const QJsonObject intrinsic = summary.value("intrinsics").toObject();
  const auto progressText = [](const QJsonObject &value) {
    return QString("%1 / %2")
        .arg(value.value("current").toInt())
        .arg(value.value("total").toInt());
  };
  intrinsics_->setText(
      QString("Railjack  %1\nDuviri  %2")
          .arg(progressText(intrinsic.value("railjack").toObject()))
          .arg(progressText(intrinsic.value("duviri").toObject())));

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
