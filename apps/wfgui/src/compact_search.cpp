#include "compact_search.h"

#include <QHBoxLayout>
#include <QIcon>
#include <QLineEdit>
#include <QToolButton>
#include <QVariantAnimation>

CompactSearch::CompactSearch(const QString &placeholder, QWidget *parent)
    : QWidget(parent), editor_(new QLineEdit),
      animation_(new QVariantAnimation(this)) {
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
  animation_->setDuration(250);
  animation_->setEasingCurve(QEasingCurve::InOutCubic);
  connect(animation_, &QVariantAnimation::valueChanged, this,
          [this](const QVariant &value) { setFixedWidth(value.toInt()); });
  connect(animation_, &QVariantAnimation::finished, this, [this] {
    if (!expanded_) {
      editor_->hide();
    }
  });
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
  expanded_ = true;
  editor_->show();
  animateTo(174);
  editor_->setFocus(Qt::MouseFocusReason);
}

void CompactSearch::collapse() {
  expanded_ = false;
  animateTo(40);
}

void CompactSearch::animateTo(int width) {
  animation_->stop();
  animation_->setStartValue(this->width());
  animation_->setEndValue(width);
  animation_->start();
}
