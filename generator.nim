import macros, tables#, algorithm

type
  Slice = object
    offset, length: int
    node: NimNode

template `[]`*(s: Slice, idx: int): untyped =
  assert idx < s.length, "Index out of bounds"
  s.node[s.offset + idx]

template `[]=`*(s: Slice, idx: int, val: untyped): untyped =
  assert idx < s.length, "Index out of bounds"
  s.node[s.offset + idx] = val

iterator items*(s: Slice): NimNode =
  for i in 0..<s.length:
    yield s.node[s.offset + i]

template len*(s: Slice): untyped = s.length

proc `$`*(s: Slice): string =
  result = "["
  for i in 0..<s.length:
    result.add s.node[s.offset + i].repr
    if i != s.length - 1:
      result.add ", "
  result.add "]"

macro massert(x, node: untyped): untyped =
  let textRepr = x.repr
  quote do:
    if not `x`:
      error("Assertion failed: " & `textRepr`, `node`)

macro generate(nodes: untyped, extraFields: untyped): untyped =
  result = newStmtList()
  assert(nodes.kind == nnkStmtList)
  var fields: Table[string, seq[tuple[kind, node: NimNode]]]
  let isInitialiser = newIdentNode("isInitialiser")
  for node in nodes:
    massert(node.kind == nnkCall, node)
    massert(node[0].kind == nnkIdent, node[0])
    massert(node[1].kind == nnkStmtList, node[1])
    var
      positives: seq[BiggestInt]
      negatives: seq[BiggestInt]
      flexible = (start: -1.BiggestInt, stop: -1.BiggestInt, node: newEmptyNode())
    for arg in node[1]:
      massert(arg.kind == nnkCall, arg)
      massert(arg[0].kind == nnkBracketExpr, arg[0])
      massert(arg[0][0].kind == nnkIdent, arg[0][0])
      case arg[0][1].kind:
      of nnkIntLit:
        positives.add arg[0][1].intVal
      of nnkInfix:
        massert(arg[0][1][0].kind == nnkIdent, arg[0][1][0])
        case $arg[0][1][0]:
        of "..":
          for i in arg[0][1][1].intVal..arg[0][1][2].intVal:
            positives.add i
        of "..<":
          for i in arg[0][1][1].intVal..<arg[0][1][2].intVal:
            positives.add i
        of "..^":
          flexible = (start: arg[0][1][1].intVal, stop: arg[0][1][2].intVal, node: arg)
      of nnkPrefix:
        negatives.add arg[0][1][1].intVal
      else:
        massert(arg[0][1].kind in {nnkIntLit, nnkInfix}, arg[0][1])
    #positives.sort
    #negatives.sort
    for i, v in positives:
      massert(i == v, node)
    if flexible.start != -1:
      massert(positives.len == 0 or positives[^1]+1 == flexible.start, node)
      massert(negatives.len == 0 or negatives[0]+1 == flexible.stop, node)
      massert(positives.len != 0 or flexible.start == 0, node)
      massert(negatives.len != 0 or flexible.stop == 1, node)
    for i, v in negatives:
      massert(negatives.len - i == v, node)
    massert(negatives.len == 0 or flexible.start != -1, node)
    var generator = nnkProcDef.newTree(
      nnkPostfix.newTree(newIdentNode("*"), node[0]), newEmptyNode(), newEmptyNode(),
      nnkFormalParams.newTree(newIdentNode("NimNode")), newEmptyNode(), newEmptyNode(), newStmtList())
    for arg in node[1]:
      generator[3].add nnkIdentDefs.newTree(arg[0][0], arg[1], newEmptyNode())
    let
      nodeKind = newIdentNode("nnk" & $node[0])
      argcount =
        if flexible.start == -1:
          newLit(positives.len)
        else:
          nnkInfix.newTree(newIdentNode("+"),
            newLit(positives.len + negatives.len), nnkDotExpr.newTree(flexible.node[0][0], newIdentNode("len")))
    generator[6].add quote do:
      const `isInitialiser` {.used.} = true
      result = newNimNode(`nodeKind`)
      #result.sons = newSeq[NimNode](`argcount`)
      for i in 0..<`argcount`:
        result.add newEmptyNode()
    for arg in node[1]:
      if fields.hasKeyOrPut(arg[0][0].strVal, @[(kind: node[0], node: arg)]):
        fields[arg[0][0].strVal].add (kind: node[0], node: arg)
      if arg.len == 3:
        generator[6].add arg[2]
      else:
        # Add in some default setters
        case arg[0][1].kind:
        of nnkIntLit, nnkPrefix:
          let
            pos = arg[0][1]
            argName = arg[0][0]
          generator[6].add quote do:
            result[`pos`] = `argName`
        of nnkInfix:
          case $arg[0][1][0]:
          of "..", "..<":
            let
              argName = arg[0][0]
              theRange = arg[0][1]
              start = arg[0][1][1]
            generator[6].add quote do:
              for i in `theRange`:
                result[i] = `argName`[i-`start`]
          of "..^":
            let
              argName = arg[0][0]
              start = arg[0][1][1]
            generator[6].add quote do:
              for i in 0..`argName`.high:
                result[`start` + i] = `argName`[i]
        else: discard
    result.add generator
  for field, nodes in fields:
    let
      nameNode = newIdentNode(field)
      setterNameNode = newIdentNode(field & "=")
      x = newIdentNode("x")
      val = newIdentNode(field)
    var getter = quote do:
      template `nameNode`*(`x`: NimNode): untyped =
        case `x`.kind:
        else:
          raise newException(ValueError, "Unable to get " & `field` & " for NimNode of kind " & $`x`.kind)
    var setter = quote do:
      template `setterNameNode`*(`x`: NimNode, `val`: untyped): untyped =
        const `isInitialiser` {.used.} = false
        template result(): untyped {.used.} = `x`
        case `x`.kind:
        else:
          raise newException(ValueError, "Unable to set " & `field` & " for NimNode of kind " & $`x`.kind)
    for node in nodes:
      let
        getterBranch = nnkOfBranch.newTree(newIdentNode("nnk" & node.kind.strVal))
        setterBranch = nnkOfBranch.newTree(newIdentNode("nnk" & node.kind.strVal))
        indices = node.node[0][1]
      case indices.kind:
      of nnkIntLit, nnkPrefix:
        getterBranch.add quote do:
          `x`[`indices`]
        if node.node.len == 3:
          setterBranch.add node.node[2]
        else:
          setterBranch.add quote do:
            `x`[`indices`] = `val`
      of nnkInfix:
        case $indices[0]:
        of "..", "..<", "..^":
          let
            start = indices[1].intVal
            stop = indices[2].intVal
            length = stop - start + (if $indices[0] == "..<": 0 else: 1)
          if $indices[0] == "..^":
            getterBranch.add quote do:
              Slice(offset: `start`, length: `x`.len - `start` - `stop` + 1, node: `x`)
            if node.node.len == 3:
              setterBranch.add node.node[2]
            else:
              setterBranch.add quote do:
                `x`.del(`start`, `x`.len - `stop` - `start` + 1)
                for i, v in `val`:
                  `x`.insert(i + `start`, v)
          else:
            getterBranch.add quote do:
              Slice(offset: `start`, length: `length`, node: `x`)
            if node.node.len == 3:
              setterBranch.add node.node[2]
            else:
              setterBranch.add quote do:
                assert `val`.len == `length`, "Unable to set fixed size field to different length: " & `field` & " in node of kind " & $`x`.kind
                for i, v in `val`:
                  `x`[i + `start`] = v
      else: discard
      getter[6][0].insert 1, getterBranch
      setter[6][2].insert 1, setterBranch
    for extra in extraFields:
      massert(extra.kind == nnkCall, extra)
      massert(extra.len == 2, extra)
      massert(extra[0].kind == nnkIdent, extra[0])
      massert(extra[1].kind == nnkIdent, extra[1])
      if extra[1].strVal == field:
        getter[6][0].insert getter[6][0].len - 1, nnkOfBranch.newTree(newIdentNode("nnk" & extra[0].strVal), nnkDotExpr.newTree(x, newIdentNode("strVal")))
        setter[6][2].insert setter[6][2].len - 1, nnkOfBranch.newTree(newIdentNode("nnk" & extra[0].strVal), nnkAsgn.newTree(nnkDotExpr.newTree(x, newIdentNode("strVal")), nameNode))
      echo getter.repr
      echo setter.repr
    result.add getter
    result.add setter
  echo result.repr


