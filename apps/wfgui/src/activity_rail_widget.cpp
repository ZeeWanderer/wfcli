#include "activity_rail_widget.h"

#include <QButtonGroup>
#include <QDateTime>
#include <QFrame>
#include <QGridLayout>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QLabel>
#include <QMap>
#include <QPushButton>
#include <QScrollArea>
#include <QTimer>
#include <QVBoxLayout>

#include <algorithm>

#include "app_controller.h"

namespace {
void clearLayout(QLayout *layout) {
  while (QLayoutItem *item = layout->takeAt(0)) {
    delete item->widget();
    delete item;
  }
}

qint64 isoTime(const QString &value) {
  const QDateTime time = QDateTime::fromString(value, Qt::ISODate);
  return time.isValid() ? time.toMSecsSinceEpoch() : 0;
}

QString remaining(qint64 expiresAt) {
  qint64 seconds = std::max<qint64>(
      0, (expiresAt - QDateTime::currentMSecsSinceEpoch()) / 1000);
  const qint64 days = seconds / 86400;
  seconds %= 86400;
  const qint64 hours = seconds / 3600;
  seconds %= 3600;
  const qint64 minutes = seconds / 60;
  seconds %= 60;
  if (days > 0) {
    return QString("%1d %2h").arg(days).arg(hours);
  }
  if (hours > 0) {
    return QString("%1h %2m").arg(hours).arg(minutes);
  }
  return QString("%1m %2s").arg(minutes).arg(seconds);
}

QWidget *cycleCard(const QJsonObject &cycle) {
  auto *card = new QWidget;
  card->setObjectName("cycleCard");
  auto *layout = new QVBoxLayout(card);
  layout->setContentsMargins(8, 6, 8, 6);
  layout->setSpacing(1);
  auto *title = new QLabel(cycle.value("name").toString().toUpper());
  title->setObjectName("cycleName");
  auto *state = new QLabel(cycle.value("state").toString().toUpper());
  state->setObjectName("cycleState");
  auto *countdown = new QLabel;
  countdown->setObjectName("countdown");
  countdown->setProperty("expiresAt", cycle.value("expires_at").toInteger());
  layout->addWidget(title);
  auto *line = new QHBoxLayout;
  line->addWidget(state);
  line->addStretch();
  line->addWidget(countdown);
  layout->addLayout(line);
  return card;
}

void setEvent(QLabel *label, const QString &title, const QString &detail,
              const QJsonObject &event) {
  label->setProperty("eventTitle", title);
  label->setProperty("eventDetail", detail);
  label->setProperty("startsAt", isoTime(event.value("activation").toString()));
  label->setProperty("expiresAt", isoTime(event.value("expiry").toString()));
  label->setProperty("available", !event.isEmpty());
}

void updateEvent(QLabel *label) {
  const QString title = label->property("eventTitle").toString();
  if (!label->property("available").toBool()) {
    label->setText(title + "\nSchedule unavailable");
    return;
  }
  const QString detail = label->property("eventDetail").toString();
  const qint64 startsAt = label->property("startsAt").toLongLong();
  const qint64 expiresAt = label->property("expiresAt").toLongLong();
  const qint64 now = QDateTime::currentMSecsSinceEpoch();
  QString timing;
  if (startsAt > now) {
    timing = "In " + remaining(startsAt);
  } else if (expiresAt > now) {
    timing = remaining(expiresAt) + " left";
  }
  label->setText(title + (detail.isEmpty() ? QString() : "\n" + detail) +
                 (timing.isEmpty() ? QString() : "\n" + timing));
}
} // namespace

