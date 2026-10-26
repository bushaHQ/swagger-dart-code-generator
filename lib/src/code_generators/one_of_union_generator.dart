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
    required this.elementType,
    this.allowedValues = const [],
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

  /// The type every item of a JSON array, or every value of a JSON object
  /// used as a map, must have to match this branch.
  final String? elementType;

  /// Dart literals of the only values a string or integer branch accepts,
  /// from its `enum`.
  final List<String> allowedValues;
}

/// A `oneOf` schema resolved to a sealed union.
class OneOfUnion {
  OneOfUnion({
    required this.className,
    required this.variants,
    required this.innerClasses,
    required this.discriminatorProperty,
    required this.unknownClassName,
  });

  final String className;

  /// The subclass holding JSON that matches no branch.
  final String unknownClassName;
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

  static const _unknown = 'Unknown';

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

  /// Whether [schema], or the items of [schema] when it is an array, is
  /// generated as a union under [key].
  bool hasOneOfUnion(String key, SwaggerSchema schema) =>
      resolveOneOfUnion(key, schema) != null ||
      switch (schema.items) {
        final items? => resolveOneOfUnion('$key\$Item', items) != null,
        null => false,
      };

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

    final kinds = _variantKinds(schema.oneOf, shapes);

    for (var i = 0; i < schema.oneOf.length; i++) {
      final shape = shapes[i];
      final kind = kinds[i];

      final variant = _resolveVariant(
        branch: schema.oneOf[i],
        shape: shape,
        variantClassName: _className('$unionKey\$$kind'),
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
      unknownClassName: _className('$unionKey\$$_unknown'),
    );
  }

  /// Names each branch's subclass: a `$ref` branch after the schema it refers
  /// to (`$Card`), any other branch after its JSON shape (`$Object`, `$Array`).
  /// Names that repeat, or clash with `$Unknown`, are numbered in order.
  List<String> _variantKinds(
    List<SwaggerSchema> branches,
    List<OneOfShape> shapes,
  ) {
    final names = [
      for (final (index, branch) in branches.indexed)
        branch.hasRef
            ? getValidatedClassName(branch.ref.getUnformattedRef())
            : _shapeNames[shapes[index]] ?? '',
    ];

    return [
      for (final (index, name) in names.indexed)
        names.where((other) => other == name).length > 1 || name == _unknown
            ? '$name${names.sublist(0, index).where((other) => other == name).length + 1}'
            : name,
    ];
  }

  /// Generates the sealed union class, one subclass per branch, and an
  /// `$Unknown` subclass holding JSON that matches no branch, like
  /// `swaggerGeneratedUnknown` for enums.
  String generateOneOfUnionClass(OneOfUnion union) {
    final name = union.className;

    final cases = <String>[];
    final unreachable = <String>[];
    for (final shape in OneOfShape.values) {
      final order = union.variants.indexOf;
      final variants = union.variants.where((v) => v.shape == shape).toList()
        ..sort(
          (a, b) => switch (_guardWeight(b, union) - _guardWeight(a, union)) {
            0 => order(a) - order(b),
            final byWeight => byWeight,
          },
        );

      final guards = <String>{};
      var matchesEverything = false;
      for (final variant in variants) {
        final guard = _guard(variant, union, ambiguous: variants.length > 1);
        if (matchesEverything || !guards.add(guard)) {
          unreachable.add(variant.className);
          continue;
        }
        cases.add(
          '    final ${_shapePatterns[shape]} json${guard.isEmpty ? '' : ' when $guard'} => ${variant.className}(${variant.fromJson}),',
        );
        matchesEverything = guard.isEmpty;
      }
    }

    if (unreachable.isNotEmpty) {
      print(
        '[WARNING] oneOf $name: ${unreachable.join(', ')} can never be matched, '
        'because an earlier branch of the same JSON shape accepts the same values. '
        'Add a discriminator, or required keys or enum values that tell the branches apart.',
      );
    }

    final unknown = OneOfVariant(
      className: union.unknownClassName,
      shape: OneOfShape.map,
      valueType: 'Object?',
      fromJson: 'json',
      toJson: 'value',
      requiredKeys: const [],
      discriminatorValue: null,
      elementType: null,
    );

    final variantClasses = [...union.variants, unknown]
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
    _ => ${union.unknownClassName}(json),
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

    if (branch.isEnum && branch.type != 'string' && branch.type != 'integer') {
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
      String? elementType,
      List<String> allowedValues = const [],
    }) => OneOfVariant(
      className: variantClassName,
      shape: shape,
      valueType: valueType,
      fromJson: fromJson,
      toJson: toJson,
      requiredKeys: requiredKeys,
      discriminatorValue: discriminatorValue,
      elementType: elementType,
      allowedValues: allowedValues,
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
        if (valueType == 'dynamic') {
          return variant(
            valueType: 'Map<String, dynamic>',
            fromJson: 'json',
            toJson: 'value',
          );
        }
        final elementType = _elementType(valueType);
        return variant(
          valueType: 'Map<String, $valueType>',
          fromJson:
              '{for (final MapEntry(:key, :value) in json.entries) if (value is $elementType) key: ${_fromElement('value', valueType)}}',
          toJson: 'value',
          elementType: elementType,
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
              fromJson: _listOf(basic),
              toJson: 'value',
              elementType: _elementType(basic),
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
                'json.whereType<Map<String, dynamic>>().map($type.fromJson).toList()',
            toJson: '[for (final item in value) item.toJson()]',
            elementType: 'Map<String, dynamic>',
          );
        }

