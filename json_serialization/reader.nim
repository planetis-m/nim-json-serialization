{.experimental: "notnil".}

import
  std/[tables, strutils, typetraits, macros, strformat],
  faststreams/inputs, serialization/[formats, object_serialization, errors],
  format, types, lexer

from json import JsonNode, JsonNodeKind

export
  format, types, errors

type
  JsonReader*[Flavor = DefaultFlavor] = object
    lexer*: JsonLexer
    allowUnknownFields: bool
    requireAllFields: bool

  JsonReaderError* = object of JsonError
    line*, col*: int

  UnexpectedField* = object of JsonReaderError
    encounteredField*: cstring
    deserializedType*: cstring

  ExpectedTokenCategory* = enum
    etValue = "value"
    etBool = "bool literal"
    etInt = "integer"
    etEnum = "enum value (int or string)"
    etNumber = "number"
    etString = "string"
    etComma = "comma"
    etColon = "colon"
    etBracketLe = "array start bracket"
    etBracketRi = "array end bracker"
    etCurrlyLe = "object start bracket"
    etCurrlyRi = "object end bracket"

  GenericJsonReaderError* = object of JsonReaderError
    deserializedField*: string
    innerException*: ref CatchableError

  UnexpectedTokenError* = object of JsonReaderError
    encountedToken*: TokKind
    expectedToken*: ExpectedTokenCategory

  UnexpectedValueError* = object of JsonReaderError

  IncompleteObjectError* = object of JsonReaderError
    objectType: cstring

  IntOverflowError* = object of JsonReaderError
    isNegative: bool
    absIntVal: uint64

Json.setReader JsonReader

func valueStr(err: ref IntOverflowError): string =
  if err.isNegative:
    result.add '-'
  result.add($err.absIntVal)

template tryFmt(expr: untyped): string =
  try: expr
  except CatchableError as err: err.msg

method formatMsg*(err: ref JsonReaderError, filename: string):
    string {.gcsafe, raises: [Defect].} =
  tryFmt: fmt"{filename}({err.line}, {err.col}) Error while reading json file"

method formatMsg*(err: ref UnexpectedField, filename: string):
    string {.gcsafe, raises: [Defect].} =
  tryFmt: fmt"{filename}({err.line}, {err.col}) Unexpected field '{err.encounteredField}' while deserializing {err.deserializedType}"

method formatMsg*(err: ref UnexpectedTokenError, filename: string):
    string {.gcsafe, raises: [Defect].} =
  tryFmt: fmt"{filename}({err.line}, {err.col}) Unexpected token '{err.encountedToken}' in place of '{err.expectedToken}'"

method formatMsg*(err: ref GenericJsonReaderError, filename: string):
    string {.gcsafe, raises: [Defect].} =
  tryFmt: fmt"{filename}({err.line}, {err.col}) Exception encountered while deserializing '{err.deserializedField}': [{err.innerException.name}] {err.innerException.msg}"

method formatMsg*(err: ref IntOverflowError, filename: string):
    string {.gcsafe, raises: [Defect].} =
  tryFmt: fmt"{filename}({err.line}, {err.col}) The value '{err.valueStr}' is outside of the allowed range"

method formatMsg*(err: ref UnexpectedValueError, filename: string):
    string {.gcsafe, raises: [Defect].} =
  tryFmt: fmt"{filename}({err.line}, {err.col}) {err.msg}"

method formatMsg*(err: ref IncompleteObjectError, filename: string):
    string {.gcsafe, raises: [Defect].} =
  tryFmt: fmt"{filename}({err.line}, {err.col}) Not all required fields were specified when reading '{err.objectType}'"

proc assignLineNumber*(ex: ref JsonReaderError, r: JsonReader) =
  ex.line = r.lexer.line
  ex.col = r.lexer.tokenStartCol

proc raiseUnexpectedToken*(r: JsonReader, expected: ExpectedTokenCategory)
                          {.noreturn.} =
  var ex = new UnexpectedTokenError
  ex.assignLineNumber(r)
  ex.encountedToken = r.lexer.tok
  ex.expectedToken = expected
  raise ex

proc raiseUnexpectedValue*(r: JsonReader, msg: string) {.noreturn.} =
  var ex = new UnexpectedValueError
  ex.assignLineNumber(r)
  ex.msg = msg
  raise ex

proc raiseIntOverflow*(r: JsonReader, absIntVal: uint64, isNegative: bool) {.noreturn.} =
  var ex = new IntOverflowError
  ex.assignLineNumber(r)
  ex.absIntVal = absIntVal
  ex.isNegative = isNegative
  raise ex

