#pragma once

#include <QJsonObject>
#include <QWidget>

class AppController;
class BuildTopologyWidget;
class QCheckBox;
class QLabel;
class QLineEdit;
class QListView;
class QListWidget;
class QModelIndex;
class QPushButton;
class QStackedWidget;

class BuildGroupsWidget final : public QWidget {
  Q_OBJECT

public:
  explicit BuildGroupsWidget(AppController *controller,
                             QWidget *parent = nullptr);
  void selectGroup(const QString &id);

signals:
  void equipmentRequested(const QString &definitionId,
                          const QString &instanceId);
  void discoverRequested(const QString &definitionId);

private:
  void restoreSelection();
  void selectGroupIndex(const QModelIndex &index);
  void rebuild();
  void selectMember(int row);
  void save();
  void removeMember();
  void deleteGroup();
  void calculate();

  AppController *controller_;
  QStackedWidget *pages_;
  QWidget *editor_;
  QWidget *emptyPage_;
  QListView *groups_;
  QLabel *emptyTitle_;
  QLabel *emptyDescription_;
  QPushButton *emptyEquipment_;
  QPushButton *emptyDiscover_;
  QLineEdit *name_;
  QLabel *meta_;
  QCheckBox *preserveSlots_;
  QCheckBox *allowOmni_;
  QCheckBox *allowUmbral_;
  QListWidget *members_;
  BuildTopologyWidget *topology_;
  QLabel *state_;
  QPushButton *save_;
  QPushButton *remove_;
  QPushButton *delete_;
  QPushButton *calculate_;
  QPushButton *equipment_;
  QPushButton *discover_;
  QString selectedId_;
  QJsonObject group_;
  bool planning_ = false;
};
