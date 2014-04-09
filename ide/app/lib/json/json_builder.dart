// Copyright (c) 2014, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark.json_builder;

import 'dart:async';
import 'dart:convert' as convert;

import 'package:json/json.dart' as json;

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
  
  String _beautifyException(FormatException e) {
    final String exceptionMessage = e.message;
    Pattern pattern = new RegExp('[1-9]+:');
    final message = exceptionMessage.substring(0, exceptionMessage.indexOf(pattern));
    final position = exceptionMessage.substring(exceptionMessage.indexOf(pattern), exceptionMessage.indexOf(new RegExp(': ')));
    var nike = message;
    return message;
    //"Unexpected character at 877: 'aa: [\n    "http://*/...'"
  }
}

class _ErrorMessageParser {
  final String _errorMessage;
  final String _source;
  var Message;
  var Position;
  var Line;
  static Pattern _pattern = new RegExp('[1-9]+:'); 
  _ErrorMessageParser(this._source, this._errorMessage) {
     Message = _errorMessage.substring(0, _errorMessage.indexOf(_pattern));
     Position = int.parse(_errorMessage.substring(_errorMessage.indexOf(_pattern),
                                       _errorMessage.indexOf(new RegExp(': '))));
     Line = _calcLineNumber();
  }
  
  int _calcLineNumber() {
      int lineCount = 0;

      for (int index = 0; index < _source.length; index++) {
        if (_source[index] == '\n') lineCount++;
        if (index == Position) return lineCount + 1;
      }

      return lineCount;
    }
}

class _JsonParserListener extends json.JsonListener {
  final File file;

  _JsonParserListener(this.file);

  void fail(String source, int position, String message) {
    int lineNum = _calcLineNumber(source, position);
    file.createMarker('json', Marker.SEVERITY_ERROR, message, lineNum, position);
  }

  /**
   * Count the newlines between 0 and position.
   */
  int _calcLineNumber(String source, int position) {
    int lineCount = 0;

    for (int index = 0; index < source.length; index++) {
      if (source[index] == '\n') lineCount++;
      if (index == position) return lineCount + 1;
    }

    return lineCount;
  }
}
