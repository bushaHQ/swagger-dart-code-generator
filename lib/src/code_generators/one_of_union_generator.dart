import 'package:swagger_dart_code_generator/src/code_generators/swagger_generator_base.dart';
import 'package:swagger_dart_code_generator/src/extensions/string_extension.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/responses/swagger_schema.dart';
import 'package:swagger_dart_code_generator/src/swagger_models/swagger_root.dart';

/// The JSON shape a `oneOf` branch decodes from.
enum OneOfShape { map, list, string, integer, number, boolean }

/// One branch of a `oneOf`, resolved to the Dart type it decodes into.
class OneOfVariant {
  OneOfVariant({
    required this.className,
    required this.shape,
    required this.valueType,
    required this.fromJson,
    required this.toJson,
    required this.requiredKeys,
    required this.discriminatorValue,
    required this.itemCheck,
  });

  /// The generated subclass of the union that holds this branch.
  final String className;
  final OneOfShape shape;

  /// The Dart type of the value the subclass holds.
  final String valueType;

  /// Expression that builds the value from a matched `json`.
  final String fromJson;

  /// Expression that writes `value` back to JSON.
  final String toJson;

  /// Keys a JSON object must contain to match this branch.
  final List<String> requiredKeys;

  /// The discriminator value that selects this branch, when the `oneOf`
  /// declares a discriminator.
  final String? discriminatorValue;

  /// Type test every `item` of a JSON array must pass to match this branch.
  final String? itemCheck;
}

/// A `oneOf` schema resolved to a sealed union.
class OneOfUnion {
  OneOfUnion({
    required this.className,
    required this.variants,
    required this.innerClasses,
    required this.discriminatorProperty,
  });

  final String className;
  final List<OneOfVariant> variants;

  /// Inline object schemas used by the variants, keyed by the class name they
  /// are generated under.
  final Map<String, SwaggerSchema> innerClasses;

  final String? discriminatorProperty;
}

