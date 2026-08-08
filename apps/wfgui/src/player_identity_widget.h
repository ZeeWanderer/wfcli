#pragma once

#include <QString>
#include <QWidget>

class AppController;
class QLabel;
class QResizeEvent;

class PlayerIdentityWidget final : public QWidget {
public:
  explicit PlayerIdentityWidget(AppController *controller,
                                QWidget *parent = nullptr);

protected:
  void resizeEvent(QResizeEvent *event) override;

private:
  void updateProfile();
  void updateName();

  AppController *controller_;
  QLabel *icon_;
  QLabel *rank_;
  QLabel *name_;
  QString rankIconPath_;
  QString playerName_;
};
