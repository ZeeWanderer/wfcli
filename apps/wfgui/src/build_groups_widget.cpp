#include "build_groups_widget.h"

#include <QAbstractItemModel>
#include <QCheckBox>
#include <QFrame>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QLabel>
#include <QLineEdit>
#include <QListView>
#include <QListWidget>
#include <QMessageBox>
#include <QPixmap>
#include <QPushButton>
#include <QScrollArea>
#include <QSplitter>
#include <QStackedWidget>
#include <QStringList>
#include <QVBoxLayout>

#include "app_controller.h"
#include "build_group_model.h"
#include "build_topology_widget.h"

namespace {
QString memberLabel(const QJsonObject &member) {
  const QString name = member.value("name").toString("Build");
  if (member.value("kind").toString() == "player_config") {
    return name + "\nCurrent configuration snapshot";
  }
  const QJsonObject identity =
      member.value("snapshot").toObject().value("identity").toObject();
  const QString source = identity.value("source").toString(
      member.value("source").toString());
  return source.isEmpty() ? name : name + "\n" + source;
}

QString planLabel(const QJsonObject &result) {
  if (result.value("status").toString() == "ready") {
    return QString("Final polarity plan\n%1 Forma · %2 changes")
        .arg(result.value("forma_cost").toInt())
        .arg(result.value("change_count").toInt());
  }
  return "Plan result\nBlocked";
}
} // namespace