ActivityRailWidget::ActivityRailWidget(AppController *controller,
                                       QWidget *parent)
    : QWidget(parent), controller_(controller), cycles_(new QGridLayout),
      fissures_(new QVBoxLayout), resurgence_(new QLabel), baro_(new QLabel),
      status_(new QLabel) {
  setObjectName("activityRail");
  setFixedWidth(400);

  auto *layout = new QVBoxLayout(this);
  layout->setContentsMargins(8, 8, 8, 0);
  layout->setSpacing(8);
  auto *title = new QLabel("Timers & Events");
  title->setObjectName("railTitle");
  layout->addWidget(title);

  cycles_->setContentsMargins(0, 0, 0, 0);
  cycles_->setHorizontalSpacing(6);
  cycles_->setVerticalSpacing(6);
  layout->addLayout(cycles_);

  auto *events = new QHBoxLayout;
  events->setContentsMargins(0, 0, 0, 0);
  events->setSpacing(6);
  resurgence_->setObjectName("resurgenceStatus");
  resurgence_->setWordWrap(true);
  events->addWidget(resurgence_, 1);
  baro_->setObjectName("baroStatus");
  baro_->setWordWrap(true);
  events->addWidget(baro_, 1);
  layout->addLayout(events);

  auto *fissureHeader = new QHBoxLayout;
  auto *fissureTitle = new QLabel("Void fissures");
  fissureTitle->setObjectName("sectionTitle");
  fissureHeader->addWidget(fissureTitle);
  fissureHeader->addStretch();
  auto *modes = new QButtonGroup(this);
  modes->setExclusive(true);
  const QList<QPair<QString, QString>> filters = {
      {"All", "all"}, {"Normal", "normal"}, {"Steel", "steel"}};
  int id = 0;
  for (const auto &[label, value] : filters) {
    auto *button = new QPushButton(label);
    button->setObjectName("railFilter");
    button->setCheckable(true);
    button->setChecked(id == 0);
    button->setProperty("mode", value);
    modes->addButton(button, id++);
    fissureHeader->addWidget(button);
  }
  layout->addLayout(fissureHeader);

  auto *listHost = new QWidget;
  listHost->setObjectName("fissureList");
  fissures_->setContentsMargins(0, 0, 0, 0);
  fissures_->setSpacing(4);
  listHost->setLayout(fissures_);
  auto *scroll = new QScrollArea;
  scroll->setObjectName("activityScroll");
  scroll->setWidgetResizable(true);
  scroll->setFrameShape(QFrame::NoFrame);
  scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
  scroll->setWidget(listHost);
  layout->addWidget(scroll, 1);

  status_->setObjectName("secondaryText");
  layout->addWidget(status_);

  connect(modes, &QButtonGroup::idClicked, this, [this, modes](int buttonId) {
    mode_ = modes->button(buttonId)->property("mode").toString();
    rebuildFissures(controller_->activity());
    updateCountdowns();
  });
  connect(controller_, &AppController::activityStateChanged, this,
          &ActivityRailWidget::rebuild);
  auto *timer = new QTimer(this);
  timer->setInterval(1000);
  connect(timer, &QTimer::timeout, this, &ActivityRailWidget::updateCountdowns);
  timer->start();
  rebuild();
}

void ActivityRailWidget::rebuild() {
  const QJsonObject data = controller_->activity();
  rebuildCycles(data);
  rebuildFissures(data);
  const QJsonObject baro = data.value("baro").toObject();
  setEvent(baro_, "Baro Ki'Teer", baro.value("node").toString(), baro);
  const QJsonObject resurgence = data.value("resurgence").toObject();
  setEvent(resurgence_, "Prime Resurgence",
           resurgence.value("featured").toString(), resurgence);
  const QString error = data.value("error").toString();
  status_->setText(error.isEmpty() ? QString() : error);
  updateCountdowns();
}

void ActivityRailWidget::rebuildCycles(const QJsonObject &data) {
  clearLayout(cycles_);
  const QJsonArray values = data.value("cycles").toArray();
  for (int index = 0; index < values.size(); ++index) {
    cycles_->addWidget(cycleCard(values.at(index).toObject()), index / 2,
                       index % 2);
  }
}

void ActivityRailWidget::rebuildFissures(const QJsonObject &data) {
  clearLayout(fissures_);
  QMap<QString, QJsonArray> groups;
  for (const QJsonValue &value : data.value("fissures").toArray()) {
    const QJsonObject fissure = value.toObject();
    const bool hard = fissure.value("hard").toBool();
    if ((mode_ == "normal" && hard) || (mode_ == "steel" && !hard)) {
      continue;
    }
    groups[fissure.value("tier").toString()].append(fissure);
  }
  const QStringList order = {"Lith", "Meso", "Neo", "Axi", "Requiem", "Omnia"};
  QStringList tiers = order;
  for (auto group = groups.cbegin(); group != groups.cend(); ++group) {
    if (!tiers.contains(group.key())) {
      tiers.append(group.key());
    }
  }
  for (const QString &tier : tiers) {
    const QJsonArray rows = groups.value(tier);
    if (rows.isEmpty()) {
      continue;
    }
    auto *heading = new QLabel(tier);
    heading->setObjectName("fissureTier");
    fissures_->addWidget(heading);
    for (const QJsonValue &value : rows) {
      const QJsonObject fissure = value.toObject();
      auto *row = new QWidget;
      row->setObjectName("fissureRow");
      auto *rowLayout = new QVBoxLayout(row);
      rowLayout->setContentsMargins(8, 6, 8, 6);
      rowLayout->setSpacing(1);
      auto *top = new QHBoxLayout;
      auto *mission = new QLabel(fissure.value("mission").toString());
      mission->setObjectName("fissureMission");
      auto *countdown = new QLabel;
      countdown->setObjectName("countdown");
      countdown->setProperty("expiresAt",
                             isoTime(fissure.value("expiry").toString()));
      top->addWidget(mission);
      top->addStretch();
      top->addWidget(countdown);
      rowLayout->addLayout(top);
      auto *node = new QLabel(fissure.value("node").toString() +
                              (fissure.value("hard").toBool() ? "  ·  Steel Path" : ""));
      node->setObjectName("secondaryText");
      node->setWordWrap(true);
      rowLayout->addWidget(node);
      fissures_->addWidget(row);
    }
  }
  fissures_->addStretch();
}

void ActivityRailWidget::updateCountdowns() {
  for (QLabel *label : findChildren<QLabel *>("countdown")) {
    const qint64 expiresAt = label->property("expiresAt").toLongLong();
    label->setText(expiresAt > 0 ? remaining(expiresAt) : "--");
  }
  updateEvent(resurgence_);
  updateEvent(baro_);
}
