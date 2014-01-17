// Copyright (c) 2013, Google Inc. Please see the AUTHORS file for details.
// All rights reserved. Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

library spark;

import 'dart:async';
import 'dart:convert' show JSON;
import 'dart:html';

import 'package:bootjack/bootjack.dart' as bootjack;
import 'package:chrome/chrome_app.dart' as chrome;
import 'package:dquery/dquery.dart';
import 'package:logging/logging.dart';

import 'lib/ace.dart';
import 'lib/actions.dart';
import 'lib/analytics.dart' as analytics;
import 'lib/app.dart';
import 'lib/builder.dart';
import 'lib/dart/dart_builder.dart';
import 'lib/editors.dart';
import 'lib/editor_area.dart';
import 'lib/event_bus.dart';
import 'lib/git/commands/branch.dart';
import 'lib/git/commands/checkout.dart';
import 'lib/git/commands/clone.dart';
import 'lib/git/commands/commit.dart';
import 'lib/git/objectstore.dart';
import 'lib/git/options.dart';
import 'lib/jobs.dart';
import 'lib/launch.dart';
import 'lib/preferences.dart' as preferences;
import 'lib/scm.dart' as scm;
import 'lib/tests.dart';
import 'lib/ui/files_controller.dart';
import 'lib/ui/files_controller_delegate.dart';
import 'lib/ui/widgets/splitview.dart';
import 'lib/utils.dart';
import 'lib/workspace.dart' as ws;
import 'test/all.dart' as all_tests;

import 'spark_model.dart';

analytics.Tracker _analyticsTracker = new analytics.NullTracker();

void main() {
  isTestMode().then((testMode) {
    createSparkZone().runGuarded(() {
      Spark spark = new Spark(testMode);
      spark.start();
    });
  });
}

/**
 * Returns true if app.json contains a test-mode entry set to true. If app.json
 * does not exit, it returns true.
 */
Future<bool> isTestMode() {
  String url = chrome.runtime.getURL('app.json');
  return HttpRequest.getString(url).then((String contents) {
    bool result = true;
    try {
      Map info = JSON.decode(contents);
      result = info['test-mode'];
    } catch (exception, stackTrace) {
      // If JSON is invalid, assume test mode.
      result = true;
    }
    return result;
  }).catchError((e) {
    return true;
  });
}

/**
 * Create a [Zone] that logs uncaught exceptions.
 */
Zone createSparkZone() {
  var errorHandler = (self, parent, zone, error, stackTrace) {
    _handleUncaughtException(error, stackTrace);
  };
  var specification = new ZoneSpecification(handleUncaughtError: errorHandler);
  return Zone.current.fork(specification: specification);
}

class Spark extends SparkModel implements FilesControllerDelegate {
  /// The Google Analytics app ID for Spark.
  static final _ANALYTICS_ID = 'UA-45578231-1';

  final bool developerMode;

  final JobManager jobManager = new JobManager();

  ActivitySpinner _activitySpinner;

  AceManager _aceManager;
  ThemeManager _aceThemeManager;
  KeyBindingManager _aceKeysManager;
  ws.Workspace _workspace;
  BuilderManager _buildManager;
  EditorManager _editorManager;
  EditorArea _editorArea;
  LaunchManager _launchManager;



  final EventBus eventBus = new EventBus();

  preferences.PreferenceStore _localPrefs;
  preferences.PreferenceStore _syncPrefs;

  ActionManager _actionManager;

  SplitView _splitView;
  FilesController _filesController;
  PlatformInfo _platformInfo;
  TestDriver _testDriver;
  ProjectLocationManager projectLocationManager;

  DirectoryEntry _gitDir;
  ObjectStore _currentGitStore;

  Spark(this.developerMode) {
    document.title = appName;

    _localPrefs = preferences.localStore;
    _syncPrefs = preferences.syncStore;

    initAnalytics();

    addParticipant(new _SparkSetupParticipant(this));

    // TODO: this event is not being fired. A bug with chrome apps / Dartium?
    chrome.app.window.onClosed.listen((_) {
      close();
    });

    initWorkspace();
    initActivitySpinner();

    createEditorComponents();
    initEditorArea();
    initEditorManager();

    initFilesController();

    initLookAndFeel();

    createActions();
    initToolbar();
    buildMenu();

    initSplitView();
    initSaveStatusListener();

    initLaunchManager();


    window.onFocus.listen((Event e) {
      // When the user switch to an other application, he might change the
      // content of the workspace from other applications.
      // For that reason, when the user switch back to Spark, we want to check
      // whether the content of the workspace changed.
      // TODO(devoncarew): This is causing workspace corruption issues. Our
      // refresh method really needs to weave deltas back into the existing
      // workspace model.
      //workspace.refresh();
    });

    addBuilder(new DartBuilder());
  }

  //
  // SparkModel interface:
  //

  AceManager get aceManager => _aceManager;
  ThemeManager get aceThemeManager => _aceThemeManager;
  KeyBindingManager get aceKeysManager => _aceKeysManager;
  ws.Workspace get workspace => _workspace;
  EditorManager get editorManager => _editorManager;
  EditorArea get editorArea => _editorArea;
  LaunchManager get launchManager => _launchManager;

  preferences.PreferenceStore get localPrefs => _localPrefs;
  preferences.PreferenceStore get syncPrefs => _syncPrefs;

