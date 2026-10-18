/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_json.ms
   JSON encoder / decoder written in pure MAXScript.  No .NET, no structs, no
   closures - only constructs available in every 3ds Max from 2020 onwards.

   Value mapping
   -------------
      JSON object  ->  Array of #(key, value) pairs with a trailing marker,
                       i.e. #( #("k",v), ..., #mcpobj )
                       The trailing element is a MAXScript *Name* value.  JSON
                       can only produce strings / numbers / booleans / arrays /
                       objects, so no JSON array can ever end with a Name and
                       the discriminator is unambiguous.
      JSON array   ->  Array
      JSON string  ->  String
      JSON number  ->  Integer or Float
      JSON true/false -> Boolean
      JSON null    ->  undefined

   Wire format
   -----------
   ALWAYS ASCII.  Non ASCII characters travel as \u00XX escapes of the *local
   ANSI code page bytes*, in both directions.  This keeps MAXScript byte safe
   and makes Chinese names round trip correctly whether Max stores MAXScript
   strings as ANSI bytes or as UTF-16.
-----------------------------------------------------------------------------*/

global MCP_MARKER
global mcpObj, mcpIsObj, mcpPairs, mcpPair, mcpGet, mcpHas, mcpKeys, mcpObjCount
global mcpStr, mcpNum, mcpInt, mcpBool, mcpArr, mcpAny
global mcpReqStr, mcpReqNum, mcpReqInt
global mcpJsonParse, mcpJsonStringify
global mcpJsonEscape, mcpJsonNumber, mcpNeedsEscaping, mcpWireToAnsi, mcpHexToInt, mcpHex2Byte
global mcpZeroRun, mcpExponentToDecimal
global mcpStringJoin, mcpStringSplit, mcpJoinStrings, mcpBridgeLog
global mcpListToJson, mcpAnsiBytesToString, mcpStringToAnsiBytes

MCP_MARKER = #mcpobj


/*--------------------------------------------------------------- constructors*/
-- Build a JSON object value from an array of #(key, value) pairs.
fn mcpObj pairs =
(
    local out = #()
    if pairs != undefined do ( for p in pairs do append out p )
    append out MCP_MARKER
    out
)

fn mcpIsObj v =
(
    if not (isKindOf v Array) then return false
    if v.count < 1 then return false
    if not (isKindOf v[v.count] Name) then return false
    v[v.count] == MCP_MARKER
)

-- Strip the marker, returning the raw pair array.
fn mcpPairs v =
(
    local out = #()
    if not (mcpIsObj v) then return out
    for i = 1 to (v.count - 1) do append out v[i]
    out
)

-- Append a key/value pair to a pairs array (also returns the array).
fn mcpPair arr key value =
(
    append arr #(key, value)
    arr
)


/*------------------------------------------------------------------ accessors*/
fn mcpGet p key =
(
    if not (mcpIsObj p) then return undefined
    for e in mcpPairs p do ( if e[1] == key then return e[2] )
    undefined
)

fn mcpHas p key = ( mcpGet p key ) != undefined

fn mcpAny p key default:undefined =
(
    local v = mcpGet p key
    if v == undefined then default else v
)

fn mcpKeys p =
(
    local out = #()
    for e in mcpPairs p do append out e[1]
    out
)

fn mcpObjCount p = ( mcpPairs p ).count

fn mcpStr p key default:"" =
(
    local v = mcpGet p key
    if v == undefined then default
    else if isKindOf v String then v
    else ( try ( v as string ) catch ( default ) )
)

fn mcpNum p key default:0.0 =
(
    local v = mcpGet p key
    if v == undefined then default
    else if isKindOf v Number then ( v as float )
    else if isKindOf v String then ( try ( v as float ) catch ( default ) )
    else default
)

fn mcpInt p key default:0 =
(
    local v = mcpGet p key
    if v == undefined then default
    else if isKindOf v Number then ( v as integer )
    else if isKindOf v String then ( try ( v as integer ) catch ( default ) )
    else default
)

