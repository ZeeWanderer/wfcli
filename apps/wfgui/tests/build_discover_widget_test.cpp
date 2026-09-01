#include <QJsonArray>
#include <QLabel>
#include <QListView>
#include <QLocalServer>
#include <QScopeGuard>
#include <QScrollArea>
#include <QTemporaryDir>
#include <QtTest>

#include "app_controller.h"
#include "build_discover_widget.h"
#include "daemon_client.h"

class BuildDiscoverWidgetTest final : public QObject {
  Q_OBJECT

private slots:
  void rendersBuildCardsAndNotesInOneScrollArea();
};

void BuildDiscoverWidgetTest::rendersBuildCardsAndNotesInOneScrollArea() {
  QTemporaryDir directory;
  QVERIFY(directory.isValid());
  QLocalServer server;
  QVERIFY(server.listen(directory.filePath("wfdaemon.sock")));
  const QByteArray oldSocket = qgetenv("WFCLI_DAEMON_SOCKET");
  qputenv("WFCLI_DAEMON_SOCKET", server.fullServerName().toUtf8());
  const auto restoreSocket = qScopeGuard([oldSocket] {
    if (oldSocket.isNull()) {
      qunsetenv("WFCLI_DAEMON_SOCKET");
    } else {
      qputenv("WFCLI_DAEMON_SOCKET", oldSocket);
    }
  });

  AppController controller;
  QTRY_VERIFY(server.hasPendingConnections());
  QVERIFY(server.nextPendingConnection());
  BuildDiscoverWidget widget(&controller);
  widget.resize(1100, 700);
  widget.show();

  auto *client = controller.findChild<DaemonClient *>();
  QVERIFY(client);
  widget.ensureLoaded();
  client->buildSourceReady(
      QJsonObject{{"op", "build_search"},
                  {"query", ""},
                  {"class", "all"},
                  {"limit", 40}},
      QJsonObject{{"items", QJsonArray{QJsonObject{{"canonical_id", "/item"},
                                                   {"external_id", 100},
                                                   {"name", "Test Rifle"},
                                                   {"class", "primary"}}}}});
  QCoreApplication::processEvents();

  client->buildSourceReady(
      QJsonObject{{"op", "build_list"},
                  {"item", "/item"},
                  {"query", ""},
                  {"scope", "public"},
                  {"ordering", "score"},
                  {"limit", 50},
                  {"offset", 0},
                  {"refresh", false}},
      QJsonObject{
          {"builds", QJsonArray{QJsonObject{
                         {"identity", QJsonObject{{"external_id", 300}}},
                         {"title", "Test build"},
                         {"author", QJsonObject{{"username", "Tester"}}},
                         {"score", 10},
                         {"formas", 2}}}}});
  QCoreApplication::processEvents();
  QCOMPARE(controller.sourceBuildsError(), QString());
  QCOMPARE(controller.sourceBuilds()->rowCount(), 1);
  auto *builds = widget.findChild<QListView *>("buildSourceList");
  QVERIFY(builds);
  QCOMPARE(builds->currentIndex().data().toString(), QString("Test build"));

  const QJsonObject topology{
      {"regions", QJsonArray{QJsonObject{
                      {"id", "mods"},
                      {"label", "Mods"},
                      {"columns", 1},
                      {"slots", QJsonArray{QJsonObject{{"id", "mod-1"},
                                                       {"label", "Mod 1"},
                                                       {"role", "mod"},
                                                       {"build_slot", 1}}}}}}}};
  client->buildSourceReady(
      QJsonObject{
          {"op", "build_detail"}, {"build_id", 300}, {"refresh", false}},
      QJsonObject{{"identity", QJsonObject{{"external_id", 300}}},
                  {"fingerprint", "revision-fingerprint"},
                  {"content", QJsonObject{{"slots", QJsonArray{}}}},
                  {"metadata", QJsonObject{{"title", "Test build"},
                                           {"description", "Build **notes**"}}},
                  {"presentation",
                   QJsonObject{{"topology", topology},
                               {"upgrades", QJsonArray{QJsonObject{
                                                {"source_slot", 1},
                                                {"topology_slot", "mod-1"},
                                                {"name", "Serration"}}}}}}});
  QCoreApplication::processEvents();

  QCOMPARE(controller.buildRevision(300)
               .value("metadata")
               .toObject()
               .value("description")
               .toString(),
           QString("Build **notes**"));

  auto *scroll = widget.findChild<QScrollArea *>("buildRevisionScroll");
  auto *topologyWidget = widget.findChild<QWidget *>("buildTopology");
  auto *note = widget.findChild<QLabel *>("buildNote");
  auto *state = widget.findChild<QLabel *>("buildWorkspaceState");
  QVERIFY(scroll);
  QVERIFY(topologyWidget);
  QVERIFY(note);
  QVERIFY(state);
  QCOMPARE(state->text(), QString("Revision revision-fin"));
  QVERIFY(scroll->widget()->isAncestorOf(topologyWidget));
  QVERIFY(scroll->widget()->isAncestorOf(note));
  QTRY_COMPARE(note->text(), QString("Build **notes**"));
  QVERIFY(!note->isHidden());
  QTRY_VERIFY(widget.findChild<QWidget *>("buildModCard") != nullptr);
  const QWidget *mod = widget.findChild<QWidget *>("buildModCard");
  QCOMPARE(mod->property("upgradeName").toString(), QString("Serration"));
}

QTEST_MAIN(BuildDiscoverWidgetTest)

#include "build_discover_widget_test.moc"