/// Generates a sealed class for every `oneOf` with more than one branch, so the
/// property is typed instead of `dynamic`.
///
/// Only enabled with the `generate_one_of_unions` option. A `oneOf` with a
/// branch that can't be typed keeps the previous `dynamic` behaviour.
mixin OneOfUnionGenerator on SwaggerGeneratorBase {
  /// Every class the models are generated from, used to resolve `$ref`
  /// branches. Set before the classes are generated.
  Map<String, SwaggerSchema> oneOfClasses = {};

  static const _shapeNames = {
    OneOfShape.map: 'Object',
    OneOfShape.list: 'Array',
    OneOfShape.string: 'String',
    OneOfShape.integer: 'Integer',
    OneOfShape.number: 'Number',
    OneOfShape.boolean: 'Boolean',
  };

  static const _shapePatterns = {
    OneOfShape.map: 'Map<String, dynamic>',
    OneOfShape.list: 'List<dynamic>',
    OneOfShape.string: 'String',
    OneOfShape.integer: 'int',
    OneOfShape.number: 'num',
    OneOfShape.boolean: 'bool',
  };

  /// The key a union property of [className] is generated under, matching the
  /// names of other inner classes.
  String oneOfPropertyKey(
    String className,
    String propertyKey,
  ) => getValidatedClassName(
    '${getValidatedClassName(className)}\$${getValidatedClassName(propertyKey)}',
  );

  /// Removes `type: 'null'` branches from every `oneOf` in [root] and marks the
  /// schema nullable instead. A property or array item left with a single
  /// branch is replaced by that branch, so it is typed like any other schema.
  ///
  /// Safe to call more than once on the same root.
  void normalizeNullableOneOfs(SwaggerRoot root) {
    if (!options.generateOneOfUnions) {
      return;
    }

    final visited = Set<SwaggerSchema>.identity();

    void visit(SwaggerSchema? schema) {
      if (schema == null || !visited.add(schema)) {
        return;
      }

      _dropNullBranches(schema);

      if (schema.properties.isNotEmpty) {
        for (final MapEntry(:key, :value)
            in schema.properties.entries.toList()) {
          final collapsed = _collapseNullableOneOf(value);
          if (!identical(collapsed, value)) {
            schema.properties[key] = collapsed;
          }
          visit(collapsed);
        }
      }

      if (schema.items case final items?) {
        final collapsed = _collapseNullableOneOf(items);
        schema.items = collapsed;
        visit(collapsed);
      }

      for (final branch in [
        ...schema.oneOf,
        ...schema.anyOf,
        ...schema.allOf,
      ]) {
        visit(branch);
      }
      visit(schema.schema);
    }

    final components = root.components;
    [
      ...root.definitions.values,
      ...?components?.schemas.values,
      ...?components?.responses.values,
      ...?components?.requestBodies.values,
    ].forEach(visit);

    for (final parameter in [
      ...root.parameters.values,
      ...?components?.parameters.values,
    ]) {
      visit(parameter.schema);
    }

    for (final path in root.paths.values) {
      for (final parameter in path.parameters) {
        visit(parameter.schema);
      }
      for (final request in path.requests.values) {
        for (final parameter in request.parameters) {
          visit(parameter.schema);
        }
        visit(request.requestBody?.content?.schema);
        for (final response in request.responses.values) {
          visit(response.schema);
          visit(response.content?.schema);
          visit(response.content?.items);
        }
      }
    }
  }

  bool _dropNullBranches(SwaggerSchema schema) {
    bool isNull(SwaggerSchema branch) =>
        branch.type == 'null' && !branch.hasRef;

    if (!schema.oneOf.any(isNull)) {
      return false;
    }

    schema.oneOf = schema.oneOf.where((branch) => !isNull(branch)).toList();
    schema.isNullable = true;
    return true;
  }

  SwaggerSchema _collapseNullableOneOf(SwaggerSchema schema) {
    if (!_dropNullBranches(schema) || schema.oneOf.length != 1) {
      return schema;
    }

    return schema.oneOf.single
      ..isNullable = true
      ..deprecated = schema.deprecated || schema.oneOf.single.deprecated;
  }

  /// Resolves [schema] to a union named after [unionKey], or returns `null`
  /// when the option is off, the schema has fewer than two branches, or a
  /// branch can't be typed.
  OneOfUnion? resolveOneOfUnion(String unionKey, SwaggerSchema schema) {
    if (!options.generateOneOfUnions || schema.oneOf.length < 2) {
      return null;
    }

    final shapes = <OneOfShape>[];
    for (final branch in schema.oneOf) {
      final shape = _shapeOf(branch);
      if (shape == null) {
        return null;
      }
      shapes.add(shape);
    }

    final unionName =
        '${getValidatedClassName(unionKey)}${options.modelPostfix}';
    final discriminator = _discriminator(schema);
    final innerClasses = <String, SwaggerSchema>{};
    final variants = <OneOfVariant>[];

    for (var i = 0; i < schema.oneOf.length; i++) {
      final shape = shapes[i];
      final sameShape = shapes.where((s) => s == shape).length;
      final position = shapes.sublist(0, i).where((s) => s == shape).length;
      final kind =
          '${_shapeNames[shape]}${sameShape > 1 ? '${position + 1}' : ''}';

      final variant = _resolveVariant(
        branch: schema.oneOf[i],
        shape: shape,
        variantClassName: '$unionName\$$kind',
        innerKey: '$unionKey\$$kind',
        innerClasses: innerClasses,
        discriminator: discriminator,
      );
      if (variant == null) {
        return null;
      }
      variants.add(variant);
    }

    return OneOfUnion(
      className: unionName,
      variants: variants,
      innerClasses: innerClasses,
      discriminatorProperty: discriminator?.property,
    );
  }

  /// Generates the sealed union class and one subclass per branch.
  String generateOneOfUnionClass(OneOfUnion union) {
    final name = union.className;

    final cases = <String>[];
    for (final shape in OneOfShape.values) {
      final variants = union.variants.where((v) => v.shape == shape).toList()
        ..sort((a, b) => _guardWeight(b, union) - _guardWeight(a, union));

      for (final variant in variants) {
        final guard = variants.length > 1 ? _guard(variant, union) : '';
        cases.add(
          '    final ${_shapePatterns[shape]} json${guard.isEmpty ? '' : ' when $guard'} => ${variant.className}(${variant.fromJson}),',
        );
        if (guard.isEmpty) {
          break;
        }
      }
    }

    final variantClasses = union.variants
        .map((variant) {
          final equality = options.overrideEqualsAndHashcode
              ? '''


  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ${variant.className} &&
          const DeepCollectionEquality().equals(other.value, value);

  @override
  int get hashCode => const DeepCollectionEquality().hash(value);'''
              : '';

          final toString = options.overrideToString
              ? '''


  @override
  String toString() => jsonEncode(toJson());'''
              : '';

          return '''
final class ${variant.className} extends $name {
  const ${variant.className}(this.value);

  final ${variant.valueType} value;

  @override
  Object? toJson() => ${variant.toJson};$equality$toString
}
''';
        })
        .join('\n');

    return '''
sealed class $name {
  const $name();

  factory $name.fromJson(Object? json) => switch (json) {
${cases.join('\n')}
    _ => throw ArgumentError.value(json, 'json', 'Does not match any variant'),
  };

  static const fromJsonFactory = $name.fromJson;

  Object? toJson();
}

$variantClasses''';
  }

  OneOfShape? _shapeOf(SwaggerSchema branch) {
    if (branch.hasRef) {
      final target = _resolveRef(branch.ref);
      if (target == null) {
        return OneOfShape.map;
      }
      if (target.isEnum || target.oneOf.isNotEmpty || target.anyOf.isNotEmpty) {
        return null;
      }
      if (target.type.isEmpty || target.type == 'object') {
        return OneOfShape.map;
      }
      return null;
    }

    if (branch.isEnum && branch.type != 'string') {
      return null;
    }

    switch (branch.type) {
      case 'object':
        return OneOfShape.map;
      case '':
        return branch.properties.isNotEmpty ? OneOfShape.map : null;
      case 'array':
        return OneOfShape.list;
      case 'string':
        return OneOfShape.string;
      case 'integer':
        return OneOfShape.integer;
      case 'number':
        return OneOfShape.number;
      case 'boolean':
        return OneOfShape.boolean;
    }
    return null;
  }

  OneOfVariant? _resolveVariant({
    required SwaggerSchema branch,
    required OneOfShape shape,
    required String variantClassName,
    required String innerKey,
    required Map<String, SwaggerSchema> innerClasses,
    required _Discriminator? discriminator,
  }) {
    OneOfVariant variant({
      required String valueType,
      required String fromJson,
      required String toJson,
      List<String> requiredKeys = const [],
      String? discriminatorValue,
      String? itemCheck,
    }) => OneOfVariant(
      className: variantClassName,
      shape: shape,
      valueType: valueType,
      fromJson: fromJson,
      toJson: toJson,
      requiredKeys: requiredKeys,
      discriminatorValue: discriminatorValue,
      itemCheck: itemCheck,
    );

    switch (shape) {
      case OneOfShape.map:
        if (branch.hasRef) {
          final refName = branch.ref.getUnformattedRef();
          final type = _className(refName);
          return variant(
            valueType: type,
            fromJson: '$type.fromJson(json)',
            toJson: 'value.toJson()',
            requiredKeys: _resolveRef(branch.ref)?.required ?? const [],
            discriminatorValue: discriminator?.valueFor(refName),
          );
        }

        if (branch.properties.isNotEmpty) {
          final key = '$innerKey\$Value';
          innerClasses[key] = branch;
          final type = _className(key);
          return variant(
            valueType: type,
            fromJson: '$type.fromJson(json)',
            toJson: 'value.toJson()',
            requiredKeys: branch.required,
          );
        }

        final valueType = _additionalPropertiesType(branch);
        return variant(
          valueType: 'Map<String, $valueType>',
          fromJson: valueType == 'dynamic'
              ? 'json'
              : '{for (final MapEntry(:key, :value) in json.entries) key: ${_cast('value', valueType)}}',
          toJson: 'value',
        );

      case OneOfShape.list:
        final items = branch.items;
        if (items == null) {
          return variant(
            valueType: 'List<dynamic>',
            fromJson: 'json',
            toJson: 'value',
          );
        }

        if (items.hasRef) {
          final target = _resolveRef(items.ref);
          final basic = target == null ? null : _basicType(target.type);
          if (basic != null && target?.isEnum != true) {
            return variant(
              valueType: 'List<$basic>',
              fromJson: '[for (final item in json) ${_cast('item', basic)}]',
              toJson: 'value',
              itemCheck: _itemCheck(basic),
            );
          }
          if (target != null &&
              (target.isEnum ||
                  !(target.type.isEmpty || target.type == 'object'))) {
            return null;
          }
          final type = _className(items.ref.getUnformattedRef());
          return variant(
            valueType: 'List<$type>',
            fromJson:
                '[for (final item in json) $type.fromJson(item as Map<String, dynamic>)]',
            toJson: '[for (final item in value) item.toJson()]',
            itemCheck: 'item is Map<String, dynamic>',
          );
        }

        if (items.properties.isNotEmpty) {
          final key = '$innerKey\$Item';
          innerClasses[key] = items;
          final type = _className(key);
          return variant(
            valueType: 'List<$type>',
            fromJson:
                '[for (final item in json) $type.fromJson(item as Map<String, dynamic>)]',
            toJson: '[for (final item in value) item.toJson()]',
            itemCheck: 'item is Map<String, dynamic>',
          );
        }

        final basic = items.isEnum ? null : _basicType(items.type);
        if (basic != null) {
          return variant(
            valueType: 'List<$basic>',
            fromJson: '[for (final item in json) ${_cast('item', basic)}]',
            toJson: 'value',
            itemCheck: _itemCheck(basic),
          );
        }
        return null;

      case OneOfShape.string:
        return variant(valueType: 'String', fromJson: 'json', toJson: 'value');
      case OneOfShape.integer:
        return variant(valueType: 'int', fromJson: 'json', toJson: 'value');
      case OneOfShape.number:
        return variant(
          valueType: 'double',
          fromJson: 'json.toDouble()',
          toJson: 'value',
        );
      case OneOfShape.boolean:
        return variant(valueType: 'bool', fromJson: 'json', toJson: 'value');
    }
  }

  String _guard(OneOfVariant variant, OneOfUnion union) {
    if (variant.shape == OneOfShape.list) {
      return switch (variant.itemCheck) {
        final check? => 'json.every((item) => $check)',
        null => '',
      };
    }
    if (variant.shape != OneOfShape.map) {
      return '';
    }
    if (union.discriminatorProperty case final property?
        when variant.discriminatorValue != null) {
      return "json['$property'] == '${variant.discriminatorValue}'";
    }
    return variant.requiredKeys
        .map((key) => "json.containsKey('$key')")
        .join(' && ');
  }

  int _guardWeight(OneOfVariant variant, OneOfUnion union) {
    if (union.discriminatorProperty != null &&
        variant.discriminatorValue != null) {
      return 1 << 20;
    }
    return switch (variant.shape) {
      OneOfShape.map => variant.requiredKeys.length,
      OneOfShape.list => variant.itemCheck == null ? 0 : 1,
      _ => 0,
    };
  }

  SwaggerSchema? _resolveRef(String ref) {
    final name = ref.getUnformattedRef();
    return oneOfClasses[getValidatedClassName(name)] ?? oneOfClasses[name];
  }

  String _className(String key) =>
      '${getValidatedClassName(key)}${options.modelPostfix}';

  String _additionalPropertiesType(SwaggerSchema branch) {
    final additional = branch.rawJson?['additionalProperties'];
    if (additional is Map && additional['type'] is String) {
      return _basicType(additional['type'] as String) ?? 'dynamic';
    }
    return 'dynamic';
  }

  String? _basicType(String type) => switch (type) {
    'string' => 'String',
    'integer' => 'int',
    'number' => 'double',
    'boolean' => 'bool',
    _ => null,
  };

  String _itemCheck(String type) => switch (type) {
    'double' => 'item is num',
    _ => 'item is $type',
  };

  String _cast(String expression, String type) => switch (type) {
    'double' => '($expression as num).toDouble()',
    _ => '$expression as $type',
  };

  _Discriminator? _discriminator(SwaggerSchema schema) {
    final raw = schema.rawJson?['discriminator'];
    if (raw is! Map || raw['propertyName'] is! String) {
      return null;
    }
    final mapping = <String, String>{};
    if (raw['mapping'] case final Map values) {
      values.forEach((key, value) {
        if (key is String && value is String) {
          mapping[value.getUnformattedRef()] = key;
        }
      });
    }
    return _Discriminator(raw['propertyName'] as String, mapping);
  }
}

class _Discriminator {
  _Discriminator(this.property, this.valuesByRef);

  final String property;
  final Map<String, String> valuesByRef;

  String valueFor(String refName) => valuesByRef[refName] ?? refName;
}