  ActionManager get actionManager => _actionManager;

  //
  // - End SparkModel interface.
  //

  String get appName => i18n('app_name');

  String get appVersion => chrome.runtime.getManifest()['version'];

  PlatformInfo get platformInfo => _platformInfo;

  /**
   * Get the currently selected [Resource].
   */
  ws.Resource get currentResource => focusManager.currentResource;

  /**
   * Get the [File] currently being edited.
   */
  ws.File get currentEditedFile => focusManager.currentEditedFile;

  /**
   * Get the currently selected [Project].
   */
  ws.Project get currentProject => focusManager.currentProject;

  // TODO(ussuri): The below two methods are a temporary means to make Spark
  // reusable in SparkPolymer. Once the switch to Polymer is complete, they
  // will go away.

  /**
   * Should extract a UI Element from the underlying DOM. This method
   * is overwritten in SparkPolymer, which encapsulates the UI in a top-level
   * Polymer widget, rather than the top-level document's DOM.
   */
  Element getUIElement(String selectors) =>
      document.querySelector(selectors);

  /**
   * Should extract a dialog Element from the underlying UI's DOM. This is
   * different from [getUIElement] in that it's not currently overridden in
   * SparkPolymer.
   */
  Element getDialogElement(String selectors) =>
      document.querySelector(selectors);

  SparkDialog createDialog(Element dialogElement) =>
      new SparkBootjackDialog(dialogElement);

  //
  // Parts of ctor:
  //

  void initAnalytics() {
    analytics.getService('Spark').then((service) {
      // Init the analytics tracker and send a page view for the main page.
      _analyticsTracker = service.getTracker(_ANALYTICS_ID);
      _analyticsTracker.sendAppView('main');

      // Track logged exceptions.
      Logger.root.onRecord.listen((LogRecord r) {
        if (r.level >= Level.SEVERE && r.loggerName != 'spark.tests') {
          _handleUncaughtException(r.error, r.stackTrace);
        }
      });
    });
  }

  void initWorkspace() {
    _workspace = new ws.Workspace(localPrefs);
  }

  void initLaunchManager() {
    _launchManager = new LaunchManager(_workspace);
  }

  /**
   * Returns the path separator specific to os.
   */
  String getPathSeparator() {
    // TODO(grv) : Add check of os and return accordingly.
    return '/';
  }

  void createEditorComponents() {
    _aceManager = new AceManager(new DivElement());
    _aceThemeManager = new ThemeManager(
        aceManager, syncPrefs, getUIElement('#changeTheme span'));
    _aceKeysManager = new KeyBindingManager(
        aceManager, syncPrefs, getUIElement('#changeKeys span'));
    _editorManager = new EditorManager(
        workspace, aceManager, localPrefs, eventBus);
    _editorArea = new EditorArea(
        getUIElement('#editorArea'),
        getUIElement('#editedFilename'),
        editorManager,
        allowsLabelBar: true);
  }

  void initActivitySpinner() {
    _activitySpinner = new ActivitySpinner(this, '#activitySpinner');
    _activitySpinner.setShowing(false);

    // TODO: This might cause the spinner to "blink" between jobs.
    jobManager.onChange.listen((JobManagerEvent event) {
      _activitySpinner.setShowing(!event.finished);
    });
  }

  void initEditorManager() {
    editorManager.loaded.then((_) {
      List<ws.Resource> files = editorManager.files.toList();
      editorManager.files.forEach((file) {
        editorArea.selectFile(file, forceOpen: true, switchesTab: false);
      });
      localPrefs.getValue('lastFileSelection').then((String filePath) {
        if (editorArea.tabs.isEmpty) return;
        if (filePath == null) {
          editorArea.tabs[0].select();
          return;
        }
        ws.Resource resource = workspace.restoreResource(filePath);
        if (resource == null) {
          editorArea.tabs[0].select();
          return;
        }
        _selectFile(resource);
      });
    });
  }

  void initEditorArea() {
    editorArea.onSelected.listen((EditorTab tab) {
      // We don't change the selection when the file was already selected
      // otherwise, it would break multi-selection (#260).
      if (!_filesController.isFileSelected(tab.file)) {
        _filesController.selectFile(tab.file);
      }
      localPrefs.setValue('lastFileSelection', tab.file.path);
      focusManager.setEditedFile(tab.file);
    });
  }

  void initFilesController() {
    _filesController = new FilesController(
        workspace, this, getUIElement('#fileViewArea'));
    _filesController.onSelectionChange.listen((resource) {
      focusManager.setCurrentResource(resource);
    });
  }

  void initLookAndFeel() {
    // Init the Bootjack library (a wrapper around Bootstrap).
    bootjack.Bootjack.useDefault();
  }

  void initSplitView() {
    _splitView = new SplitView(getUIElement('#splitview'));
    _splitView.onResized.listen((_) {
      aceManager.resize();
      syncPrefs.setValue('splitViewPosition', _splitView.position.toString());
    });
    syncPrefs.getValue('splitViewPosition').then((String position) {
      if (position != null) {
        int value = int.parse(position, onError: (_) => 0);
        if (value != 0) {
          _splitView.position = value;
        }
      }
    });
  }

