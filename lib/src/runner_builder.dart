import 'dart:io';
import 'dart:isolate';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:dart_style/dart_style.dart';
import 'package:path/path.dart' as path;
import 'package:source_gen/source_gen.dart';

import '../super_annotations.dart';
import 'code_builder_string.dart';
import 'imports_builder.dart';

const classAnnotationChecker = TypeChecker.fromRuntime(ClassAnnotation);
const enumAnnotationChecker = TypeChecker.fromRuntime(EnumAnnotation);
const functionAnnotationChecker = TypeChecker.fromRuntime(FunctionAnnotation);
const codeGenChecker = TypeChecker.fromRuntime(CodeGen);

class RunnerBuilder {
  final BuildStep buildStep;
  final String target;
  final DartObject annotation;
  final Map<String, dynamic> config;

  final AssetId runnerId;

  RunnerBuilder(this.buildStep, this.target, this.annotation, this.config)
      : runnerId = buildStep.inputId.changeExtension('.runner.g.dart');

  Future<void> create() async {
    Map<ClassElement, List<String>> classTargets = {};
    Map<EnumElement, List<String>> enumTargets = {};
    Map<FunctionElement, List<String>> functionTargets = {};

    var imports = ImportsBuilder(buildStep.inputId)
      ..add(Uri.parse('dart:isolate'))
      ..add(Uri.parse('package:super_annotations/super_annotations.dart'));

    handleLibrary(LibraryElement library) {
      classTargets.addAll(inspectElements(
        library.units.expand((u) => u.classes),
        classAnnotationChecker,
        imports,
      ));

      enumTargets.addAll(inspectElements(
        library.units.expand((u) => u.enums),
        enumAnnotationChecker,
        imports,
      ));

      functionTargets.addAll(inspectElements(
        library.units.expand((u) => u.functions),
        functionAnnotationChecker,
        imports,
      ));
    }

    var discoveryMode = DiscoveryMode.values[
        annotation.getField('discoveryMode')!.getField('index')!.toIntValue()!];

    if (discoveryMode == DiscoveryMode.recursiveImports) {
      await for (var library in buildStep.resolver.libraries) {
        if (library.isInSdk) continue;
        handleLibrary(library);
      }
    } else if (discoveryMode == DiscoveryMode.inputLibrary) {
      handleLibrary(await buildStep.inputLibrary);
    }

    var runAfter = getHooks(annotation.getField('runAfter'), imports);
    var runBefore = getHooks(annotation.getField('runBefore'), imports);

    var runAnnotations = [
      ...classTargets.entries.map((e) => e.key.builder(imports, e.value)),
      ...enumTargets.entries.map((e) => e.key.builder(imports, e.value)),
      ...functionTargets.entries.map((e) => e.key.builder(imports, e.value)),
    ];

    var runnerCode = """
      ${imports.write()}
      
      void main(List<String> args, SendPort port) {
        CodeGen.currentFile = '${path.basename(buildStep.inputId.path)}';
        CodeGen.currentTarget = '${target.escaped}';
        var library = Library((l) {
          ${runBefore.map((fn) => '$fn(l);\n').join()}
          ${runAnnotations.join('\n')}
          ${runAfter.map((fn) => '$fn(l);\n').join()}
        });
        port.send(library.accept(DartEmitter.scoped(useNullSafetySyntax: true)).toString());
      }
    """;

    await File(runnerId.path).writeAsString(
        DartFormatter(languageVersion: DartFormatter.latestLanguageVersion)
            .format(runnerCode));
  }

  Map<E, List<String>> inspectElements<E extends Element>(
    Iterable<E> elements,
    TypeChecker checker,
    ImportsBuilder imports,
  ) {
    Map<E, List<String>> targets = {};
    for (var elem in elements) {
      for (var meta in elem.metadata) {
        if (meta.element is ConstructorElement) {
          var parent = (meta.element! as ConstructorElement).enclosingElement3;
          if (checker.isAssignableFrom(parent)) {
            (targets[elem] ??= []).add(meta.toSource().substring(1));
            imports.add(meta.element!.library!.source.uri);
          }
        } else if (meta.element is PropertyAccessorElement) {
          var type = (meta.element! as PropertyAccessorElement).returnType;
          if (checker.isAssignableFromType(type)) {
            (targets[elem] ??= []).add(meta.toSource().substring(1));
            imports.add(meta.element!.library!.source.uri);
          }
        }
      }
    }
    return targets;
  }

  Iterable<String> getHooks(DartObject? object, ImportsBuilder imports) {
    if (object == null) return [];
    var hooks = <String>[];
    for (var o in object.toListValue() ?? <DartObject>[]) {
      var fn = o.toFunctionValue();
      if (fn != null) {
        if (fn.isStatic && fn.enclosingElement3 is ClassElement) {
          hooks.add('${fn.enclosingElement3.name}.${fn.name}');
        } else {
          hooks.add(fn.name);
        }
        imports.add(fn.library.source.uri);
      }
    }
    return hooks;
  }

  Future<String> execute() async {
    var dataPort = ReceivePort();

    var resultFuture = dataPort.first;

    try {
      await Isolate.spawnUri(
        runnerId.uri,
        [],
        dataPort.sendPort,
        onExit: dataPort.sendPort,
        onError: dataPort.sendPort,
      );
    } on IsolateSpawnException catch (e) {
      var m = 'Unable to spawn isolate: ';
      if (e.message.startsWith(m)) {
        var message = e.message.substring(m.length);
        throw RunnerException(message);
      } else {
        rethrow;
      }
    }

    var result = await resultFuture;

    if (result is String) {
      return result;
    } else {
      print(result);
      throw Exception('Runner did fail with the output above.');
    }
  }

  Future<void> cleanup() async {
    await File(runnerId.path).delete();
  }

  Future<String> run() async {
    await create();
    var result = await execute();
    if (config['cleanup'] != false) {
      await cleanup();
    }
    return result;
  }
}

class RunnerException implements Exception {
  String message;

  RunnerException(this.message);

  @override
  String toString() {
    return 'Cannot run code generation. There probably is a error in your annotation code. See the output below for more details:\n\n$message';
  }
}
