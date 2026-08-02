#pragma once

#include <QString>
#include <QWidget>

class QLineEdit;
class QVariantAnimation;

class CompactSearch final : public QWidget {
public:
  explicit CompactSearch(const QString &placeholder, QWidget *parent = nullptr);

  QLineEdit *editor() const;
  void setText(const QString &text);

private:
  void expand();
  void collapse();
  void animateTo(int width);

  QLineEdit *editor_;
  QVariantAnimation *animation_;
  bool expanded_ = false;
};