  void initSaveStatusListener() {
    Element element = getUIElement('#saveStatus');
    Timer timer = new Timer(new Duration(seconds: 0), () => null);

    eventBus.onEvent('fileModified').listen((_) {
      //element.text = 'text modified…';
      element.text = '';
      timer.cancel();
    });

    eventBus.onEvent('filesSaved').listen((_) {
      element.text = 'all changes saved';
      timer.cancel();
      timer = new Timer(new Duration(seconds: 3), () => (element.text = ''));
    });
  }

  void createActions() {
    _actionManager = new ActionManager();

    actionManager.registerAction(new NextMarkerAction(this));
    actionManager.registerAction(new PrevMarkerAction(this));
    actionManager.registerAction(new FileOpenInTabAction(this));
    actionManager.registerAction(new FileNewAsAction(this));
    actionManager.registerAction(new FileOpenAction(this));
    actionManager.registerAction(new FileNewAction(this, getDialogElement('#fileNewDialog')));
    actionManager.registerAction(new FolderNewAction(this, getDialogElement('#folderNewDialog')));
    actionManager.registerAction(new FolderOpenAction(this));
    actionManager.registerAction(new FileSaveAction(this));
    actionManager.registerAction(new FileRenameAction(this, getDialogElement('#renameDialog')));
    actionManager.registerAction(new ApplicationRunAction(this));
    actionManager.registerAction(new GitCloneAction(this, getDialogElement("#gitCloneDialog")));
    actionManager.registerAction(new GitBranchAction(this, getDialogElement("#gitBranchDialog")));
    actionManager.registerAction(new GitCheckoutAction(this, getDialogElement("#gitCheckoutDialog")));
    actionManager.registerAction(new GitCommitAction(this, getDialogElement("#gitCommitDialog")));
    actionManager.registerAction(new RunTestsAction(this));
    actionManager.registerAction(new SettingAction(this, getDialogElement('#settingDialog')));
    actionManager.registerAction(new AboutSparkAction(this, getDialogElement('#aboutDialog')));
    actionManager.registerAction(new ResourceCloseAction(this));
    actionManager.registerAction(new FileDeleteAction(this, getDialogElement('#deleteDialog')));
    actionManager.registerAction(new FileExitAction(this));

    actionManager.registerKeyListener();
  }

  void initToolbar() {

  }

  void buildMenu() {
    UListElement ul = getUIElement('#hotdogMenu ul');

    ul.children.add(createMenuItem(actionManager.getAction('file-open')));
    ul.children.add(createMenuItem(actionManager.getAction('folder-open')));

    ul.children.add(createMenuSeparator());

    // Theme control.
    Element theme = ul.querySelector('#changeTheme');
    ul.children.remove(theme);
    ul.children.add(theme);
    ul.querySelector('#themeLeft').onClick.listen((e) => aceThemeManager.dec(e));
    ul.querySelector('#themeRight').onClick.listen((e) => aceThemeManager.inc(e));

    // Key binding control.
    Element keys = ul.querySelector('#changeKeys');
    ul.children.remove(keys);
    ul.children.add(keys);
    ul.querySelector('#keysLeft').onClick.listen((e) => aceKeysManager.dec(e));
    ul.querySelector('#keysRight').onClick.listen((e) => aceKeysManager.inc(e));

    if (developerMode) {
      ul.children.add(createMenuSeparator());
      ul.children.add(createMenuItem(actionManager.getAction('run-tests')));
      ul.children.add(createMenuItem(actionManager.getAction('git-clone')));
      ul.children.add(createMenuItem(actionManager.getAction('git-commit')));
      ul.children.add(createMenuItem(actionManager.getAction('git-branch')));
      ul.children.add(createMenuItem(actionManager.getAction('git-checkout')));
    }

    ul.children.add(createMenuSeparator());
    ul.children.add(createMenuItem(actionManager.getAction('help-about')));
  }

  //
  // - End parts of ctor.
  //

  void addBuilder(Builder builder) {
    if (_buildManager == null) {
      _buildManager = new BuilderManager(workspace, jobManager);
    }

    _buildManager.builders.add(builder);
  }

  /**
   * Allow for creating a new file using the Save as dialog.
   */
  void newFileAs() {
    chrome.ChooseEntryOptions options = new chrome.ChooseEntryOptions(
        type: chrome.ChooseEntryType.SAVE_FILE);
    chrome.fileSystem.chooseEntry(options).then((chrome.ChooseEntryResult res) {
      chrome.ChromeFileEntry entry = res.entry;

      if (entry != null) {
        workspace.link(entry).then((file) {
          _selectFile(file);
          workspace.save();
        });
      }
    }).catchError((e) => null);
  }

  void openFile() {
    chrome.ChooseEntryOptions options = new chrome.ChooseEntryOptions(
        type: chrome.ChooseEntryType.OPEN_WRITABLE_FILE);
    chrome.fileSystem.chooseEntry(options).then((chrome.ChooseEntryResult res) {
      chrome.ChromeFileEntry entry = res.entry;

      if (entry != null) {
        workspace.link(entry).then((file) {
          _selectFile(file);
          workspace.save();
        });
      }
    }).catchError((e) => null);
  }

  void openFolder() {
    _selectFolder().then((chrome.ChromeFileEntry entry) {
      if (entry != null) {
        workspace.link(entry).then((file) {
          Timer.run(() {
            _filesController.selectFile(file);
            _filesController.setFolderExpanded(file);
          });
          workspace.save();
        });
      }
    });
  }

  void onSplitViewUpdate(int position) { }