        if (items.properties.isNotEmpty) {
          final key = '$innerKey\$Item';
          innerClasses[key] = items;
          final type = _className(key);
          return variant(
            valueType: 'List<$type>',
            fromJson:
                'json.whereType<Map<String, dynamic>>().map($type.fromJson).toList()',
            toJson: '[for (final item in value) item.toJson()]',
            elementType: 'Map<String, dynamic>',
          );
        }

        final basic = items.isEnum ? null : _basicType(items.type);
        if (basic != null) {
          return variant(
            valueType: 'List<$basic>',
            fromJson: _listOf(basic),
            toJson: 'value',
            elementType: _elementType(basic),
          );
        }
        return null;

      case OneOfShape.string:
        return variant(
          valueType: 'String',
          fromJson: 'json',
          toJson: 'value',
          allowedValues: [
            for (final value in branch.enumValuesObj)
              if (value is String) _stringLiteral(value),
          ],
        );
      case OneOfShape.integer:
        return variant(
          valueType: 'int',
          fromJson: 'json',
          toJson: 'value',
          allowedValues: [
            for (final value in branch.enumValuesObj)
              if (value is int) '$value',
          ],
        );
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

  /// The condition JSON of the right shape must meet to match [variant].
  ///
  /// Required keys and element types are always checked, so a matched branch
  /// never meets JSON it can't hold, and anything else becomes `$Unknown`.
  /// Discriminators only tell apart branches of the same shape, so they are
  /// left out when [variant] is the only one.
  String _guard(
    OneOfVariant variant,
    OneOfUnion union, {
    required bool ambiguous,
  }) {
    final conditions = [
      if (variant.shape == OneOfShape.map)
        if (union.discriminatorProperty case final property?
            when ambiguous && variant.discriminatorValue != null)
          "json['$property'] == '${variant.discriminatorValue}'"
        else
          for (final key in variant.requiredKeys) "json.containsKey('$key')",
      if (variant.allowedValues.isNotEmpty)
        'const {${variant.allowedValues.join(', ')}}.contains(json)',
      if (variant.elementType case final type?)
        switch (variant.shape) {
          OneOfShape.list => 'json.every((item) => item is $type)',
          _ => 'json.values.every((value) => value is $type)',
        },
    ];
    return conditions.join(' && ');
  }

  int _guardWeight(OneOfVariant variant, OneOfUnion union) {
    if (union.discriminatorProperty != null &&
        variant.discriminatorValue != null) {
      return 1 << 20;
    }
    return variant.requiredKeys.length * 2 +
        (variant.elementType == null ? 0 : 1) +
        (variant.allowedValues.isEmpty ? 0 : 1);
  }

  SwaggerSchema? _resolveRef(String ref) {
    final name = ref.getUnformattedRef();
    return oneOfClasses[getValidatedClassName(name)] ?? oneOfClasses[name];
  }

  String _className(String key) =>
      '${getValidatedClassName(key)}${options.modelPostfix}';

  String _additionalPropertiesType(SwaggerSchema branch) =>
      switch (branch.rawJson?['additionalProperties']) {
        {'type': final String type} => _basicType(type) ?? 'dynamic',
        _ => 'dynamic',
      };

  String? _basicType(String type) => switch (type) {
    'string' => 'String',
    'integer' => 'int',
    'number' => 'double',
    'boolean' => 'bool',
    _ => null,
  };

  /// [value] as a single-quoted Dart string literal.
  String _stringLiteral(String value) {
    final escaped = value
        .replaceAll(r'\', r'\\')
        .replaceAll("'", r"\'")
        .replaceAll(r'$', r'\$')
        .replaceAll('\n', r'\n');
    return "'$escaped'";
  }

  /// The type a JSON value has before it is converted to the basic [type].
  String _elementType(String type) => type == 'double' ? 'num' : type;

  /// Converts [variable], already known to be an [_elementType], to [type].
  String _fromElement(String variable, String type) =>
      type == 'double' ? '$variable.toDouble()' : variable;

  /// Builds a list of the basic [type] from a JSON array whose items were
  /// already checked by the guard.
  String _listOf(String type) => type == 'double'
      ? 'json.whereType<num>().map((item) => item.toDouble()).toList()'
      : 'json.whereType<$type>().toList()';

  _Discriminator? _discriminator(SwaggerSchema schema) =>
      switch (schema.rawJson?['discriminator']) {
        {'propertyName': final String property} && final Map raw =>
          _Discriminator(property, {
            if (raw['mapping'] case final Map mapping)
              for (final MapEntry(:key, :value) in mapping.entries)
                if ((key, value) case (final String key, final String ref))
                  ref.getUnformattedRef(): key,
          }),
        _ => null,
      };
}

class _Discriminator {
  _Discriminator(this.property, this.valuesByRef);

  final String property;
  final Map<String, String> valuesByRef;

  String valueFor(String refName) => valuesByRef[refName] ?? refName;
}
