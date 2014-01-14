// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark_widgets.menu_button;

import 'package:polymer/polymer.dart';
import 'dart:html';
import '../common/widget.dart';
import '../spark_menu/spark_menu.dart';

// Ported from Polymer Javascript to Dart code.

@CustomTag("spark-menu-button")
class SparkMenuButton extends Widget {
  @published String src = "";
  @published dynamic selected;
  @published String valueattr = "";
  @published bool opened = false;
  @published bool responsive = false;
  @published String valign = "center";
  @published String selectedClass = "";

  SparkMenuButton.created(): super.created() {
    _captureHandler = captureHandler;
    document.addEventListener('mousedown', _captureHandler, true);
  }

  EventListener _captureHandler;

  //* Toggle the opened state of the dropdown.
  void toggle() {
    SparkMenu menu = $['overlayMenu'];
    menu.clearSelection();
    opened = !opened;
  }

  // TODO(sorvell): This approach will not work with modal. For this we need a
  // scrim.
  void captureHandler(MouseEvent e) {
    // TODO(terry): Hack to work around lightdom or event.path not yet working.
    var element = ($['button']);
    if (element != null && !pointInWidget(element, e.client)) {
      // TODO(terry): How to cancel the event e.cancelable = true;
      e.stopImmediatePropagation();
      e.preventDefault();

      opened = false;
    }
  }
  //* Returns the selected item.
  String get selection {
    var menu = $['overlayMenu'];
    assert(menu != null);
    return menu.selection;
  }
}