  List<ws.Resource> _getSelection() => _filesController.getSelection();

  void _closeOpenEditor(ws.Resource resource) {
    if (resource is ws.File &&  editorManager.isFileOpened(resource)) {
      editorArea.closeFile(resource);
    }
  }

  /**
   * Refreshes the file name on an opened editor tab.
   */
  void _renameOpenEditor(ws.Resource renamedResource) {
    if (renamedResource is ws.File && editorManager.isFileOpened(renamedResource)) {
      editorArea.renameFile(renamedResource);
    }
  }

  void _selectFile(ws.Resource file) {
    editorArea.selectFile(file,
        forceOpen: true, switchesTab: true, forceFocus: true);
  }

  //
  // Implementation of FilesControllerDelegate interface:
  //

  void selectInEditor(ws.File file,
                      {bool forceOpen: false,
                       bool replaceCurrent: true,
                       bool switchesTab: true}) {
    if (forceOpen || editorManager.isFileOpened(file)) {
      editorArea.selectFile(file,
          forceOpen: forceOpen,
          replaceCurrent: replaceCurrent,
          switchesTab: switchesTab);
    }
  }

  Element getContextMenuContainer() => getUIElement('#file-item-context-menu');

  List<ContextAction> getActionsFor(List<ws.Resource> resources) =>
      actionManager.getContextActions(resources);

  //
  // - End implementation of FilesControllerDelegate interface.
  //
}

class PlatformInfo {
  /**
   * The operating system chrome is running on. One of: "mac", "win", "android",
   * "cros", "linux", "openbsd".
   */
  final String os;

  /**
   * The machine's processor architecture. One of: "arm", "x86-32", "x86-64".
   */
  final String arch;

  /**
   * The native client architecture. This may be different from arch on some
   * platforms. One of: "arm", "x86-32", "x86-64".
   */
  final String naclArch;

  PlatformInfo._(this.os, this.arch, this.naclArch);

  String toString() => "${os}, ${arch}, ${naclArch}";

  bool get isCros => os == 'cros';
}

/**
 * Used to manage the default location to create new projects.
 *
 * This class also abstracts a bit other the differences between Chrome OS and
 * Windows/Mac/linux.
 */
class ProjectLocationManager {
  preferences.PreferenceStore _prefs;
  chrome.DirectoryEntry _projectLocation;

  /**
   * Create a ProjectLocationManager asynchronously, restoring the default
   * project location from the given preferences.
   */
  static Future<ProjectLocationManager> restoreManager(preferences.PreferenceStore prefs) {
    return prefs.getValue('projectFolder').then((String folderToken) {
      if (folderToken == null) {
        return new ProjectLocationManager._(prefs, null);
      }

      return chrome.fileSystem.restoreEntry(folderToken).then((chrome.Entry entry) {
        return new ProjectLocationManager._(prefs, entry);
      });
    });
  }

  ProjectLocationManager._(this._prefs, this._projectLocation);

  /**
   * Returns the default location to create new projects in. For Chrome OS, this
   * will be the sync filesystem. This method can return `null` if the user
   * cancels the folder selection dialog.
   */
  Future<chrome.DirectoryEntry> getProjectLocation() {
    if (_projectLocation != null) {
      return new Future.value(_projectLocation);
    }

    // On Chrome OS, use the sync filesystem.
    if (_isCros()) {
      return chrome.syncFileSystem.requestFileSystem().then((fs) {
        return fs.root;
      });
    }

    // Display a dialog asking the user to choose a default project folder.
    // TODO: We need to provide an explaination to the user about what this
    // folder is for.
    return _selectFolder(suggestedName: 'projects').then((entry) {
      if (entry == null) {
        return null;
      }

      _projectLocation = entry;
      _prefs.setValue('projectFolder', chrome.fileSystem.retainEntry(entry));
      return _projectLocation;
    });
  }

  /**
   * This will create a new folder in default project location. It will attempt
   * to use the given [defaultName], but will disambiguate it if necessary. For
   * example, if `defaultName` already exists, the created folder might be named
   * something like `defaultName-1` instead.
   */
  Future<chrome.DirectoryEntry> createNewFolder(String defaultName) {
    return getProjectLocation().then((root) {
      return _create(root, defaultName, 1);
    });
  }

  Future<chrome.DirectoryEntry> _create(
      chrome.DirectoryEntry parent, String baseName, int count) {
    String name = count == 1 ? baseName : '${baseName}-${count}';

    return parent.createDirectory(name, exclusive: true).then((dir) {
      return dir;
    }).catchError((_) {
      if (count > 20) {
        return null;
      } else {
        return _create(parent, baseName, count + 1);
      }
    });
  }
}

class _SparkSetupParticipant extends LifecycleParticipant {
  Spark spark;

  _SparkSetupParticipant(this.spark);

  Future applicationStarting(Application application) {
    // get platform info
    return chrome.runtime.getPlatformInfo().then((Map m) {
      spark._platformInfo = new PlatformInfo._(m['os'], m['arch'], m['nacl_arch']);
      spark.workspace.restore().then((value) {
        if (spark.workspace.getFiles().length == 0) {
          // No files, just focus the editor.
          spark.aceManager.focus();
        }
      });
      spark.workspace.restoreSyncFs();
    }).then((_) {
      return ProjectLocationManager.restoreManager(spark.localPrefs).then((manager) {
        spark.projectLocationManager = manager;
      });
    });
  }

