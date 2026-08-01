#pragma once

#include <QJsonObject>
#include <QWidget>

class AppController;
class QLabel;
class QGridLayout;
class QPropertyAnimation;
class QVBoxLayout;

class ActivityRailWidget final : public QWidget {
  Q_OBJECT

public:
  explicit ActivityRailWidget(AppController *controller,
                              QWidget *parent = nullptr);

private:
  void rebuild();
  void rebuildCycles(const QJsonObject &data);
  void rebuildFissures(const QJsonObject &data);
  void setStatus(const QString &error);
  void updateCountdowns();

  AppController *controller_;
  QGridLayout *cycles_;
  QVBoxLayout *fissures_;
  QLabel *resurgence_;
  QLabel *baro_;
  QLabel *status_;
  QPropertyAnimation *statusAnimation_;
  QString mode_ = "all";
};
