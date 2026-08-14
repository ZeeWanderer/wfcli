#include <QJsonArray>
#include <QJsonObject>
#include <QtTest>

#include "build_group_model.h"

class BuildGroupModelTest final : public QObject {
  Q_OBJECT

private slots:
  void ordersAndUpdatesGroups();
  void preservesDetailedGroupOnSummaryUpdate();
  void rejectsMalformedGroups();
};

void BuildGroupModelTest::ordersAndUpdatesGroups() {
  BuildGroupModel model;
  const QJsonObject first{{"id", "a"},
                          {"name", "Alpha"},
                          {"definition_id", "/item"},
                          {"revision", 1},
                          {"updated_at", 10},
                          {"member_count", 0}};
  const QJsonObject second{{"id", "b"},
                           {"name", "Beta"},
                           {"definition_id", "/item"},
                           {"revision", 1},
                           {"updated_at", 20},
                           {"member_count", 1}};
  QVERIFY(model.replace({{"groups", QJsonArray{first, second}}}));
  QCOMPARE(model.rowCount(), 2);
  QCOMPARE(model.index(0).data(BuildGroupModel::IdRole).toString(),
           QString("b"));

  QJsonObject updated = first;
  updated.insert("revision", 2);
  updated.insert("updated_at", 30);
  updated.insert("member_count", 2);
  QVERIFY(model.upsert(updated));
  QCOMPARE(model.index(0).data(BuildGroupModel::IdRole).toString(),
           QString("a"));
  QCOMPARE(model.group("a").value("member_count").toInt(), 2);

  model.remove("b");
  QCOMPARE(model.rowCount(), 1);
  QVERIFY(model.group("b").isEmpty());
}

void BuildGroupModelTest::rejectsMalformedGroups() {
  BuildGroupModel model;
  QString error;
  QVERIFY(!model.replace({{"groups", QJsonArray{QJsonObject{{"id", "a"}}}}},
                         &error));
  QVERIFY(!error.isEmpty());
}

void BuildGroupModelTest::preservesDetailedGroupOnSummaryUpdate() {
  BuildGroupModel model;
  const QJsonObject member{{"id", "member"},
                           {"snapshot", QJsonObject{{"config", QJsonObject{}}}}};
  const QJsonObject detailed{{"id", "group"},
                             {"name", "Detailed"},
                             {"definition_id", "/item"},
                             {"revision", 2},
                             {"updated_at", 10},
                             {"members", QJsonArray{member}}};
  QVERIFY(model.upsert(detailed));

  const QJsonObject summary{{"id", "group"},
                            {"name", "Detailed"},
                            {"definition_id", "/item"},
                            {"revision", 2},
                            {"updated_at", 20},
                            {"member_count", 1},
                            {"plan_result",
                             QJsonObject{{"status", "ready"},
                                         {"forma_cost", 2}}}};
  QVERIFY(model.upsert(summary));
  const QJsonObject merged = model.group("group");
  QCOMPARE(merged.value("members").toArray().size(), 1);
  QCOMPARE(merged.value("updated_at").toInteger(), 20);
  QCOMPARE(merged.value("plan_result").toObject().value("forma_cost").toInt(),
           2);
}

QTEST_MAIN(BuildGroupModelTest)

#include "build_group_model_test.moc"
