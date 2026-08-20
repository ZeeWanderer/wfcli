#include <QJsonArray>
#include <QLabel>
#include <QPushButton>
#include <QSignalSpy>
#include <QtTest>

#include "app_controller.h"
#include "build_groups_widget.h"
#include "daemon_client.h"

namespace {
template <typename T> T *findByTestId(QWidget &widget, const char *id) {
  for (T *child : widget.findChildren<T *>()) {
    if (child->property("testId").toString() == id) {
      return child;
    }
  }
  return nullptr;
}
} // namespace

class BuildGroupsWidgetTest final : public QObject {
  Q_OBJECT

private slots:
  void showsFocusedEmptyState();
};

void BuildGroupsWidgetTest::showsFocusedEmptyState() {
  AppController controller;
  BuildGroupsWidget widget(&controller);
  widget.resize(1000, 700);
  widget.show();

  auto *client = controller.findChild<DaemonClient *>();
  QVERIFY(client);
  client->buildSourceReady(QJsonObject{{"op", "build_group_list"}},
                           QJsonObject{{"groups", QJsonArray{}}});
  QCoreApplication::processEvents();

  auto *empty = widget.findChild<QWidget *>("buildGroupEmpty");
  auto *editor = widget.findChild<QWidget *>("buildGroupEditor");
  auto *title = findByTestId<QLabel>(widget, "buildGroupEmptyTitle");
  auto *equipment =
      findByTestId<QPushButton>(widget, "buildGroupEmptyEquipment");
  auto *discover =
      findByTestId<QPushButton>(widget, "buildGroupEmptyDiscover");
  QVERIFY(empty);
  QVERIFY(editor);
  QVERIFY(title);
  QVERIFY(equipment);
  QVERIFY(discover);
  QVERIFY(empty->isVisible());
  QVERIFY(!editor->isVisible());
  QCOMPARE(title->text(), QString("No build groups"));

  QSignalSpy equipmentSpy(&widget, &BuildGroupsWidget::equipmentRequested);
  QSignalSpy discoverSpy(&widget, &BuildGroupsWidget::discoverRequested);
  QTest::mouseClick(equipment, Qt::LeftButton);
  QTest::mouseClick(discover, Qt::LeftButton);
  QCOMPARE(equipmentSpy.count(), 1);
  QCOMPARE(discoverSpy.count(), 1);
  QCOMPARE(equipmentSpy.takeFirst().at(0).toString(), QString());
  QCOMPARE(discoverSpy.takeFirst().at(0).toString(), QString());
}

QTEST_MAIN(BuildGroupsWidgetTest)

#include "build_groups_widget_test.moc"