  Future applicationStarted(Application application) {
    if (spark.developerMode) {
      spark._testDriver = new TestDriver(
          all_tests.defineTests, spark.jobManager, connectToTestListener: true);
    }
  }

  Future applicationClosed(Application application) {
    spark.editorManager.persistState();

    spark.localPrefs.flush();
    spark.syncPrefs.flush();
  }
}

/**
 * Allows a user to select a folder on disk. Returns the selected folder
 * entry. Returns `null` in case the user cancels the action.
 */
Future<chrome.ChromeFileEntry> _selectFolder({String suggestedName}) {
  Completer completer = new Completer();
  chrome.ChooseEntryOptions options = new chrome.ChooseEntryOptions(
      type: chrome.ChooseEntryType.OPEN_DIRECTORY);
  if (suggestedName != null) options.suggestedName = suggestedName;
  chrome.fileSystem.chooseEntry(options).then((chrome.ChooseEntryResult res) {
    completer.complete(res.entry);
  }).catchError((e) => null);
  return completer.future;
}

bool _isCros() {
  return (SparkModel.instance as Spark).platformInfo.isCros;
}

// TODO: This should be moved into the ui/ directory.
class ActivitySpinner {
  Element element;

  ActivitySpinner(Spark spark, String elementId) {
    element = spark.getUIElement(elementId);
  }

  void setShowing(bool showing) {
    element.style.opacity = showing ? '1' : '0';
  }
}

/**
 * The abstract parent class of Spark related actions.
 */
abstract class SparkAction extends Action {
  Spark spark;

  SparkAction(this.spark, String id, String name) : super(id, name);

  void invoke([Object context]) {
    // Send an action event with the 'main' event category.
    _analyticsTracker.sendEvent('main', id);

    _invoke(context);
  }

  void _invoke([Object context]);

  /**
   * Returns true if `object` is a list and all items are [Resource].
   */
  bool _isResourceList(Object object) {
    if (object is! List) {
      return false;
    }
    List items = object as List;
    return items.every((r) => r is ws.Resource);
  }

  /**
   * Returns true if `object` is a list with a single item and this item is a
   * [Resource].
   */
  bool _isSingleResource(Object object) {
    if (!_isResourceList(object)) {
      return false;
    }
    List<ws.Resource> resources = object as List<ws.Resource>;
    return resources.length == 1;
  }

  /**
   * Returns true if `object` is a list with a single item and this item is a
   * [Project].
   */
  bool _isProject(object) {
    if (!_isResourceList(object)) {
      return false;
    }
    return object.length == 1 && object.first is ws.Project;
  }

  /**
   * Returns true if `object` is a list with a single item and this item is a
   * [Folder].
   */
  bool _isSingleFolder(Object object) {
    if (!_isSingleResource(object)) {
      return false;
    }
    List<ws.Resource> resources = object as List;
    return (object as List).first is ws.Folder;
  }

  /**
   * Returns true if `object` is a list of top-level [Resource].
   */
  bool _isTopLevel(Object object) {
    if (!_isResourceList(object)) {
      return false;
    }
    List<ws.Resource> resources = object as List;
    return resources.every((ws.Resource r) => r.isTopLevel);
  }

  /**
   * Returns true if `object` is a list of File.
   */
  bool _isFileList(Object object) {
    if (!_isResourceList(object)) {
      return false;
    }
    List<ws.Resource> resources = object as List;
    return resources.every((r) => r is ws.File);
  }
}

abstract class SparkDialog {
  void show();
  void hide();
  Element get element;
}

class SparkBootjackDialog implements SparkDialog {
  bootjack.Modal _dialog;

  SparkBootjackDialog(Element dialogElement) {
    _dialog = bootjack.Modal.wire(dialogElement);

    _dialog.$element.on('shown.bs.modal', (event) {
      final Element dialog = event.target;
      Element elementToFocus = dialog.querySelector('[focused]');

      if (elementToFocus != null) {
        elementToFocus.focus();
      }
    });
  }

  void show() => _dialog.show();

  void hide() => _dialog.hide();

  Element get element => _dialog.element;
}

abstract class SparkActionWithDialog extends SparkAction {
  SparkDialog _dialog;

  SparkActionWithDialog(Spark spark,
                        String id,
                        String name,
                        Element dialogElement)
      : super(spark, id, name) {
    _dialog = spark.createDialog(dialogElement);
    _dialog.element.querySelector("[primary]").onClick.listen((_) => _commit());
  }

  void _commit();

  Element getElement(String selectors) =>
      _dialog.element.querySelector(selectors);

  Element _triggerOnReturn(String selectors) {
    var element = _dialog.element.querySelector(selectors);
    element.onKeyDown.listen((event) {
      if (event.keyCode == KeyCode.ENTER) {
        _commit();
        _dialog.hide();
      }
    });
    return element;
  }

  void _show() => _dialog.show();
}

class FileOpenInTabAction extends SparkAction implements ContextAction {
  FileOpenInTabAction(Spark spark) :
      super(spark, "file-open-in-tab", "Open in New Tab");

  void _invoke([List<ws.File> files]) {
    bool forceOpen = files.length > 1;
    files.forEach((ws.File file) {
      spark.selectInEditor(file, forceOpen: true, replaceCurrent: false);
    });
  }

  String get category => 'tab';