macro createLitConverters(list: varargs[untyped]): untyped =
  result = newStmtList()
  let x = newIdentNode("x")
  for kind in list:
    result.add quote do:
      converter Lit*(`x`: `kind`): NimNode = newLit(`x`)

createLitConverters(char, int, int8, int16, int32, int64, uint, uint8, uint16,
                    uint32, uint64, bool, string, float32, float64, enum, object, tuple)

converter Lit*[N, T](x: array[N, T]): NimNode = newLit(`x`)
converter Lit*[T](x: seq[T]): NimNode = newLit(`x`)
converter Lit*[T](x: set[T]): NimNode = newLit(`x`)

proc asIdent(name: string | NimNode): NimNode =
  when name is NimNode:
    assert name.kind == nnkIdent, "Node must be an identifier, but was: " & $name.kind & "(" & name.repr & ")"
    name
  else:
    newIdentNode(name)

proc Ident*(name: string): NimNode =
  newIdentNode(name)

proc RStrLit*(argument: string): NimNode =
  result = newNimNode(nnkRStrLit)
  result.strVal = argument

proc CommentStmt*(argument: string): NimNode =
  result = nnkCommentStmt.newTree()
  result.strVal = argument

proc BlockStmt*(body: NimNode): NimNode =
  nnkBlockStmt.newTree(newNimNode(nnkEmpty), body)