BuildGroupsWidget::BuildGroupsWidget(AppController *controller, QWidget *parent)
    : QWidget(parent), controller_(controller), pages_(new QStackedWidget),
      editor_(new QWidget), emptyPage_(new QWidget), groups_(new QListView),
      emptyTitle_(new QLabel), emptyDescription_(new QLabel),
      emptyEquipment_(new QPushButton("Choose equipment")),
      emptyDiscover_(new QPushButton("Discover builds")),
      name_(new QLineEdit), meta_(new QLabel),
      preserveSlots_(new QCheckBox("Preserve source slot positions")),
      allowOmni_(new QCheckBox("Allow Omni Forma")),
      allowUmbral_(new QCheckBox("Allow Umbral Forma")),
      members_(new QListWidget), topology_(new BuildTopologyWidget(controller)),
      state_(new QLabel), save_(new QPushButton("Save")),
      remove_(new QPushButton("Remove member")),
      delete_(new QPushButton("Delete group")),
      calculate_(new QPushButton("Calculate")),
      equipment_(new QPushButton("Add current configuration")),
      discover_(new QPushButton("Find builds")) {
  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(0, 0, 0, 0);
  layout->addWidget(pages_);

  auto *editorLayout = new QVBoxLayout(editor_);
  editorLayout->setContentsMargins(0, 0, 0, 0);
  auto *splitter = new QSplitter;
  splitter->setObjectName("buildGroupsSplit");
  splitter->setChildrenCollapsible(false);
  editorLayout->addWidget(splitter);
  editor_->setObjectName("buildGroupEditor");
  pages_->addWidget(editor_);

  auto *rail = new QFrame;
  rail->setObjectName("buildPane");
  rail->setMinimumWidth(220);
  auto *railLayout = new QVBoxLayout(rail);
  railLayout->setContentsMargins(8, 8, 8, 8);
  auto *heading = new QLabel("Saved groups");
  heading->setObjectName("sectionTitle");
  railLayout->addWidget(heading);
  groups_->setObjectName("buildGroupList");
  groups_->setModel(controller_->buildGroups());
  groups_->setSelectionMode(QAbstractItemView::SingleSelection);
  groups_->setUniformItemSizes(true);
  groups_->setSpacing(4);
  railLayout->addWidget(groups_, 1);
  splitter->addWidget(rail);

  auto *detail = new QFrame;
  detail->setObjectName("buildPane");
  detail->setMinimumWidth(480);
  auto *detailLayout = new QVBoxLayout(detail);
  detailLayout->setContentsMargins(12, 10, 12, 10);
  detailLayout->setSpacing(8);
  auto *nameRow = new QHBoxLayout;
  name_->setPlaceholderText("Group name");
  nameRow->addWidget(name_, 1);
  save_->setObjectName("primaryAction");
  nameRow->addWidget(save_);
  detailLayout->addLayout(nameRow);
  meta_->setObjectName("secondaryText");
  detailLayout->addWidget(meta_);
  auto *options = new QHBoxLayout;
  options->addWidget(preserveSlots_);
  options->addWidget(allowOmni_);
  options->addWidget(allowUmbral_);
  options->addStretch();
  detailLayout->addLayout(options);

  auto *workspace = new QSplitter(Qt::Vertical);
  workspace->setChildrenCollapsible(false);
  members_->setObjectName("buildGroupMembers");
  members_->setSelectionMode(QAbstractItemView::SingleSelection);
  workspace->addWidget(members_);
  auto *scroll = new QScrollArea;
  scroll->setObjectName("buildTopologyScroll");
  scroll->setWidgetResizable(true);
  scroll->setFrameShape(QFrame::NoFrame);
  scroll->setWidget(topology_);
  workspace->addWidget(scroll);
  workspace->setStretchFactor(0, 1);
  workspace->setStretchFactor(1, 3);
  detailLayout->addWidget(workspace, 1);

  state_->setObjectName("secondaryText");
  state_->setWordWrap(true);
  detailLayout->addWidget(state_);
  auto *actions = new QHBoxLayout;
  delete_->setProperty("destructive", true);
  actions->addWidget(delete_);
  actions->addStretch();
  actions->addWidget(remove_);
  actions->addWidget(equipment_);
  actions->addWidget(discover_);
  calculate_->setObjectName("primaryAction");
  actions->addWidget(calculate_);
  detailLayout->addLayout(actions);
  splitter->addWidget(detail);
  splitter->setStretchFactor(0, 0);
  splitter->setStretchFactor(1, 1);
  splitter->setSizes({260, 760});

  emptyPage_->setObjectName("buildGroupEmpty");
  auto *emptyLayout = new QVBoxLayout(emptyPage_);
  emptyLayout->setContentsMargins(24, 24, 24, 24);
  emptyLayout->setSpacing(8);
  emptyLayout->addStretch();
  auto *emptyIcon = new QLabel;
  emptyIcon->setObjectName("emptyStateIcon");
  emptyIcon->setAlignment(Qt::AlignCenter);
  emptyIcon->setPixmap(QPixmap(":/resources/ui/nav_builds.png")
                           .scaled(48, 48, Qt::KeepAspectRatio,
                                   Qt::SmoothTransformation));
  emptyLayout->addWidget(emptyIcon);
  emptyTitle_->setObjectName("sectionTitle");
  emptyTitle_->setProperty("testId", "buildGroupEmptyTitle");
  emptyTitle_->setProperty("emptyState", true);
  emptyTitle_->setAlignment(Qt::AlignCenter);
  emptyLayout->addWidget(emptyTitle_);
  emptyDescription_->setObjectName("secondaryText");
  emptyDescription_->setAlignment(Qt::AlignCenter);
  emptyDescription_->setWordWrap(true);
  emptyLayout->addWidget(emptyDescription_);
  auto *emptyActions = new QHBoxLayout;
  emptyActions->addStretch();
  emptyEquipment_->setObjectName("primaryAction");
  emptyEquipment_->setProperty("testId", "buildGroupEmptyEquipment");
  emptyEquipment_->setProperty("emptyStateAction", true);
  emptyActions->addWidget(emptyEquipment_);
  emptyDiscover_->setObjectName("textAction");
  emptyDiscover_->setProperty("testId", "buildGroupEmptyDiscover");
  emptyActions->addWidget(emptyDiscover_);
  emptyActions->addStretch();
  emptyLayout->addLayout(emptyActions);
  emptyLayout->addStretch();
  pages_->addWidget(emptyPage_);

  connect(groups_->selectionModel(), &QItemSelectionModel::currentChanged,
          this, [this](const QModelIndex &index) { selectGroupIndex(index); });
  connect(members_, &QListWidget::currentRowChanged, this,
          &BuildGroupsWidget::selectMember);
  connect(save_, &QPushButton::clicked, this, &BuildGroupsWidget::save);
  connect(remove_, &QPushButton::clicked, this,
          &BuildGroupsWidget::removeMember);
  connect(delete_, &QPushButton::clicked, this,
          &BuildGroupsWidget::deleteGroup);
  connect(calculate_, &QPushButton::clicked, this,
          &BuildGroupsWidget::calculate);
  connect(equipment_, &QPushButton::clicked, this, [this] {
    emit equipmentRequested(group_.value("definition_id").toString(),
                            group_.value("instance_id").toString());
  });
  connect(discover_, &QPushButton::clicked, this, [this] {
    emit discoverRequested(group_.value("definition_id").toString());
  });
  connect(emptyEquipment_, &QPushButton::clicked, this,
          [this] {
            if (!controller_->buildGroupsError().isEmpty()) {
              controller_->refreshBuildGroups();
            } else {
              emit equipmentRequested(QString(), QString());
            }
          });
  connect(emptyDiscover_, &QPushButton::clicked, this,
          [this] { emit discoverRequested(QString()); });
  connect(controller_, &AppController::buildGroupsStateChanged, this,
          [this] {
            restoreSelection();
            rebuild();
          });
  connect(controller_, &AppController::buildGroupChanged, this,
          [this](const QString &action, const QJsonObject &group) {
            if (group.value("id").toString() == selectedId_) {
              if (action == "planned") {
                planning_ = false;
              }
              group_ = controller_->buildGroup(selectedId_);
              rebuild();
            }
          });
  connect(controller_, &AppController::buildGroupRequestFinished, this,
          [this](const QJsonObject &request, const QJsonObject &group) {
            const QString op = request.value("op").toString();
            const QString id = request.value("group_id").toString(
                group.value("id").toString());
            if (op.startsWith("build_group_") && id == selectedId_) {
              if (op == "build_group_plan") {
                planning_ = false;
              }
              group_ = controller_->buildGroup(selectedId_);
              rebuild();
            }
          });
  connect(controller_, &AppController::buildGroupRequestFailed, this,
          [this](const QJsonObject &request, const QString &) {
            if (request.value("op").toString() == "build_group_plan" &&
                request.value("group_id").toString() == selectedId_) {
              planning_ = false;
              rebuild();
            }
          });
  rebuild();
}