fn mcpBool p key default:false =
(
    local v = mcpGet p key
    if v == undefined then default
    else if classof v == BooleanClass then v
    else if isKindOf v Number then ( v != 0 )
    else if isKindOf v String then ( (toLower v) == "true" or v == "1" )
    else default
)

fn mcpArr p key =
(
    local v = mcpGet p key
    if v == undefined or not (isKindOf v Array) then #() else v
)

fn mcpReqStr p key =
(
    local v = mcpStr p key default:""
    if v == "" do throw (mcpMsg "err.missing_param" a1:key)
    v
)

fn mcpReqNum p key =
(
    if (mcpGet p key) == undefined do throw (mcpMsg "err.missing_param" a1:key)
    mcpNum p key
)

fn mcpReqInt p key =
(
    if (mcpGet p key) == undefined do throw (mcpMsg "err.missing_param" a1:key)
    mcpInt p key
)


/*---------------------------------------------------------------- string utils*/
fn mcpStringJoin parts sep =
(
    local out = ""
    local first = true
    for p in parts do
    (
        if not first do out += sep
        out += p
        first = false
    )
    out
)

fn mcpJoinStrings parts sep = ( mcpStringJoin parts sep )

fn mcpStringSplit text sep =
(
    local out = #()
    if text == undefined or text.count == 0 then return out
    local start = 1
    local idx = findString text sep
    while idx != undefined do
    (
        append out (substring text start (idx - start))
        start = idx + sep.count
        if start > text.count then idx = undefined
        else idx = findString text sep start
    )
    if start <= text.count do append out (substring text start (text.count - start + 1))
    out
)

fn mcpListToJson items mapper =
(
    local parts = #()
    for it in items do append parts (mapper it)
    "[" + (mcpStringJoin parts ",") + "]"
)


/*------------------------------------------------------------ codepage bridge*/
fn mcpHexToInt h =
(
    local v = 0
    for k = 1 to h.count do
    (
        local ci = bit.charAsInt (toUpper (substring h k 1))
        if ci >= 48 and ci <= 57 then v = v * 16 + (ci - 48)
        else if ci >= 65 and ci <= 70 then v = v * 16 + (ci - 55)
    )
    v
)

-- Array of byte values (0..255) -> MAXScript string, decoded via ANSI code page.
-- MAXScript auto-converts a plain array of integers into byte[] for a .NET call,
-- which is the one marshalling route that works here; Array.SetValue on a byte[]
-- and a per-byte bit.intAsChar both produce mojibake (bit.intAsChar maps bytes as
-- Latin-1, not through the ANSI code page).
fn mcpAnsiBytesToString bytes =
(
    local out = ""
    if bytes.count == 0 then return out
    try ( out = ((dotNetClass "System.Text.Encoding").Default).GetString bytes )
    catch ( out = "" )
    if out == "" do
    (
        for b in bytes do
        (
            local v = 0
            try ( v = b as integer ) catch ( v = 0 )
            if v > 255 do v = 255
            if v < 0 do v = 0
            out += (bit.intAsChar v)
        )
    )
    out
)

-- MAXScript string -> ANSI code page byte values, as a plain MAXScript array.
fn mcpStringToAnsiBytes str =
(
    local out = #()
    local n = 0
    local v = 0
    local arr = undefined
    if str.count == 0 then return out
    arr = ((dotNetClass "System.Text.Encoding").Default).GetBytes str
    -- A byte[] produced by .NET reaches MAXScript as a plain array, so ".Length"
    -- is not guaranteed; probe both shapes instead of assuming one.
    try ( n = arr.Length ) catch ( n = arr.count )
    for k = 0 to (n - 1) do
    (
        v = 0
        try ( v = arr.GetValue k ) catch ( v = arr[k + 1] )
        append out (v as integer)
    )
    out
)

-- Turn the \uXXXX escapes of a scanned wire string into a real string.  Only
-- used when the wire string contained escapes above 0x7F.
fn mcpWireToAnsi wire =
(
    local bytes = #()
    local i = 1
    local n = wire.count
    while i <= n do
    (
        local c = substring wire i 1
        if c == "\\" and (i + 1) <= n and (substring wire (i + 1) 1) == "u" then
        (
            append bytes (mcpHexToInt (substring wire (i + 2) 4))
            i += 6
        )
        else
        (
            append bytes (bit.charAsInt c)
            i += 1
        )
    )
    mcpAnsiBytesToString bytes
)