proc ContinueStmt*(): NimNode =
  newNimNode(nnkContinueStmt)

proc AsmStmt*(body: string | NimNode): NimNode =
  AsmStmt(newNimNode(nnkEmpty), body)

generate:
  Command:
    name[0](string | NimNode):
      result[0] = asIdent(name)
    arguments[1..^1](varargs[NimNode])

  Call:
    name[0](string | NimNode):
      result[0] = asIdent(name)
    arguments[1..^1](varargs[NimNode])

  Infix:
    name[0](string | NimNode):
      result[0] = asIdent(name)
    left[1](NimNode)
    right[2](NimNode)

  Prefix:
    name[0](string | NimNode):
      result[0] = asIdent(name)
    argument[1](NimNode)

  Postfix:
    name[0](string | NimNode):
      result[0] = asIdent(name)
    argument[1](NimNode)

  ExprEqExpr:
    left[0](NimNode)
    right[1](NimNode)

  ExprColonExpr:
    left[0](NimNode)
    right[1](NimNode)

  CallStrLit:
    name[0](string | NimNode):
      result[0] = asIdent(name)
    argument[1](string | NimNode):
      result[1] = when argument is NimNode:
        case argument.kind:
        of nnkRStrLit: argument
        of nnkStrLit: RStrLit(argument.strVal)
        else:
          raise newException(ValueError, "Unable to convert NimNode of kind " & $arg.kind & " to nnkRStrLit")
      else:
        RStrLit(argument)

  DerefExpr:
    node[0](NimNode)

  Addr:
    node[0](NimNode)

  Cast:
    bracket[0](NimNode)
    node[1](NimNode)

  DotExpr:
    left[0](NimNode)
    right[1](NimNode)

  BracketExpr:
    node[0](NimNode)
    bracket[1](NimNode)

  Par:
    arguments[0..^1](varargs[NimNode])

  Curly:
    arguments[0..^1](varargs[NimNode])

  Bracket:
    arguments[0..^1](varargs[NimNode])

  TableConstr:
    arguments[0..^1](varargs[NimNode]):
      for i, a in arguments:
        assert a.kind == nnkExprColonExpr, "Unable to add non-colon expression to table constructor: " & $a.kind
        result[i] = a

  IfExpr:
    branches[0..^1](varargs[NimNode]):
      for i, a in branches:
        assert a.kind in {nnkElifBranch, nnkElifExpr, nnkElseExpr, nnkElse}, "Unable to add non-branch expression to if constructor: " & $a.kind
        result[i] = a

  IfStmt:
    branches[0..^1](varargs[NimNode]):
      for i, a in branches:
        assert a.kind in {nnkElifBranch, nnkElifExpr, nnkElseExpr, nnkElse}, "Unable to add non-branch expression to if constructor: " & $a.kind
        result[i] = a

  WhenStmt:
    branches[0..^1](varargs[NimNode]):
      for i, a in branches:
        assert a.kind in {nnkElifBranch, nnkElifExpr, nnkElseExpr, nnkElse}, "Unable to add non-branch expression to when constructor: " & $a.kind
        result[i] = a

  ElifExpr:
    cond[0](NimNode)
    body[1](NimNode)

  ElifBranch:
    cond[0](NimNode)
    body[1](NimNode)

  ElseExpr:
    body[0](NimNode)

  Else:
    body[0](NimNode)

  Pragma:
    arguments[0..^1](varargs[NimNode])

  Asgn:
    left[0](NimNode)
    right[1](NimNode)

  StmtList:
    arguments[0..^1](varargs[NimNode])

  CaseStmt:
    cond[0](NimNode)
    branches[1..^1](varargs[NimNode]):
      for i, a in branches:
        assert a.kind in {nnkOfBranch, nnkElifBranch, nnkElseExpr, nnkElse}, "Unable to add non-branch expression to case constructor: " & $a.kind
        result[1 + i] = a

  OfBranch:
    arguments[0..^2](openarray[Nimnode])
    body[^1](NimNode)

  WhileStmt:
    cond[0](NimNode)
    body[1](NimNode)

  ForStmt:
    arguments[0..^3](openarray[NimNode])
    iter[^2](NimNode)
    body[^1](NimNode)

  TryStmt:
    body[0](NimNode)
    branches[1..^1](varargs[NimNode]):
      for i, branch in branches:
        assert branch.kind in {nnkExceptBranch, nnkFinally}, "Unable to add non-except or -finally expression to try constructor: " & $branch.kind
        result[1 + i] = branch

  ExceptBranch:
    arguments[0..^2](openarray[NimNode])
    body[^1](NimNode)

  Finally:
    body[0](NimNode)

  ReturnStmt:
    argument[0](NimNode)

  YieldStmt:
    argument[0](NimNode)

  DiscardStmt:
    argument[0](NimNode)

  BreakStmt:
    argument[0](NimNode)

  BlockStmt:
    name[0](string | NimNode):
      result[0] = asIdent(name)
    body[1](NimNode)

  AsmStmt:
    pragmas[0](NimNode)
    body[1](string | NimNode):
      result[1] = when body is string: newLit(body) else: body

  ImportStmt:
    arguments[0..^1](varargs[NimNode])

  ImportExceptStmt:
    left[0](NimNode)
    right[1](NimNode)

  FromStmt:
    left[0](NimNode)
    right[1](NimNode)

  ExportStmt:
    argument[0](NimNode)

  ExportExceptStmt:
    left[0](NimNode)
    right[1](NimNode)

  IncludeStmt:
    arguments[0..^1](varargs[NimNode])

  VarSection:
    definitions[0..^1](varargs[NimNode]):
      for i, def in definitions:
        assert def.kind == nnkIdentDefs, "Unable to add something not an ident definition to var section constructor: " & $def.kind
        result[i] = def

  LetSection:
    definitions[0..^1](varargs[NimNode]):
      for i, def in definitions:
        assert def.kind == nnkIdentDefs, "Unable to add something not an ident definition to let section constructor: " & $def.kind
        result[i] = def

  ConstSection:
    definitions[0..^1](varargs[NimNode]):
      for i, def in definitions:
        assert def.kind == nnkConstDef, "Unable to add something not an constant definition to const section constructor: " & $def.kind
        result[i] = def

  IdentDefs:
    name[0](NimNode)
    typ[1](NimNode)
    body[2](NimNode)

  ConstDef:
    name[0](NimNode)
    typ[1](NimNode)
    body[2](NimNode)