  bool appliesTo(Object object) => _isFileList(object);
}

class FileOpenAction extends SparkAction {
  FileOpenAction(Spark spark) : super(spark, "file-open", "Open File…") {
    defaultBinding("ctrl-o");
  }

  void _invoke([Object context]) => spark.openFile();
}

class FileNewAction extends SparkActionWithDialog implements ContextAction {
   InputElement _nameElement;
   ws.Folder folder;

   FileNewAction(Spark spark, Element dialog)
     : super(spark, "file-new", "New File…", dialog) {
       defaultBinding("ctrl-n");
       _nameElement = _triggerOnReturn("#fileNewName");
   }

   void _invoke([List<ws.Folder> folders]) {
     if (folders != null && folders.isNotEmpty) {
       folder = folders.first;
       _nameElement.value = '';
       _show();
     } else {
       // create new file in sync fs on chrome os
       if (spark.platformInfo.isCros && spark.workspace.syncFsIsAvailable) {
          _nameElement.value = '';
          _show();
       } else { // use file save as for local fs
          spark.newFileAs();
       }
     }
   }

  // called when user validates the dialog
  void _commit() {
    var name = _nameElement.value;
    if (name.isNotEmpty) {
      if (folder != null) {
        folder.createNewFile(name).then((file) {
          // Delay a bit to allow the files view to process the new file event.
          // TODO: This is due to a race condition in when the files view receives
          // the resource creation event; we should remove the possibility for
          // this to occur.
          Timer.run(() {
            spark.selectInEditor(file, forceOpen: true, replaceCurrent: true);
          });
        });
      } else {
        spark.workspace.createFileSyncFs(name).then((file) {
          if (file != null) {
            Timer.run(() {
              spark.selectInEditor(file, forceOpen: true, replaceCurrent: true);
            });
          }
        });
      }
    }
  }

  String get category => 'folder';

  bool appliesTo(Object object) => _isSingleFolder(object);
}

class FileNewAsAction extends SparkAction {
  FileNewAsAction(Spark spark) : super(spark, "file-new-as", "New File…");

  void _invoke([Object context]) => spark.newFileAs();
}

class FileSaveAction extends SparkAction {
  FileSaveAction(Spark spark) : super(spark, "file-save", "Save") {
    defaultBinding("ctrl-s");
  }

  void _invoke([Object context]) => spark.editorManager.saveAll();
}

class FileDeleteAction extends SparkActionWithDialog implements ContextAction {
  List<ws.Resource> _resources;
  // TODO: Add _messageElement.

  FileDeleteAction(Spark spark, Element dialog)
      : super(spark, "file-delete", "Delete", dialog);

  void _invoke([List<ws.Resource> resources]) {
    if (resources == null) {
      var sel = spark._filesController.getSelection();
      if (sel.isNotEmpty) {
        _resources = sel;
        _setMessageAndShow();
      }
    } else {
      _resources = resources;
      _setMessageAndShow();
    }
  }

  void _setMessageAndShow() {
    if (_resources.length == 1) {
      getElement("#message").text =
          "Are you sure you want to delete '${_resources.first.name}'?";
    } else {
      getElement("#message").text =
          "Are you sure you want to delete ${_resources.length} files?";
    }

    _show();
  }

  void _commit() {
    _resources.forEach((ws.Resource resource) {
      resource.delete();
    });
    _resources = null;
  }

  String get category => 'resource-delete';

  bool appliesTo(Object object) => _isResourceList(object);
}

class FileRenameAction extends SparkActionWithDialog implements ContextAction {
  ws.Resource resource;
  InputElement _nameElement;

  FileRenameAction(Spark spark, Element dialog)
      : super(spark, "file-rename", "Rename…", dialog) {
    _nameElement = _triggerOnReturn("#renameFileName");
  }

  void _invoke([List<ws.Resource> resources]) {
   if (resources != null && resources.isNotEmpty) {
     resource = resources.first;
     _nameElement.value = resource.name;
     _show();
   }
  }

  void _commit() {
    if (_nameElement.value.isNotEmpty) {
      resource.rename(_nameElement.value)
        .then((value) {
          spark._renameOpenEditor(resource);
        });
    }
  }

  String get category => 'resource';

  bool appliesTo(Object object) => _isSingleResource(object) && !_isTopLevel(object);
}

class ResourceCloseAction extends SparkAction implements ContextAction {
  ResourceCloseAction(Spark spark) : super(spark, "file-close", "Close");

  void _invoke([List<ws.Resource> resources]) {
    if (resources == null) {
      resources = spark._getSelection();
    }

    for (ws.Resource resource in resources) {
      spark.workspace.unlink(resource);
      if (resource is ws.File) {
        spark._closeOpenEditor(resource);
      } else if (resource is ws.Project) {
        resource.traverse().forEach(spark._closeOpenEditor);
      }
    }

    spark.workspace.save();
  }

  String get category => 'resource';

  bool appliesTo(Object object) => _isTopLevel(object);
}

class FileExitAction extends SparkAction {
  FileExitAction(Spark spark) : super(spark, "file-exit", "Quit") {
    macBinding("ctrl-q");
    winBinding("ctrl-shift-f4");
  }

  void _invoke([Object context]) {
    spark.close().then((_) {
      chrome.app.window.current().close();
    });
  }
}

