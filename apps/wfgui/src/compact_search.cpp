#include "compact_search.h"

#include <QHBoxLayout>
#include <QIcon>
#include <QLineEdit>
#include <QToolButton>

CompactSearch::CompactSearch(const QString &placeholder, QWidget *parent)
    : QWidget(parent), editor_(new QLineEdit) {
  setObjectName("expandingSearch");
  setFixedWidth(40);
  auto *layout = new QHBoxLayout(this);
  layout->setContentsMargins(0, 0, 0, 0);
  layout->setSpacing(2);
  auto *button = new QToolButton;
  button->setObjectName("compactTool");
  button->setIcon(QIcon(":/resources/ui/search.png"));
  button->setIconSize({17, 17});
  button->setToolTip(placeholder);
  layout->addWidget(button);
  editor_->setObjectName("inlineSearch");
  editor_->setPlaceholderText(placeholder);
  editor_->setClearButtonEnabled(true);
  editor_->setFrame(false);
  editor_->setFixedWidth(125);
  editor_->hide();
  layout->addWidget(editor_);
  connect(button, &QToolButton::clicked, this, [this] {
    if (editor_->isVisible() && editor_->text().isEmpty()) {
      collapse();
    } else {
      expand();
    }
  });
  connect(editor_, &QLineEdit::editingFinished, this, [this] {
    if (editor_->text().isEmpty()) {
      collapse();
    }
  });
}

QLineEdit *CompactSearch::editor() const { return editor_; }

void CompactSearch::expand() {
  editor_->show();
  setFixedWidth(174);
  editor_->setFocus(Qt::MouseFocusReason);
}

void CompactSearch::collapse() {
  editor_->hide();
  setFixedWidth(40);
}