/*--------------------------------------------------------------------- parser*/
-- Parser state is a 3 element array: #(source, position, length)
global mcpParseValue, mcpParseObject, mcpParseArray, mcpParseString, mcpParseNumber
global mcpParseLiteral, mcpSkipWs

fn mcpSkipWs st =
(
    local src = st[1]
    local len = st[3]
    local go = true
    while go do
    (
        if st[2] > len then go = false
        else
        (
            local c = substring src st[2] 1
            if c == " " or c == "\t" or c == "\n" or c == "\r" then st[2] = st[2] + 1
            else go = false
        )
    )
    ok
)

fn mcpParseString st =
(
    local src = st[1]
    local len = st[3]
    st[2] = st[2] + 1                                  -- opening quote

    local sb = ""
    local go = true
    local needsDecode = false
    while go do
    (
        if st[2] > len then go = false
        else
        (
            local c = substring src st[2] 1
            if c == "\"" then ( st[2] = st[2] + 1; go = false )
            else if c == "\\" then
            (
                st[2] = st[2] + 1
                local e = substring src st[2] 1
                st[2] = st[2] + 1
                if e == "u" then
                (
                    local hex = substring src st[2] 4
                    st[2] = st[2] + 4
                    local cp = mcpHexToInt hex
                    if cp > 127 then
                    (
                        needsDecode = true
                        sb += "\\u" + hex
                    )
                    else sb += (bit.intAsChar cp)
                )
                else if e == "n" then sb += (bit.intAsChar 10)
                else if e == "r" then sb += (bit.intAsChar 13)
                else if e == "t" then sb += (bit.intAsChar 9)
                else if e == "b" then sb += (bit.intAsChar 8)
                else if e == "f" then sb += (bit.intAsChar 12)
                else if e == "/" then sb += "/"
                else if e == "\"" then sb += "\""
                else if e == "\\" then sb += "\\"
                else sb += e
            )
            else ( sb += c; st[2] = st[2] + 1 )
        )
    )
    if needsDecode then sb = mcpWireToAnsi sb
    sb
)

fn mcpParseNumber st =
(
    local src = st[1]
    local len = st[3]
    local start = st[2]
    local go = true
    while go do
    (
        if st[2] > len then go = false
        else
        (
            local ci = bit.charAsInt (substring src st[2] 1)
            local isDigit = (ci >= 48 and ci <= 57)
            local isSign = (ci == 45 or ci == 43 or ci == 46)
            local isExp = (ci == 101 or ci == 69)
            if isDigit or isSign or isExp then st[2] = st[2] + 1
            else go = false
        )
    )
    local txt = substring src start (st[2] - start)
    if txt.count == 0 then return 0
    local hasDot = (findString txt ".") != undefined
    local hasExp = ((findString txt "e") != undefined) or ((findString txt "E") != undefined)
    if hasDot or hasExp then
    (
        local f = 0.0
        try ( f = txt as float ) catch ( f = 0.0 )
        f
    )
    else
    (
        local n = 0
        try ( n = txt as integer ) catch ( n = 0 )
        n
    )
)

fn mcpParseLiteral st =
(
    local src = st[1]
    local len = st[3]
    local rest = len - st[2] + 1
    local four = if rest >= 4 then substring src st[2] 4 else ""
    if four == "true" then ( st[2] = st[2] + 4; return true )
    if four == "null" then ( st[2] = st[2] + 4; return undefined )
    local five = if rest >= 5 then substring src st[2] 5 else ""
    if five == "false" then ( st[2] = st[2] + 5; return false )
    mcpParseNumber st
)