do:
  Ident(name)
  RStrLit(name)
  CommentStmt(name)

macro test(): untyped =
  let testTableConst = TableConstr(ExprColonExpr(newLit("hello"), newLit(100)))
  testTableConst.arguments[0] = ExprColonExpr(newLit("goodbye"), newLit(42))
  testTableConst.arguments[0] = newLit(200)
  echo testTableConst.repr
  let testComment = CommentStmt("Hello world")
  echo testComment.name
  testComment.name = "test"
  echo testComment.repr
  let testCommand = Command("testCmd", newLit(100))
  echo testCommand.repr
  echo testCommand.name
  testCommand.name = "echo"
  echo testCommand.repr

test()

#generate:
#  Command:
#    name[0](string | NimNode):
#      result[0] = asIdent(name)
#    body[^1](NimNode)
#    head[^2](NimNode)
#    stuff[1..3](array[3, int])
#    arguments[4..^3](varargs[NimNode])
#
#macro test(): untyped =
#  result = newStmtList()
#  let testCommand = Command(name = "hello", body = "body", head = "head", stuff = [100, 200, 300], 400, 500)
#  echo testCommand.treeRepr
#  echo "name: ", testCommand.name.repr
#  echo "body: ", testCommand.body.repr
#  echo "head: ", testCommand.head.repr
#  echo "stuff: ", testCommand.stuff
#  echo "arguments: ", testCommand.arguments
#  testCommand.name = "goodbye"
#  testCommand.body = "set body"
#  testCommand.stuff = [101, 202, 303]
#  testCommand.arguments = [800, 900]
#  echo testCommand.treeRepr
#
#
#test()

when false:
  proc Command*(name: string | NimNode, arguments: varargs[NimNode]): NimNode =
    const isInitialiser = true
    result = nnkCommand.newTree(toIdent(name))
    when not isInitialiser:
      field.del(1, field.len - 1)
    result.add(children = arguments)