class ApplicationRunAction extends SparkAction implements ContextAction {
  ApplicationRunAction(Spark spark) : super(
      spark, "application-run", "Run Application") {
    defaultBinding("ctrl-r");

    enabled = false;

    spark.focusManager.onResourceChange.listen((r) => _updateEnablement(r));
  }

  void _invoke([context]) {
    ws.Resource resource;

    if (context == null) {
      resource = spark.focusManager.currentResource;
    } else {
      resource = context.first;
    }
    spark.launchManager.run(resource);
  }

  String get category => 'application';

  bool appliesTo(list) => list.length == 1 && _appliesTo(list.first);

  bool _appliesTo(ws.Resource resource) {
    return spark.launchManager.canRun(resource);
  }

  void _updateEnablement(ws.Resource resource) {
    enabled = _appliesTo(resource);
  }
}

class PrevMarkerAction extends SparkAction {
  PrevMarkerAction(Spark spark) : super(
      spark, "marker-prev", "Previous Marker") {
    defaultBinding("ctrl-shift-p");
  }

  void _invoke([Object context]) {
    spark._aceManager.selectPrevMarker();
  }
}

class NextMarkerAction extends SparkAction {
  NextMarkerAction(Spark spark) : super(
      spark, "marker-next", "Next Marker") {
    defaultBinding("ctrl-p");
  }

  void _invoke([Object context]) {
    spark._aceManager.selectNextMarker();
  }
}

class FolderNewAction extends SparkActionWithDialog implements ContextAction {
   InputElement _nameElement;
   ws.Folder folder;

   FolderNewAction(Spark spark, Element dialog)
     : super(spark, "folder-new", "New Folder…", dialog) {
     defaultBinding("ctrl-shift-n");
     _nameElement = _triggerOnReturn("#folderName");
   }

   void _invoke([List<ws.Folder> folders]) {
     if (folders != null && folders.isNotEmpty) {
       folder = folders.first;
       _nameElement.value = '';
       _show();
     }
   }

  // called when user validates the dialog
  void _commit() {
    var name = _nameElement.value;
    if (name.isNotEmpty) {
      folder.createNewFolder(name).then((folder) {
        // Delay a bit to allow the files view to process the new file event.
        Timer.run(() {
          spark._filesController.selectFile(folder);
        });
      });
    }
  }

  String get category => 'folder';

  bool appliesTo(Object object) => _isSingleFolder(object);
}

class FolderOpenAction extends SparkAction {
  FolderOpenAction(Spark spark) : super(spark, "folder-open", "Open Folder…");

  void _invoke([Object context]) => spark.openFolder();
}

/* Git operations */

class GitCloneAction extends SparkActionWithDialog {
  InputElement _repoUrlElement;

  GitCloneAction(Spark spark, Element dialog)
      : super(spark, "git-clone", "Git Clone…", dialog) {
    _repoUrlElement = _triggerOnReturn("#gitRepoUrl");
  }

  void _invoke([Object context]) {
    _show();
  }

  void _commit() {
    // TODO(grv): add verify checks.
    _GitCloneJob job = new _GitCloneJob(_repoUrlElement.value, spark);
    spark.jobManager.schedule(job);
  }
}

class GitBranchAction extends SparkActionWithDialog implements ContextAction {
  ws.Project project;
  InputElement _branchNameElement;

  GitBranchAction(Spark spark, Element dialog)
      : super(spark, "git-branch", "Git Branch…", dialog) {
    _branchNameElement = getElement("#gitBranchName");
  }

  void _invoke([context]) {
    // TODO: use the project as the git repo
    project = context.first;
    _show();
  }

  void _commit() {
    // TODO(grv): add verify checks.
    _GitBranchJob job = new _GitBranchJob(_branchNameElement.value, spark);
    spark.jobManager.schedule(job);
  }

  String get category => 'git';

  bool appliesTo(context) => _isProject(context) && scm.isUnderScm(context.first);
}

class GitCommitAction extends SparkActionWithDialog implements ContextAction {
  ws.Project project;
  InputElement _commitMessageElement;

  GitCommitAction(Spark spark, Element dialog)
      : super(spark, "git-commit", "Git Commit…", dialog) {
    _commitMessageElement = getElement("#commitMessage");
  }

  void _invoke([context]) {
    // TODO: use the project as the git repo
    project = context.first;
    _show();
  }

  void _commit() {
    // TODO(grv): add verify checks.
    _GitCommitJob job = new _GitCommitJob(_commitMessageElement.value, spark);
    spark.jobManager.schedule(job);
  }

  String get category => 'git';

  bool appliesTo(context) => _isProject(context) && scm.isUnderScm(context.first);
}

class GitCheckoutAction extends SparkActionWithDialog implements ContextAction {
  ws.Project project;
  SelectElement _branchSelectElement;

  GitCheckoutAction(Spark spark, Element dialog)
      : super(spark, "git-checkout", "Git Checkout…", dialog) {
    _branchSelectElement = getElement("#gitCheckout");
  }

  void _invoke([List context]) {
    // TODO: use the _project as the git repo
    project = context.first;
    ObjectStore store = spark._currentGitStore;

    store.getCurrentBranch().then((String currentBranch) {
      (getElement('#currentBranchName') as InputElement).value = currentBranch;

      store.getLocalBranches().then((List<String> branches) {
        branches.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        for (String branchName in branches) {
          _branchSelectElement.append(new OptionElement(data: branchName, value: branchName));
        }
      });

      _show();
    });
  }

