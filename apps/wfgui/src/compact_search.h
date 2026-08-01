#pragma once

#include <QString>
#include <QWidget>

class QLineEdit;

class CompactSearch final : public QWidget {
public:
  explicit CompactSearch(const QString &placeholder, QWidget *parent = nullptr);

  QLineEdit *editor() const;

private:
  void expand();
  void collapse();

  QLineEdit *editor_;
};