proc raiseUnexpectedField*(r: JsonReader, fieldName, deserializedType: cstring) {.noreturn.} =
  var ex = new UnexpectedField
  ex.assignLineNumber(r)
  ex.encounteredField = fieldName
  ex.deserializedType = deserializedType
  raise ex

proc raiseIncompleteObject*(r: JsonReader, objectType: cstring) {.noreturn.} =
  var ex = new IncompleteObjectError
  ex.assignLineNumber(r)
  ex.objectType = objectType
  raise ex

proc handleReadException*(r: JsonReader,
                          Record: type,
                          fieldName: string,
                          field: auto,
                          err: ref CatchableError) =
  var ex = new GenericJsonReaderError
  ex.assignLineNumber(r)
  ex.deserializedField = fieldName
  ex.innerException = err
  raise ex

proc init*(T: type JsonReader,
           stream: InputStream,
           mode = defaultJsonMode,
           allowUnknownFields = false,
           requireAllFields = false): T =
  result.allowUnknownFields = allowUnknownFields
  result.requireAllFields = requireAllFields
  result.lexer = JsonLexer.init(stream, mode)
  result.lexer.next()

proc setParsed[T: enum](e: var T, s: string) =
  e = parseEnum[T](s)

proc requireToken*(r: JsonReader, tk: TokKind) =
  if r.lexer.tok != tk:
    r.raiseUnexpectedToken case tk
      of tkString: etString
      of tkInt, tkNegativeInt: etInt
      of tkComma: etComma
      of tkBracketRi: etBracketRi
      of tkBracketLe: etBracketLe
      of tkCurlyRi: etCurrlyRi
      of tkCurlyLe: etCurrlyLe
      of tkColon: etColon
      else: (doAssert false; etBool)

proc skipToken*(r: var JsonReader, tk: TokKind) =
  r.requireToken tk
  r.lexer.next()

func maxAbsValue(T: type[SomeInteger]): uint64 {.compileTime.} =
  when T is int8 : 128'u64
  elif T is int16: 32768'u64
  elif T is int32: 2147483648'u64
  elif T is int64: 9223372036854775808'u64
  else: uint64(high(T))

proc parseJsonNode(r: var JsonReader): JsonNode
                  {.gcsafe, raises: [IOError, JsonReaderError, Defect].}

proc readJsonNodeField(r: var JsonReader, field: var JsonNode) =
  if field != nil:
    r.raiseUnexpectedValue("Unexpected duplicated field name")

  r.lexer.next()
  r.skipToken tkColon

  field = r.parseJsonNode()

proc parseJsonNode(r: var JsonReader): JsonNode =
  const maxIntValue = maxAbsValue(BiggestInt)

  case r.lexer.tok
  of tkCurlyLe:
    result = JsonNode(kind: JObject)
    r.lexer.next()
    if r.lexer.tok != tkCurlyRi:
      while r.lexer.tok == tkString:
        try:
          r.readJsonNodeField(result.fields.mgetOrPut(r.lexer.strVal, nil))
        except KeyError:
          raiseAssert "mgetOrPut should never raise a KeyError"
        if r.lexer.tok == tkComma:
          r.lexer.next()
        else:
          break
    r.skipToken tkCurlyRi

  of tkBracketLe:
    result = JsonNode(kind: JArray)
    r.lexer.next()
    if r.lexer.tok != tkBracketRi:
      while true:
        result.elems.add r.parseJsonNode()
        if r.lexer.tok == tkBracketRi:
          break
        else:
          r.skipToken tkComma
    # Skip over the last tkBracketRi
    r.lexer.next()

  of tkColon, tkComma, tkEof, tkError, tkBracketRi, tkCurlyRi:
    r.raiseUnexpectedToken etValue

  of tkString:
    result = JsonNode(kind: JString, str: r.lexer.strVal)
    r.lexer.next()

  of tkInt:
    if r.lexer.absIntVal > maxIntValue:
      r.raiseIntOverflow(r.lexer.absIntVal, false)
    else:
      result = JsonNode(kind: JInt, num: BiggestInt r.lexer.absIntVal)
      r.lexer.next()

  of tkNegativeInt:
    if r.lexer.absIntVal > maxIntValue + 1:
      r.raiseIntOverflow(r.lexer.absIntVal, true)
    else:
      # `0 - x` is a magical trick that turns the unsigned
      # value into its negative signed counterpart:
      result = JsonNode(kind: JInt, num: cast[int64](uint64(0) - r.lexer.absIntVal))
      r.lexer.next()

  of tkFloat:
    result = JsonNode(kind: JFloat, fnum: r.lexer.floatVal)
    r.lexer.next()

  of tkTrue:
    result = JsonNode(kind: JBool, bval: true)
    r.lexer.next()

  of tkFalse:
    result = JsonNode(kind: JBool, bval: false)
    r.lexer.next()

  of tkNull:
    result = JsonNode(kind: JNull)
    r.lexer.next()