void BuildGroupsWidget::selectGroup(const QString &id) {
  planning_ = false;
  selectedId_ = id;
  restoreSelection();
  if (!id.isEmpty()) {
    controller_->requestBuildGroup(id);
  }
}

void BuildGroupsWidget::restoreSelection() {
  QAbstractItemModel *model = controller_->buildGroups();
  QModelIndex selected;
  for (int row = 0; row < model->rowCount(); ++row) {
    const QModelIndex candidate = model->index(row, 0);
    if (candidate.data(BuildGroupModel::IdRole).toString() == selectedId_) {
      selected = candidate;
      break;
    }
  }
  if (!selected.isValid() && model->rowCount() > 0) {
    selected = model->index(0, 0);
  }
  if (selected.isValid()) {
    groups_->setCurrentIndex(selected);
    selectGroupIndex(selected);
  } else {
    selectedId_.clear();
    group_ = {};
  }
}

void BuildGroupsWidget::selectGroupIndex(const QModelIndex &index) {
  if (!index.isValid()) {
    return;
  }
  const QString id = index.data(BuildGroupModel::IdRole).toString();
  const bool changed = selectedId_ != id;
  selectedId_ = id;
  group_ = controller_->buildGroup(id);
  rebuild();
  if (changed || (group_.value("member_count").toInt() > 0 &&
                  group_.value("members").toArray().at(0)
                      .toObject()
                      .value("snapshot")
                      .isUndefined())) {
    controller_->requestBuildGroup(id);
  }
}