fn mcpParseArray st =
(
    local src = st[1]
    local len = st[3]
    st[2] = st[2] + 1                                  -- [
    local out = #()
    mcpSkipWs st
    if st[2] <= len and (substring src st[2] 1) == "]" then
    (
        st[2] = st[2] + 1
        return out
    )
    local go = true
    while go do
    (
        append out (mcpParseValue st)
        mcpSkipWs st
        local c = if st[2] <= len then substring src st[2] 1 else ""
        if c == "," then st[2] = st[2] + 1
        else
        (
            if c == "]" then st[2] = st[2] + 1
            go = false
        )
    )
    out
)

fn mcpParseObject st =
(
    local src = st[1]
    local len = st[3]
    st[2] = st[2] + 1                                  -- {
    local pairs = #()
    mcpSkipWs st
    if st[2] <= len and (substring src st[2] 1) == "}" then
    (
        st[2] = st[2] + 1
        return (mcpObj pairs)
    )
    local go = true
    while go do
    (
        mcpSkipWs st
        local key = mcpParseString st
        mcpSkipWs st
        if st[2] <= len and (substring src st[2] 1) == ":" then st[2] = st[2] + 1
        local val = mcpParseValue st
        append pairs #(key, val)
        mcpSkipWs st
        local c = if st[2] <= len then substring src st[2] 1 else ""
        if c == "," then st[2] = st[2] + 1
        else
        (
            if c == "}" then st[2] = st[2] + 1
            go = false
        )
    )
    mcpObj pairs
)

fn mcpParseValue st =
(
    mcpSkipWs st
    local len = st[3]
    if st[2] > len then return undefined
    local c = substring st[1] st[2] 1
    if c == "{" then return (mcpParseObject st)
    if c == "[" then return (mcpParseArray st)
    if c == "\"" then return (mcpParseString st)
    mcpParseLiteral st
)

fn mcpJsonParse text =
(
    if text == undefined then return undefined
    local st = #(text, 1, text.count)
    mcpParseValue st
)


/*------------------------------------------------------------------- encoder*/
-- A run of n zero characters (no printf: format / formattedPrint both return
-- something other than the substituted text in this build).
fn mcpZeroRun n =
(
    local z = ""
    if n > 0 do
    (
        for i = 1 to n do ( z = z + "0" )
    )
    z
)

-- MAXScript prints some floats in exponent form (1e-006, 1.5e+015) while the
-- bridge -- and the self test -- expect plain decimal text.  Shift the decimal
-- point on the printed digits instead of re-formatting the float, so no
-- precision is added or lost.
fn mcpExponentToDecimal txt =
(
    local s = txt
    local negSign = false
    if s.count > 0 do
    (
        if (substring s 1 1) == "-" do ( negSign = true; s = substring s 2 (s.count - 1) )
    )
    if s.count > 0 do
    (
        if (substring s 1 1) == "+" do ( s = substring s 2 (s.count - 1) )
    )

    local ePos = findString s "e"
    if ePos == undefined do ( ePos = findString s "E" )
    local mant = s
    local expVal = 0
    if ePos != undefined do
    (
        mant = substring s 1 (ePos - 1)
        local expTxt = substring s (ePos + 1) (s.count - ePos)
        local expSign = 1
        -- "+20" as integer returns undefined (it does not raise), so strip the
        -- sign by hand and verify the result before using it.
        if expTxt.count > 0 do
        (
            if (substring expTxt 1 1) == "+" do
                ( expTxt = substring expTxt 2 (expTxt.count - 1) )
        )
        if expTxt.count > 0 do
        (
            if (substring expTxt 1 1) == "-" do
            (
                expSign = -1
                expTxt = substring expTxt 2 (expTxt.count - 1)
            )
        )
        local e = 0
        try ( e = expTxt as integer ) catch ( e = 0 )
        if e == undefined then ( e = 0 )
        if (classof e) != Integer then ( e = 0 )
        expVal = e * expSign
    )

    local intPart = mant
    local fracPart = ""
    local dotPos = findString mant "."
    if dotPos != undefined do
    (
        if dotPos == 1 then
            ( intPart = "" )
        else
            ( intPart = substring mant 1 (dotPos - 1) )
        fracPart = substring mant (dotPos + 1) (mant.count - dotPos)
    )

    local digits = intPart + fracPart
    if digits == "" then digits = "0"

    -- Where the decimal point lands inside `digits`.
    local pointPos = intPart.count + expVal

    local out = ""
    if pointPos <= 0 then
    (
        out = "0." + (mcpZeroRun (-pointPos)) + digits
    )
    else if pointPos >= digits.count then
    (
        out = digits + (mcpZeroRun (pointPos - digits.count))
    )
    else
    (
        out = (substring digits 1 pointPos) + "." + (substring digits (pointPos + 1) (digits.count - pointPos))
    )

    -- Drop the fraction's trailing zeros / dot.
    local dp = findString out "."
    if dp != undefined do
    (
        while (out.count > dp) and ((substring out out.count 1) == "0") do
            ( out = substring out 1 (out.count - 1) )
        if (substring out out.count 1) == "." do
            ( out = substring out 1 (out.count - 1) )
    )

    -- Drop the integer part's leading zeros, keeping one digit.
    local intLen = out.count
    dp = findString out "."
    if dp != undefined do ( intLen = dp - 1 )
    while (intLen > 1) and ((substring out 1 1) == "0") do
    (
        out = substring out 2 (out.count - 1)
        dp = findString out "."
        intLen = out.count
        if dp != undefined do ( intLen = dp - 1 )
    )

    if out == "" do ( out = "0" )
    if negSign and (out != "0") then ("-" + out) else out
)

fn mcpJsonNumber v =
(
    if classof v == BooleanClass then ( if v then return "true" else return "false" )

    local isInt = false
    local iv = 0
    try ( iv = v as integer ) catch ( iv = 0 )
    try (
        if ((iv as float) == (v as float)) and (abs (v as float)) < 1.0e15 then
            ( isInt = true )
        else
            ( isInt = false )
    ) catch ( isInt = false )
    if isInt then return (iv as string)

    local txt = ""
    try ( txt = v as string ) catch ( txt = "" )
    if (findString txt "e") != undefined or (findString txt "E") != undefined do
    (
        local fixed = ""
        try ( fixed = mcpExponentToDecimal txt ) catch ( fixed = "" )
        if fixed != "" do ( txt = fixed )
    )
    if txt == "" then txt = "0"
    txt
)

-- True when the string has bytes outside 7 bit ASCII.
fn mcpNeedsEscaping str =
(
    if str.count == 0 then return false
    local n = str.count
    try ( n = ((dotNetClass "System.Text.Encoding").Default).GetByteCount str ) catch ( n = str.count )
    n != str.count
)

/* Two lowercase hex digits for a byte value.
   MAXScript's "format" prints to a stream and returns OK, not a string, so
   "\\u" + (format "%04x" b) built a string plus OK and raised
   "cannot convert OK to String" -- which made every non ASCII message
   unservable.  A digit table is the only reliable way to format here. */
fn mcpHex2Byte v =
(
    local digits = "0123456789abcdef"
    local n = 0
    local hi = 0
    local lo = 0
    local out = "00"
    try ( n = v as integer ) catch ( n = 0 )
    if n < 0 do n = 0
    if n > 255 do n = 255
    hi = (n / 16) as integer
    lo = n - (hi * 16)
    out = (substring digits (hi + 1) 1) + (substring digits (lo + 1) 1)
    out
)

fn mcpJsonEscape str =
(
    if str == undefined then return ""
    if str.count == 0 then return ""

    if not (mcpNeedsEscaping str) then
    (
        local s = substituteString str "\\" "\\\\"
        s = substituteString s "\"" "\\\""
        s = substituteString s "\n" "\\n"
        s = substituteString s "\r" "\\r"
        s = substituteString s "\t" "\\t"
        return s
    )

    local bytes = mcpStringToAnsiBytes str
    local out = ""
    for b in bytes do
    (
        if b == 34 then out += "\\\""
        else if b == 92 then out += "\\\\"
        else if b == 10 then out += "\\n"
        else if b == 13 then out += "\\r"
        else if b == 9 then out += "\\t"
        else if b == 8 then out += "\\b"
        else if b == 12 then out += "\\f"
        else if b < 32 or b > 127 then out += ("\\u00" + (mcpHex2Byte b))
        else out += (bit.intAsChar b)
    )
    out
)

fn mcpJsonStringify value =
(
    if value == undefined then return "null"

    local cls = classof value
    if cls == BooleanClass then ( if value then return "true" else return "false" )
    if isKindOf value String then return ("\"" + (mcpJsonEscape value) + "\"")
    if isKindOf value Number then return (mcpJsonNumber value)
    if isKindOf value Name then return ("\"" + (mcpJsonEscape (value as string)) + "\"")

    if mcpIsObj value then
    (
        local parts = #()
        local kTxt = ""
        local vTxt = ""
        local piece = ""
        for e in mcpPairs value do
        (
            kTxt = "?"
            vTxt = "?"
            piece = "\"<error>\":null"
            try ( kTxt = (classof e[1]) as string ) catch ( kTxt = "?" )
            try ( vTxt = (classof e[2]) as string ) catch ( vTxt = "?" )
            try ( piece = ("\"" + (mcpJsonEscape e[1]) + "\":" + (mcpJsonStringify e[2])) )
            catch
            (
                local etxt = ""
                try ( etxt = (getCurrentException() as string) ) catch ( etxt = "?" )
                try ( mcpBridgeLog ("json: pair failed key=" + kTxt + " value=" + vTxt + " -> " + etxt) ) catch()
            )
            append parts piece
        )
        return "{" + (mcpStringJoin parts ",") + "}"
    )

    if isKindOf value Array then
    (
        local parts = #()
        for e in value do append parts (mcpJsonStringify e)
        return "[" + (mcpStringJoin parts ",") + "]"
    )

    if isKindOf value Point3 then
        return ("[" + (mcpJsonNumber value.x) + "," + (mcpJsonNumber value.y) + "," + (mcpJsonNumber value.z) + "]")
    if isKindOf value Point2 then
        return ("[" + (mcpJsonNumber value.x) + "," + (mcpJsonNumber value.y) + "]")
    if isKindOf value Color then
        return ("[" + (mcpJsonNumber value.r) + "," + (mcpJsonNumber value.g) + "," + (mcpJsonNumber value.b) + "]")

    -- Node transforms surface as these three value classes.  Without an explicit
    -- branch they fell through to the generic "as string" path, which cannot
    -- convert a matrix at all and produced an unserialisable subtree.
    if isKindOf value EulerAngles then
        return ("[" + (mcpJsonNumber value.x) + "," + (mcpJsonNumber value.y) + "," + (mcpJsonNumber value.z) + "]")
    if isKindOf value AngleAxis then
        return ("{\"angle\":" + (mcpJsonNumber value.angle) + ",\"axis\":[" + (mcpJsonNumber value.axis.x) + "," + (mcpJsonNumber value.axis.y) + "," + (mcpJsonNumber value.axis.z) + "]}")
    if isKindOf value Quat then
        return ("[" + (mcpJsonNumber value.x) + "," + (mcpJsonNumber value.y) + "," + (mcpJsonNumber value.z) + "," + (mcpJsonNumber value.w) + "]")
    if isKindOf value Matrix3 then
    (
        local m = #()
        append m (mcpJsonNumber value.row1.x)
        append m (mcpJsonNumber value.row1.y)
        append m (mcpJsonNumber value.row1.z)
        append m (mcpJsonNumber value.row2.x)
        append m (mcpJsonNumber value.row2.y)
        append m (mcpJsonNumber value.row2.z)
        append m (mcpJsonNumber value.row3.x)
        append m (mcpJsonNumber value.row3.y)
        append m (mcpJsonNumber value.row3.z)
        return ("[" + (mcpStringJoin m ",") + "]")
    )

    -- Anything else (OK, unsupplied, MAXWrapper ...) still has to serialise to
    -- something.  Log the class once so a handler returning the wrong type is
    -- traceable instead of silently becoming a string.
    try ( mcpBridgeLog ("json: unusual value class -> " + ((classof value) as string)) ) catch()
    try ( return ("\"" + (mcpJsonEscape (value as string)) + "\"") )
    catch ( return "null" )
)