  void _commit() {
    // TODO(grv): add verify checks.
    String branchName = _branchSelectElement.options[
        _branchSelectElement.selectedIndex].value;
    _GitCheckoutJob job = new _GitCheckoutJob(branchName, spark);
    spark.jobManager.schedule(job);
  }

  String get category => 'git';

  bool appliesTo(context) => _isProject(context) && scm.isUnderScm(context.first);
}

class _GitCloneJob extends Job {
  String projectName;
  String url;
  Spark spark;

  _GitCloneJob(this.url, this.spark) : super("Cloning …") {
    projectName = url.split('/').last;
    if (projectName.endsWith('.git')) {
      projectName = projectName.substring(0, projectName.length - 4);
    }
    if (!url.endsWith('.git')) {
      url = url + '.git';
    }
  }

  Future<Job> run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    Completer completer = new Completer();

    spark.projectLocationManager.createNewFolder(projectName).then((chrome.DirectoryEntry dir) {
      GitOptions options = new GitOptions(
          root: dir, repoUrl: url, depth: 1, store: new ObjectStore(dir));

      // TODO: We shouldn't have this be stateful.
      spark._currentGitStore = options.store;

      Clone clone = new Clone(options);
      return options.store.init().then((_) {
        return clone.clone().then((_) {
          return spark.workspace.link(dir).then((folder) {
            Timer.run(() {
              spark._filesController.selectFile(folder);
              spark._filesController.setFolderExpanded(folder);
            });
            spark.workspace.save();
          });
        });
      });
    }).whenComplete(() => completer.complete(this));

    return completer.future;
  }
}

class _GitBranchJob extends Job {
  String _branchName;
  String url;
  Spark spark;

  _GitBranchJob(this._branchName, this.spark)
  : super("Branch …");

  Future<Job> run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    Completer completer = new Completer();
    GitOptions options = new GitOptions();
    options.root = spark._gitDir;
    options.branchName = _branchName;
    options.store = spark._currentGitStore;
    Branch.branch(options).then((entry) {
      Checkout.checkout(options);
      // TODO(grv) : checkout the new branch.
    }, onError: (e) {
      print(e);
    }).whenComplete(() => completer.complete(this));

    return completer.future;
  }
}

class _GitCommitJob extends Job {
  String _commitMessage;
  Spark spark;

  _GitCommitJob(this._commitMessage, this.spark)
  : super("Commit …");

  Future<Job> run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    Completer completer = new Completer();
    GitOptions options = new GitOptions();
    options.root = spark._gitDir;
    options.commitMessage = _commitMessage;
    options.store = spark._currentGitStore;
    Commit.commit(options).then((_) {
      // TODO(grv) : add status line API for transitory success messages.
      print('commit successful.');

    }).whenComplete(() => completer.complete(this));
    return completer.future;
  }
}

class _GitCheckoutJob extends Job {
  String _branchName;
  Spark spark;

  _GitCheckoutJob(this._branchName, this.spark)
  : super("Checkout …");

  Future<Job> run(ProgressMonitor monitor) {
    monitor.start(name, 1);

    Completer completer = new Completer();
    GitOptions options = new GitOptions();
    options.root = spark._gitDir;
    options.branchName = _branchName;
    options.store = spark._currentGitStore;
    Checkout.checkout(options).then((_) {
      // TODO : add UI notification.
      print('checkout successful');
    }).whenComplete(() => completer.complete(this));
    return completer.future;
  }
}

// TODO(terry):  When only polymer overlays are used remove _initialized and
//               isPolymer's defintion and usage.
class AboutSparkAction extends SparkActionWithDialog {
  bool _initialized = false;

  AboutSparkAction(Spark spark, Element dialog)
      : super(spark, "help-about", "About Spark", dialog);

  void _invoke([Object context]) {
    if (!_initialized) {
      var checkbox = getElement('#analyticsCheck');
      checkbox.checked = _isTrackingPermitted;
      checkbox.onChange.listen((e) => _isTrackingPermitted = checkbox.checked);

      getElement('#aboutVersion').text = spark.appVersion;

      _initialized = true;
    }

    _show();
  }

  void _commit() {
    // Nothing to do for this dialog.
  }
}

class SettingAction extends SparkActionWithDialog {
  bool _initialized = false;

  SettingAction(Spark spark, Element dialog)
      : super(spark, "settings", "Setting", dialog);

  void _invoke([Object context]) {
    if (!_initialized) {

      _initialized = true;
    }

    _show();
  }

  void _commit() {
    // Nothing to do for this dialog.
  }
}

class RunTestsAction extends SparkAction {
  RunTestsAction(Spark spark) : super(spark, "run-tests", "Run Tests");

  _invoke([Object context]) => spark._testDriver.runTests();
}

// analytics code

void _handleUncaughtException(error, StackTrace stackTrace) {
  // We don't log the error object itself because of PII concerns.
  String errorDesc = error != null ? error.runtimeType.toString() : '';
  String desc = '${errorDesc}\n${minimizeStackTrace(stackTrace)}'.trim();

  _analyticsTracker.sendException(desc);
}

bool get _isTrackingPermitted =>
    _analyticsTracker.service.getConfig().isTrackingPermitted();

set _isTrackingPermitted(bool value) =>
    _analyticsTracker.service.getConfig().setTrackingPermitted(value);
