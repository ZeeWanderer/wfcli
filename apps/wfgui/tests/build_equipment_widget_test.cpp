#include <QImage>
#include <QSplitter>
#include <QToolButton>
#include <QVariantAnimation>
#include <QtTest>

#include "app_controller.h"
#include "build_equipment_widget.h"

class BuildEquipmentWidgetTest final : public QObject {
  Q_OBJECT

private slots:
  void animatesEquipmentRailWithVisibleGlyph();
};

void BuildEquipmentWidgetTest::animatesEquipmentRailWithVisibleGlyph() {
  AppController controller;
  BuildEquipmentWidget widget(&controller);
  widget.resize(1000, 700);
  widget.show();
  QTest::qWait(10);

  auto *splitter = widget.findChild<QSplitter *>("buildEquipmentSplit");
  auto *toggle = widget.findChild<QToolButton *>("compactTool");
  auto *animation = widget.findChild<QVariantAnimation *>("buildRailAnimation");
  QVERIFY(splitter);
  QVERIFY(toggle);
  QVERIFY(animation);
  QCOMPARE(animation->duration(), 160);
  QVERIFY(splitter->widget(0)->isVisible());
  QVERIFY(splitter->sizes().at(0) >= 220);

  const QImage icon = toggle->icon().pixmap(16, 16).toImage();
  bool hasLightPixel = false;
  for (int y = 0; y < icon.height() && !hasLightPixel; ++y) {
    for (int x = 0; x < icon.width(); ++x) {
      const QColor pixel = icon.pixelColor(x, y);
      if (pixel.alpha() > 0 && pixel.lightness() > 150) {
        hasLightPixel = true;
        break;
      }
    }
  }
  QVERIFY(hasLightPixel);

  QTest::mouseClick(toggle, Qt::LeftButton);
  QTRY_VERIFY_WITH_TIMEOUT(!splitter->widget(0)->isVisible(), 400);
  QCOMPARE(splitter->sizes().at(0), 0);

  QTest::mouseClick(toggle, Qt::LeftButton);
  QTRY_VERIFY_WITH_TIMEOUT(splitter->widget(0)->isVisible(), 400);
  QTRY_VERIFY_WITH_TIMEOUT(splitter->sizes().at(0) >= 220, 400);
}

QTEST_MAIN(BuildEquipmentWidgetTest)

#include "build_equipment_widget_test.moc"
