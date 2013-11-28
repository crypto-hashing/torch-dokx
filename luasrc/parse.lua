--[[ Facilities for parsing lua 5.1 code, in order to extract documentation and function names ]]

-- Penlight libraries
local class = require 'pl.class'
local stringx = require 'pl.stringx'
local tablex = require 'pl.tablex'
local func = require 'pl.func'

local function _calcLineNo(text, pos)
	local line = 1
	for _ in text:sub(1, pos):gmatch("\n") do
		line = line+1
	end
    return line
end

-- Lua 5.1 parser - based on one from http://lua-users.org/wiki/LpegRecipes
function dokx.createParser(packageName, file)
    assert(packageName)
    assert(file)
    local function makeComment(content, pos, text)
        local lineNo = _calcLineNo(content, pos)
        return true, dokx.Comment(text, packageName, file, lineNo)
    end
    local function makeFunction(content, pos, name, funcArgs)
        local lineNo = _calcLineNo(content, pos)
        local argString = ""
        if funcArgs and type(funcArgs) == 'string' then
            argString = funcArgs
        end
        return true, dokx.Function(name, argString or "", packageName, file, lineNo)
    end
    local function makeClass(content, pos, funcname, classArgsString, ...)
        if funcname == 'torch.class' then
            local classArgs = loadstring("return " .. classArgsString:sub(2, -2))
            local valid = true
            if not classArgs then
                valid = false
            end
            if valid then
                local name, parent = classArgs()
                if not name then
                    valid = false
                else
                    local lineNo = _calcLineNo(content, pos)
                    return true, dokx.Class(name, parent or false, packageName, file, lineNo)
                end
                if not valid then
                    dokx.logger:error("Could not understand class declaration " .. funcname .. classArgsString)
                    return true
                end
            end
        end
        return true
    end
    local function makeWhitespace(content, pos, text)
        local lineNo = _calcLineNo(content, pos)
        local numLines = #stringx.splitlines(text)
        return true, dokx.Whitespace(numLines, packageName, file, lineNo)
    end

    local lpeg = require "lpeg";

    -- Increase the max stack depth, since it can legitimately get quite deep, for
    -- syntactically complex programs.
    lpeg.setmaxstack(100000)

    local locale = lpeg.locale();
    local P, S, V = lpeg.P, lpeg.S, lpeg.V;
    local C, Cb, Cc, Cg, Cs, Cmt, Ct = lpeg.C, lpeg.Cb, lpeg.Cc, lpeg.Cg, lpeg.Cs, lpeg.Cmt, lpeg.Ct;

    local shebang = P "#" * (P(1) - P "\n")^0 * P "\n";

    -- keyword
    local function K (k) return P(k) * -(locale.alnum + P "_"); end

    local lua = Ct(P {
        (shebang)^-1 * V "capturespace" * V "chunk" * V "capturespace" * -P(1);

        -- keywords

        keywords = K "and" + K "break" + K "do" + K "else" + K "elseif" +
        K "end" + K "false" + K "for" + K "function" + K "if" +
        K "in" + K "local" + K "nil" + K "not" + K "or" + K "repeat" +
        K "return" + K "then" + K "true" + K "until" + K "while";

        -- longstrings

        longstring = P { -- from Roberto Ierusalimschy's lpeg examples
            V "open" * C((P(1) - V "closeeq")^0) *
            V "close" / function (o, s) return s end;

            open = "[" * Cg((P "=")^0, "init") * P "[" * (P "\n")^-1;
            close = "]" * C((P "=")^0) * "]";
            closeeq = Cmt(V "close" * Cb "init", function (s, i, a, b) return a == b end)
        };

        -- comments & whitespace

        comment = Cmt(P "--" * C(V "longstring") +
        P "--" * C((P(1) - P "\n")^0 * (P "\n" + -P(1))), makeComment);

        space = (locale.space + V "comment")^0;
        capturespace = (Cmt(C(locale.space^1), makeWhitespace) + V "comment")^0;

        -- Types and Comments

        Name = (locale.alpha + P "_") * (locale.alnum + P "_")^0 - V "keywords";
        Number = (P "-")^-1 * V "space" * P "0x" * locale.xdigit^1 *
        -(locale.alnum + P "_") +
        (P "-")^-1 * V "space" * locale.digit^1 *
        (P "." * locale.digit^1)^-1 * (S "eE" * (P "-")^-1 *
        locale.digit^1)^-1 * -(locale.alnum + P "_") +
        (P "-")^-1 * V "space" * P "." * locale.digit^1 *
        (S "eE" * (P "-")^-1 * locale.digit^1)^-1 *
        -(locale.alnum + P "_");
        String = P "\"" * (P "\\" * P(1) + (1 - P "\""))^0 * P "\"" +
        P "'" * (P "\\" * P(1) + (1 - P "'"))^0 * P "'" +
        V "longstring";

        -- Lua Complete Syntax

        chunk = (V "capturespace" * V "stat" * (V "space" * P ";")^-1)^0 *
        (V "capturespace" * V "laststat" * (V "space" * P ";")^-1)^-1;

        block = V "chunk";

        stat = K "do" * V "space" * V "block" * V "space" * K "end" +

        K "while" * V "space" * V "exp" * V "space" * K "do" * V "space" *
        V "block" * V "space" * K "end" +

        K "repeat" * V "space" * V "block" * V "space" * K "until" *
        V "space" * V "exp" +

        K "if" * V "space" * V "exp" * V "space" * K "then" *
        V "space" * V "block" * V "space" *
        (K "elseif" * V "space" * V "exp" * V "space" * K "then" *
        V "space" * V "block" * V "space"
        )^0 *
        (K "else" * V "space" * V "block" * V "space")^-1 * K "end" +

        K "for" * V "space" * V "Name" * V "space" * P "=" * V "space" *
        V "exp" * V "space" * P "," * V "space" * V "exp" *
        (V "space" * P "," * V "space" * V "exp")^-1 * V "space" *

        K "do" * V "space" * V "block" * V "space" * K "end" +

        K "for" * V "space" * V "namelist" * V "space" * K "in" * V "space" *
        V "explist" * V "space" * K "do" * V "space" * V "block" *
        V "space" * K "end" +

        -- Define a function - we'll create a Function entity!
        Cmt(K "function" * V "space" * C(V "funcname") * V "space" *  V "funcbody" +
        K "local" * V "space" * K "function" * V "space" * C(V "Name") *
        V "space" * V "funcbody", makeFunction) +

        -- Assign to local vars
        K "local" * V "space" * V "namelist" *
        (V "space" * P "=" * V "space" * V "explist")^-1 +

        V "varlist" * V "space" * P "=" * V "space" * V "explist" +
        V "functioncall";

        laststat = K "return" * (V "space" * V "explist")^-1 + K "break";

        funcname = V "Name" * (V "space" * P "." * V "space" * V "Name")^0 *
        (V "space" * P ":" * V "space" * V "Name")^-1;

        namelist = V "Name" * (V "space" * P "," * V "space" * V "Name")^0;

        varlist = V "var" * (V "space" * P "," * V "space" * V "var")^0;

        -- Let's come up with a syntax that does not use left recursion
        -- (only listing changes to Lua 5.1 extended BNF syntax)
        -- value ::= nil | false | true | Number | String | '...' | function |
        --           tableconstructor | functioncall | var | '(' exp ')'
        -- exp ::= unop exp | value [binop exp]
        -- prefix ::= '(' exp ')' | Name
        -- index ::= '[' exp ']' | '.' Name
        -- call ::= args | ':' Name args
        -- suffix ::= call | index
        -- var ::= prefix {suffix} index | Name
        -- functioncall ::= prefix {suffix} call

        -- Something that represents a value (or many values)
        value = K "nil" +
        K "false" +
        K "true" +
        V "Number" +
        V "String" +
        P "..." +
        V "function" +
        V "tableconstructor" +
        V "functioncall" +
        V "var" +
        P "(" * V "space" * V "exp" * V "space" * P ")";

        -- An expression operates on values to produce a new value or is a value
        exp = V "unop" * V "space" * V "exp" +
        V "value" * (V "space" * V "binop" * V "space" * V "exp")^-1;

        -- Index and Call
        index = P "[" * V "space" * V "exp" * V "space" * P "]" +
        P "." * V "space" * V "Name";
        call = V "args" +
        P ":" * V "space" * V "Name" * V "space" * V "args";

        -- A Prefix is a the leftmost side of a var(iable) or functioncall
        prefix = P "(" * V "space" * V "exp" * V "space" * P ")" +
        V "Name";
        -- A Suffix is a Call or Index
        suffix = V "call" +
        V "index";

        var = V "prefix" * (V "space" * V "suffix" * #(V "space" * V "suffix"))^0 *
        V "space" * V "index" +
        V "Name";

        -- Function call - check for torch.class definitions!
        functioncall = Cmt(C(V "prefix" *
        (V "space" * V "suffix" * #(V "space" * V "suffix"))^0) *
        V "space" * C(V "call"), makeClass);

        explist = V "exp" * (V "space" * P "," * V "space" * V "exp")^0;

        args = P "(" * V "space" * (V "explist" * V "space")^-1 * P ")" +
        V "tableconstructor" +
        V "String";

        ["function"] = K "function" * V "space" * (V "funcbody")/0;

        funcbody = P "(" * V "space" * (C(V "parlist") / "%0" * V "space")^-1 * P ")" *
        V "space" *  V "block" * V "space" * K "end";

        parlist = V "namelist" * (V "space" * P "," * V "space" * P "...")^-1 +
        P "...";

        tableconstructor = P "{" * V "space" * (V "fieldlist" * V "space")^-1 * P "}";

        fieldlist = V "field" * (V "space" * V "fieldsep" * V "space" * V "field")^0
        * (V "space" * V "fieldsep")^-1;

        field = P "[" * V "space" * V "exp" * V "space" * P "]" * V "space" * P "=" *
        V "space" * V "exp" +
        V "Name" * V "space" * P "=" * V "space" * V "exp" +
        V "exp";

        fieldsep = P "," +
        P ";";

        binop = K "and" + -- match longest token sequences first
        K "or" +
        P ".." +
        P "<=" +
        P ">=" +
        P "==" +
        P "~=" +
        P "+" +
        P "-" +
        P "*" +
        P "/" +
        P "^" +
        P "%" +
        P "<" +
        P ">";

        unop = P "-" +
        P "#" +
        K "not";
    });

    return function(content)
        return lpeg.match(lua, content)
    end
end

local List = require 'pl.List'
local tablex = require 'pl.tablex'

--[[ Given a list of entities, combine runs of adjacent Comment objects

Args:
 - `entities :: pl.List` - AST objects extracted from the source code

Returns: a new list of entities
--]]
local function mergeAdjacentComments(entities)

    local merged = List.new()

    -- Merge adjacent comments
    tablex.foreachi(entities, function(x)
        if type(x) ~= 'table' then
            error("Unexpected type for captured data: [" .. tostring(x) .. " :: " .. type(x) .. "]")
        end
        if merged:len() ~= 0 and dokx._is_a(merged[merged:len()], 'dokx.Comment') and dokx._is_a(x, 'dokx.Comment') then
            merged[merged:len()] = merged[merged:len()]:combine(x)
        else
            merged:append(x)
        end
    end)
    return merged
end

--[[ Given a list of entities, remove all whitespace elements

Args:
 - `entities :: pl.List` - AST objects extracted from the source code

Returns: a new list of entities
--]]
local function removeWhitespace(entities)
    -- Remove whitespace
    return tablex.filter(entities, function(x) return not dokx._is_a(x, 'dokx.Whitespace') end)
end

local function removeSingleLineWhitespace(entities)
    return tablex.filter(entities, function(x) return not dokx._is_a(x, 'dokx.Whitespace') or x:numLines() > 1 end)
end

--[[ Given a list of entities, combine adjacent (Comment, Function) pairs into DocumentedFunction objects

Args:
 - `entities :: pl.List` - AST objects extracted from the source code

Returns: a new list of entities
--]]
local function associateDocsWithFunctions(entities)
    -- Find comments that immediately precede functions - we assume these are the corresponding docs
    local merged = List.new()
    tablex.foreachi(entities, function(x)
        if merged:len() ~= 0 and dokx._is_a(merged[merged:len()], 'dokx.Comment') and dokx._is_a(x, 'dokx.Function') then
            merged[merged:len()] = dokx.DocumentedFunction(x, merged[merged:len()])
        else
            merged:append(x)
        end
    end)
    return merged
end

--[[ Given a list of entities, combine adjacent (Comment, Class) pairs

Args:
 - `entities :: pl.List` - AST objects extracted from the source code

Returns: a new list of entities
--]]
local function associateDocsWithClasses(entities)
    -- Find comments that immediately precede classes - we assume these are the corresponding docs
    local merged = List.new()
    tablex.foreachi(entities, function(x)
        if merged:len() ~= 0 and dokx._is_a(merged[merged:len()], 'dokx.Comment') and dokx._is_a(x, 'dokx.Class') then
            x:setDoc(merged[merged:len()]:text())
            merged[merged:len()] = x
        else
            merged:append(x)
        end
    end)
    return merged
end

-- TODO
function getFileString(entities)
    if entities:len() ~= 0 and dokx._is_a(entities[1], 'dokx.Comment') then
        local fileComment = entities[1]
        entities[1] = dokx.File(fileComment:text(), fileComment:package(), fileComment:file(), fileComment:lineNo())
    end
    return entities
end

--[[ Extract functions and documentation from lua source code

Args:
 - `packageName` :: string - name of package from which we're extracting
 - `sourceName` :: string - name of source file with which to tag extracted elements
 - `input` :: string - lua source code

Returns:
- `classes` - a table of Class objects
- `documentedFunctions` - a table of DocumentedFunction objects
- `undocumentedFunctions` - a table of Function objects

--]]
function dokx.extractDocs(packageName, sourceName, input)

    -- Output data
    local classes = List.new()
    local documentedFunctions = List.new()
    local undocumentedFunctions = List.new()
    local fileString = false

    local parser = dokx.createParser(packageName, sourceName)

    -- Tokenize & extract relevant strings
    local matched = parser(input)

    if not matched then
        return classes, documentedFunctions, undocumentedFunctions, fileString
    end

    -- Manipulate our reduced AST to extract a list of functions, possibly with
    -- docs attached
    local extractor = tablex.reduce(func.compose, {
        -- note: order of application is bottom to top!
        getFileString,
        removeWhitespace,
        associateDocsWithClasses,
        associateDocsWithFunctions,
        removeSingleLineWhitespace,
        mergeAdjacentComments,
    })

    local entities = extractor(matched)
    local files = {}
    for entity in entities:iter() do
        if dokx._is_a(entity, 'dokx.File') then
            files[1] = entity
        end
        if dokx._is_a(entity, 'dokx.Class') then
            classes:append(entity)
        end
        if dokx._is_a(entity, 'dokx.DocumentedFunction') then
            documentedFunctions:append(entity)
        end
        if dokx._is_a(entity, 'dokx.Function') then
            undocumentedFunctions:append(entity)
        end
    end
    if #files ~= 0 then
        fileString = files[1]:text()
    end

    return classes, documentedFunctions, undocumentedFunctions, fileString
end



