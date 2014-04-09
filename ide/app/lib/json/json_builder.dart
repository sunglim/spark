// Copyright (c) 2014, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark.json_builder;

import 'dart:async';
import 'dart:convert' as convert;

import '../builder.dart';
import '../jobs.dart';
import '../workspace.dart';

/**
 * A [Builder] implementation to add validation warnings to JSON files.
 */
class JsonBuilder extends Builder {

  @override
  Future build(ResourceChangeEvent event, ProgressMonitor monitor) {
    Iterable<ChangeDelta> changes = event.changes.where(
        (c) => c.resource is File && _shouldProcessFile(c.resource));

    return Future.wait(changes.map((c) => _handleFileChange(c.resource)));
  }

  bool _shouldProcessFile(File file) {
    return file.name.endsWith('.json') && !file.isDerived();
  }

  Future _handleFileChange(File file) {
    return file.getContents().then((String str) {
      file.clearMarkers('json');

      try {
        new convert.JsonDecoder().convert(str);
      } catch (e) {
        _ErrorMessageParser parser = new _ErrorMessageParser(str, e.message);
        //file.createMarker('json', Marker.SEVERITY_ERROR, parser.message, parser.lineNumber, parser.position);
        file.createMarker('json', Marker.SEVERITY_ERROR, parser.message, 1);
      }
    });
  }
}

/*
 *  Parse the exception message.
 */
class _ErrorMessageParser {
  final String _errorMessage;
  final String _source;
  var message;
  var position;
  var lineNumber;
  static final _pattern = new RegExp(' \\d+:');
  //static final _pattern = new RegExp('at [1-9]');

  _ErrorMessageParser(this._source, this._errorMessage) {
     // The error message format would be
     // "Unexpected character at 877: 'aa: [\n    "http://*/...'"
    int nike = _errorMessage.indexOf(_pattern);
     message = _errorMessage.substring(0, _errorMessage.indexOf(_pattern));

     _process();
  }

  /**
   * Count the newlines between 0 and position.
   */
  void _process() {
    int start = _errorMessage.indexOf(_pattern);
    int end = _errorMessage.indexOf(new RegExp(': '));
    var substring =_errorMessage.substring(start,end);
    int positionFromSource = int.parse(substring);
    int newLineIndex = 0;
    lineNumber = 0;
    for (int index = 0; index < positionFromSource; index++) {
      if (_source[index] == '\n') {
        lineNumber++;
        newLineIndex = index;
      }
    }

    position = positionFromSource - newLineIndex;
  }
}