void BuildGroupsWidget::rebuild() {
  const bool hasGroup = !group_.isEmpty();
  const int count = controller_->buildGroups()->rowCount();
  const bool loaded = controller_->buildGroupsLoaded();
  const QString loadError = controller_->buildGroupsError();
  pages_->setCurrentWidget(count == 0 ? emptyPage_ : editor_);
  emptyTitle_->setText(!loadError.isEmpty() ? "Could not load build groups"
                       : loaded              ? "No build groups"
                                             : "Loading build groups");
  emptyDescription_->setText(
      !loadError.isEmpty()
          ? loadError
          : loaded
                ? "Choose owned equipment, then add builds to plan its polarities."
                : QString());
  emptyDescription_->setVisible(loaded || !loadError.isEmpty());
  emptyEquipment_->setText(loadError.isEmpty() ? "Choose equipment" : "Retry");
  emptyEquipment_->setVisible(loaded || !loadError.isEmpty());
  emptyDiscover_->setVisible(loaded && loadError.isEmpty());
  name_->setEnabled(hasGroup);
  preserveSlots_->setEnabled(hasGroup);
  allowOmni_->setEnabled(hasGroup);
  allowUmbral_->setEnabled(hasGroup);
  save_->setEnabled(hasGroup && !controller_->buildGroupsLoading());
  delete_->setEnabled(hasGroup && !controller_->buildGroupsLoading());
  equipment_->setEnabled(hasGroup && !group_.value("instance_id").toString().isEmpty());
  discover_->setEnabled(hasGroup);
  calculate_->setEnabled(
      hasGroup && !group_.value("baseline").toObject().isEmpty() &&
      group_.value("member_count").toInt() > 0 &&
      !controller_->buildGroupsLoading() && !planning_);
  calculate_->setText(planning_ ? "Calculating..." : "Calculate");

  if (!hasGroup) {
    name_->clear();
    meta_->clear();
    members_->clear();
    topology_->clear();
    state_->setText(controller_->buildGroupsError());
    remove_->setEnabled(false);
    return;
  }

  if (!name_->hasFocus()) {
    name_->setText(group_.value("name").toString());
  }
  const QJsonObject options = group_.value("options").toObject();
  preserveSlots_->setChecked(options.value("preserve_source_slots").toBool(true));
  allowOmni_->setChecked(options.value("allow_omni").toBool(false));
  allowUmbral_->setChecked(options.value("allow_umbral_forma").toBool(false));
  meta_->setText(QString("%1 member%2  ·  revision %3")
                     .arg(group_.value("member_count").toInt())
                     .arg(group_.value("member_count").toInt() == 1 ? "" : "s")
                     .arg(group_.value("revision").toInteger()));

  const QString selectedMember =
      members_->currentItem()
          ? members_->currentItem()->data(Qt::UserRole).toMap().value("id").toString()
          : QString();
  members_->blockSignals(true);
  members_->clear();
  int selectedRow = -1;
  for (const QJsonValue &value : group_.value("members").toArray()) {
    const QJsonObject member = value.toObject();
    auto *item = new QListWidgetItem(memberLabel(member), members_);
    item->setData(Qt::UserRole, member.toVariantMap());
    if (member.value("id").toString() == selectedMember) {
      selectedRow = members_->count() - 1;
    }
  }
  const QJsonObject plan = group_.value("plan_result").toObject();
  if (!plan.isEmpty()) {
    QJsonObject itemData{{"id", "__plan_result__"},
                         {"kind", "plan_result"},
                         {"result", plan}};
    auto *item = new QListWidgetItem(planLabel(plan), members_);
    item->setData(Qt::UserRole, itemData.toVariantMap());
    if (selectedMember == "__plan_result__") {
      selectedRow = members_->count() - 1;
    }
  }
  if (selectedRow < 0 && members_->count() > 0) {
    selectedRow = 0;
  }
  members_->setCurrentRow(selectedRow);
  members_->blockSignals(false);
  selectMember(selectedRow);

  const QString error = controller_->buildGroupsError();
  const QString counts = QString("%1 source build%2 · %3 current configuration%4")
                             .arg(group_.value("source_member_count").toInt())
                             .arg(group_.value("source_member_count").toInt() == 1
                                      ? ""
                                      : "s")
                             .arg(group_.value("config_member_count").toInt())
                             .arg(group_.value("config_member_count").toInt() == 1
                                      ? ""
                                      : "s");
  QString result = "Not calculated";
  if (group_.value("baseline").toObject().isEmpty()) {
    result = "Choose an owned equipment copy before calculating";
  } else if (group_.value("member_count").toInt() == 0) {
    result = "Add a build or current configuration before calculating";
  } else if (planning_) {
    result = "Calculating minimum Forma plan";
  } else if (plan.value("status").toString() == "ready") {
    result = QString("Minimum %1 Forma · %2 polarity change%3")
                 .arg(plan.value("forma_cost").toInt())
                 .arg(plan.value("change_count").toInt())
                 .arg(plan.value("change_count").toInt() == 1 ? "" : "s");
  } else if (plan.value("status").toString() == "blocked") {
    result = "Plan blocked: " + plan.value("reason").toVariant().toString();
  }
  QStringList stateLines{counts, result};
  int operation = 1;
  for (const QJsonValue &value : plan.value("changes").toArray()) {
    const QJsonObject change = value.toObject();
    stateLines.append(QString("%1. %2: %3 -> %4")
                          .arg(operation++)
                          .arg(change.value("label").toString(
                              change.value("slot_id").toString()))
                          .arg(change.value("before").toString("none"))
                          .arg(change.value("polarity").toString("none")));
  }
  state_->setText(error.isEmpty() ? stateLines.join('\n') : error);
}