proc skipSingleJsValue(r: var JsonReader) =
  case r.lexer.tok
  of tkCurlyLe:
    r.lexer.next()
    if r.lexer.tok != tkCurlyRi:
      while true:
        r.skipToken tkString
        r.skipToken tkColon
        r.skipSingleJsValue()
        if r.lexer.tok == tkCurlyRi:
          break
        r.skipToken tkComma
    # Skip over the last tkCurlyRi
    r.lexer.next()

  of tkBracketLe:
    r.lexer.next()
    if r.lexer.tok != tkBracketRi:
      while true:
        r.skipSingleJsValue()
        if r.lexer.tok == tkBracketRi:
          break
        else:
          r.skipToken tkComma
    # Skip over the last tkBracketRi
    r.lexer.next()

  of tkColon, tkComma, tkEof, tkError, tkBracketRi, tkCurlyRi:
    r.raiseUnexpectedToken etValue

  of tkString, tkInt, tkNegativeInt, tkFloat, tkTrue, tkFalse, tkNull:
    r.lexer.next()

proc captureSingleJsValue(r: var JsonReader, output: var string) =
  r.lexer.renderTok output
  case r.lexer.tok
  of tkCurlyLe:
    r.lexer.next()
    if r.lexer.tok != tkCurlyRi:
      while true:
        r.lexer.renderTok output
        r.skipToken tkString
        r.lexer.renderTok output
        r.skipToken tkColon
        r.captureSingleJsValue(output)
        r.lexer.renderTok output
        if r.lexer.tok == tkCurlyRi:
          break
        else:
          r.skipToken tkComma
    else:
      output.add '}'
    # Skip over the last tkCurlyRi
    r.lexer.next()

  of tkBracketLe:
    r.lexer.next()
    if r.lexer.tok != tkBracketRi:
      while true:
        r.captureSingleJsValue(output)
        r.lexer.renderTok output
        if r.lexer.tok == tkBracketRi:
          break
        else:
          r.skipToken tkComma
    else:
      output.add ']'
    # Skip over the last tkBracketRi
    r.lexer.next()

  of tkColon, tkComma, tkEof, tkError, tkBracketRi, tkCurlyRi:
    r.raiseUnexpectedToken etValue

  of tkString, tkInt, tkNegativeInt, tkFloat, tkTrue, tkFalse, tkNull:
    r.lexer.next()

proc allocPtr[T](p: var ptr T) =
  p = create(T)

proc allocPtr[T](p: var ref T) =
  p = new(T)

iterator readArray*(r: var JsonReader, ElemType: typedesc): ElemType =
  mixin readValue

  r.skipToken tkBracketLe
  if r.lexer.tok != tkBracketRi:
    while true:
      var res: ElemType
      readValue(r, res)
      yield res
      if r.lexer.tok != tkComma: break
      r.lexer.next()
  r.skipToken tkBracketRi

iterator readObjectFields*(r: var JsonReader,
                           KeyType: type): KeyType =
  mixin readValue

  r.skipToken tkCurlyLe
  if r.lexer.tok != tkCurlyRi:
    while true:
      var key: KeyType
      readValue(r, key)
      if r.lexer.tok != tkColon: break
      r.lexer.next()
      yield key
      if r.lexer.tok != tkComma: break
      r.lexer.next()
  r.skipToken tkCurlyRi

iterator readObject*(r: var JsonReader,
                     KeyType: type,
                     ValueType: type): (KeyType, ValueType) =
  mixin readValue

  for fieldName in readObjectFields(r, KeyType):
    var value: ValueType
    readValue(r, value)
    yield (fieldName, value)

proc isNotNilCheck[T](x: ref T not nil) {.compileTime.} = discard
proc isNotNilCheck[T](x: ptr T not nil) {.compileTime.} = discard

# this construct catches `array[N, char]` which otherwise won't decompose into
# openArray[char] - we treat any array-like thing-of-characters as a string in
# the output
template isCharArray[N](v: array[N, char]): bool = true
template isCharArray(v: auto): bool = false

