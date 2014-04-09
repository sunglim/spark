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
        file.createMarker('json', Marker.SEVERITY_ERROR, parser.Message, parser.Line, parser.Position);
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
  var Message;
  var Position;
  var Line;
  static final _pattern = new RegExp('[1-9]+:');

  _ErrorMessageParser(this._source, this._errorMessage) {
     // The error message format should be
     // "Unexpected character at 877: 'aa: [\n    "http://*/...'"
     Message = _errorMessage.substring(0, _errorMessage.indexOf(_pattern));
     Position = int.parse(
         _errorMessage.substring(_errorMessage.indexOf(_pattern),
                                 _errorMessage.indexOf(new RegExp(': '))));
     Line = _calcLineNumber();
  }

  /**
   * Count the newlines between 0 and position.
   */
  int _calcLineNumber() {
      int lineCount = 0;

      for (int index = 0; index < _source.length; index++) {
        if (_source[index] == '\n') lineCount++;
        if (index == Position) return lineCount + 1;
      }

      return lineCount;
    }
}