void BuildGroupsWidget::selectMember(int row) {
  QListWidgetItem *item = members_->item(row);
  remove_->setEnabled(item && !controller_->buildGroupsLoading());
  if (!item) {
    QJsonObject snapshot = group_.value("baseline").toObject();
    snapshot.insert("config", QJsonObject{{"upgrade_slots", QJsonArray{}}});
    if (snapshot.value("topology").isObject()) {
      topology_->setPlayerSnapshot(snapshot);
    } else {
      topology_->clear();
    }
    return;
  }
  const QJsonObject member =
      QJsonObject::fromVariantMap(item->data(Qt::UserRole).toMap());
  if (member.value("kind").toString() == "plan_result") {
    remove_->setEnabled(false);
    topology_->setPlanResult(member.value("result").toObject(),
                             group_.value("baseline").toObject());
    return;
  }
  const QJsonObject snapshot = member.value("snapshot").toObject();
  if (snapshot.isEmpty()) {
    topology_->clear();
  } else if (member.value("kind").toString() == "player_config") {
    QJsonObject merged = group_.value("baseline").toObject();
    merged.insert("config", snapshot.value("config"));
    topology_->setPlayerSnapshot(merged);
  } else {
    topology_->setSourceRevision(snapshot, group_.value("baseline").toObject());
  }
}

void BuildGroupsWidget::save() {
  if (group_.isEmpty()) {
    return;
  }
  controller_->updateBuildGroup(
      selectedId_, group_.value("revision").toInteger(),
      {{"name", name_->text().trimmed()},
       {"options",
        QJsonObject{{"preserve_source_slots", preserveSlots_->isChecked()},
                    {"allow_omni", allowOmni_->isChecked()},
                    {"allow_umbral_forma", allowUmbral_->isChecked()}}}});
}

void BuildGroupsWidget::removeMember() {
  QListWidgetItem *item = members_->currentItem();
  if (!item || group_.isEmpty()) {
    return;
  }
  controller_->removeBuildGroupMember(
      selectedId_, group_.value("revision").toInteger(),
      item->data(Qt::UserRole).toMap().value("id").toString());
}

void BuildGroupsWidget::deleteGroup() {
  if (group_.isEmpty() ||
      QMessageBox::question(this, "Delete build group",
                            QString("Delete %1?").arg(group_.value("name").toString())) !=
          QMessageBox::Yes) {
    return;
  }
  controller_->deleteBuildGroup(selectedId_,
                                group_.value("revision").toInteger());
}

void BuildGroupsWidget::calculate() {
  if (group_.isEmpty() || planning_) {
    return;
  }
  planning_ = true;
  rebuild();
  controller_->planBuildGroup(selectedId_,
                              group_.value("revision").toInteger());
}