proc readValue*[T](r: var JsonReader, value: var T)
                  {.raises: [SerializationError, IOError, Defect].} =
  mixin readValue
  type ReaderType = type r

  let tok {.used.} = r.lexer.tok

  when value is JsonString:
    r.captureSingleJsValue(string value)

  elif value is JsonNode:
    value = r.parseJsonNode()

  elif value is string:
    r.requireToken tkString
    value = r.lexer.strVal
    r.lexer.next()

  elif value is TaintedString:
    value = TaintedString r.readValue(string)

  elif value is seq[char]:
    r.requireToken tkString
    value.setLen(r.lexer.strVal.len)
    for i in 0..<r.lexer.strVal.len:
      value[i] = r.lexer.strVal[i]
    r.lexer.next()

  elif isCharArray(value):
    r.requireToken tkString
    if r.lexer.strVal.len != value.len:
      # Raise tkString because we expected a `"` earlier
      r.raiseUnexpectedToken(etString)
    for i in 0..<value.len:
      value[i] = r.lexer.strVal[i]
    r.lexer.next()

  elif value is bool:
    case tok
    of tkTrue: value = true
    of tkFalse: value = false
    else: r.raiseUnexpectedToken etBool
    r.lexer.next()

  elif value is ref|ptr:
    when compiles(isNotNilCheck(value)):
      allocPtr value
      value[] = readValue(r, type(value[]))
    else:
      if tok == tkNull:
        value = nil
        r.lexer.next()
      else:
        allocPtr value
        value[] = readValue(r, type(value[]))

  elif value is enum:
    case tok
    of tkString:
      try:
        value.setParsed(r.lexer.strVal)
      except ValueError as err:
        const typeName = typetraits.name(T)
        r.raiseUnexpectedValue("Expected valid '" & typeName & "' value")
    of tkInt:
      # TODO: validate that the value is in range
      value = type(value)(r.lexer.absIntVal)
    else:
      r.raiseUnexpectedToken etEnum
    r.lexer.next()

  elif value is SomeInteger:
    type TargetType = type(value)
    const maxValidValue = maxAbsValue(TargetType)

    let isNegative = tok == tkNegativeInt
    if r.lexer.absIntVal > maxValidValue + uint64(isNegative):
      r.raiseIntOverflow r.lexer.absIntVal, isNegative

    case tok
    of tkInt:
      value = TargetType(r.lexer.absIntVal)
    of tkNegativeInt:
      when value is SomeSignedInt:
        if r.lexer.absIntVal == maxValidValue:
          # We must handle this as a special case because it would be illegal
          # to convert a value like 128 to int8 before negating it. The max
          # int8 value is 127 (while the minimum is -128).
          value = low(TargetType)
        else:
          value = -TargetType(r.lexer.absIntVal)
      else:
        r.raiseIntOverflow r.lexer.absIntVal, true
    else:
      r.raiseUnexpectedToken etInt
    r.lexer.next()

  elif value is SomeFloat:
    case tok
    of tkInt: value = float(r.lexer.absIntVal)
    of tkFloat: value = r.lexer.floatVal
    else:
      r.raiseUnexpectedToken etNumber
    r.lexer.next()

  elif value is seq:
    r.skipToken tkBracketLe
    if r.lexer.tok != tkBracketRi:
      while true:
        let lastPos = value.len
        value.setLen(lastPos + 1)
        readValue(r, value[lastPos])
        if r.lexer.tok != tkComma: break
        r.lexer.next()
    r.skipToken tkBracketRi

  elif value is array:
    r.skipToken tkBracketLe
    for i in low(value) ..< high(value):
      # TODO: dont's ask. this makes the code compile
      if false: value[i] = value[i]
      readValue(r, value[i])
      r.skipToken tkComma
    readValue(r, value[high(value)])
    r.skipToken tkBracketRi

  elif value is (object or tuple):
    type T = type(value)
    r.skipToken tkCurlyLe

    const expectedFields = T.totalSerializedFields
    var readFields = 0
    when expectedFields > 0:
      let fields = T.fieldReadersTable(ReaderType)
      var expectedFieldPos = 0
      while r.lexer.tok == tkString:
        when T is tuple:
          var reader = fields[][expectedFieldPos].reader
          expectedFieldPos += 1
        else:
          var reader = findFieldReader(fields[], r.lexer.strVal, expectedFieldPos)
        r.lexer.next()
        r.skipToken tkColon
        if reader != nil:
          reader(value, r)
          inc readFields
        elif r.allowUnknownFields:
          r.skipSingleJsValue()
        else:
          const typeName = typetraits.name(T)
          r.raiseUnexpectedField(r.lexer.strVal, typeName)
        if r.lexer.tok == tkComma:
          r.lexer.next()
        else:
          break

    if r.requireAllFields and readFields != expectedFields:
      const typeName = typetraits.name(T)
      r.raiseIncompleteObject(typeName)

    r.skipToken tkCurlyRi

  else:
    const typeName = typetraits.name(T)
    {.error: "Failed to convert to JSON an unsupported type: " & typeName.}

iterator readObjectFields*(r: var JsonReader): string =
  for key in readObjectFields(r, string):
    yield key

