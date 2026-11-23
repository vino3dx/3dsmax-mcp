/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_core.ms
   Consolidated core infrastructure: JSON codec, bilingual message table,
   handler registry, node resolution helpers, TCP transport, main-thread pump.
-----------------------------------------------------------------------------*/

/* ==========================================================================
   SECTION: mcp_json.ms
   ========================================================================== */
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
global mcpStringJoin, mcpStringSplit, mcpJoinStrings, mcpBridgeLog, mcpErrText, mcpToBool
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

/* `true as boolean` raises in MAXScript -- a Boolean cannot be coerced to
   Boolean, which is not obvious and turns every "read a flag back" into a
   silent false.  Every boolean that comes back out of a payload goes through
   here instead of a cast. */
fn mcpToBool v fallback:false =
(
    if v == undefined then fallback
    else if isKindOf v Boolean then v
    else if isKindOf v Number then ( v != 0 )
    else if isKindOf v String then
        ( local s = toLower v; s == "true" or s == "1" or s == "yes" )
    else fallback
)

/* Every error string that leaves the bridge goes through this.  Not cosmetic:
   `getCurrentException()` on a struct member that does not exist dumps the
   whole struct -- polyop alone is about 6 KB of text -- and that lands in the
   JSON response, in the panel page and in context sections.  The contract is
   one flat line, at most maxLen characters, with the dropped remainder counted
   so a truncated message never looks like a complete one. */
fn mcpErrText exc maxLen:400 =
(
    local s = ""
    if exc == undefined then return s
    try ( s = exc as string ) catch ( s = "" )
    if s == undefined then s = ""
    -- Newlines and tabs inside an exception become one flat line; a multi-line
    -- error is unreadable once it is inside a JSON string field.
    s = substituteString s "\r\n" " "
    s = substituteString s "\n" " "
    s = substituteString s "\r" " "
    s = substituteString s "\t" " "
    if s.count <= maxLen then return s
    local dropped = s.count - maxLen
    (substring s 1 maxLen) + " ...(+" + (dropped as string) + " chars)"
)

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

/* ==========================================================================
   SECTION: mcp_core.ms
   ========================================================================== */
﻿/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_core.ms
   Shared infrastructure: bilingual message table, handler registry, node
   resolution helpers, version probing and small utilities.

   The message table is the in-Max half of the language switch.  Every string
   the bridge hands back to the AI client goes through `mcpMsg`, so switching
   language in the MCP server changes the wording of Max side messages too.
-----------------------------------------------------------------------------*/

global mcpLang, mcpLangPinned
global mcpRegistry
global mcpVerbose

global mcpMsg, mcpFormat, mcpRegister, mcpFindHandler, mcpFindEntry, mcpSetLanguage, mcpGetLanguage
global mcpSetLanguageAuto, mcpIsLanguagePinned
global mcpEntryUndoable, mcpEntryLabel
global mcpFail, mcpTryCode, mcpHoldBegin, mcpHoldAccept, mcpHoldCancel
global mcpResolveNode, mcpResolveNodes, mcpRequireNode, mcpNodeInfo, mcpNodesInfo, mcpSelectionInfo
global mcpIsPoly, mcpIsMesh, mcpSuperclass, mcpRedraw
global mcpMaxMajor, mcpMaxYear, mcpVersionInfo, mcpClassExists, mcpEnsureClass
global mcpPoint3From, mcpColorFrom, mcpNameFrom
global mcpMessages, mcpCurrentRendererName

mcpLang = "zh"
mcpLangPinned = false
mcpVerbose = false
if mcpRegistry == undefined do mcpRegistry = #()


/*------------------------------------------------------------------- messages*/
-- Each entry is #(chinese, english); "%" is the positional placeholder.
global mcpMessages
mcpMessages = #(
    #("err.missing_param",        #("缺少必填参数：%",                          "Missing required parameter: %")),
    #("err.node_not_found",       #("找不到对象：%",                            "Object not found: %")),
    #("err.unknown_method",       #("未知命令：%",                              "Unknown command: %")),
    #("err.bad_value",            #("参数 % 的值不合法。",                       "Invalid value for parameter %.")),
    #("err.no_selection",         #("当前没有选中任何对象。",                    "Nothing is selected.")),
    #("err.class_missing",        #("当前 3ds Max 中不可用：%。请确认对应插件已安装并勾选启用。",
                                   "% is not available in this 3ds Max. Make sure the plugin is installed and enabled.")),
    #("err.render_engine",        #("无法切换到渲染器 %。",                       "Could not switch to renderer %.")),
    #("err.file_missing",         #("文件不存在：%",                             "File not found: %")),
    #("err.poly_required",        #("对象 % 必须是可编辑多边形（Editable Poly）。已尝试自动转换失败。",
                                   "Object % must be an Editable Poly; automatic conversion failed.")),
    #("err.not_found_in_list",    #("在 % 中找不到 %。",                          "% was not found in %.")),
    #("err.invalid_argument",     #("参数 % 无效：%",                            "Invalid argument %: %")),
    #("err.mod_params_failed",    #("修改器参数未应用（拒绝 % 项，失败 % 项）。",   "No modifier parameter applied (% rejected, % failed).")),
    #("err.confirm_required",     #("危险操作：必须显式传入 confirm=true 才会执行 %。该操作不可撤销地修改场景。",
                                   "Dangerous operation: pass confirm=true explicitly to run %. It modifies the scene irreversibly.")),
    #("err.invalid_subobject_level", #("无效的子对象层级：%。应为 0-5 或 vert/edge/border/face/element。",
                                      "Invalid sub-object level: %. Expected 0-5 or vert/edge/border/face/element.")),
    #("err.element_api_missing",  #("当前 3ds Max 版本不支持元素（element）查询接口。",
                                   "This 3ds Max version does not support the element query interface.")),
    #("msg.ok",                   #("完成。",                                    "Done.")),
    #("msg.bridge_started",       #("MCP 桥接已启动，监听端口 %。",               "MCP bridge started, listening on port %.")),
    #("msg.bridge_stopped",       #("MCP 桥接已停止。",                          "MCP bridge stopped.")),
    #("msg.bridge_running",       #("MCP 桥接正在运行，端口 %。",                 "MCP bridge is running on port %.")),
    #("msg.undo_label",           #("MCP：%",                                    "MCP: %")),
    #("msg.created",              #("已创建 %。",                                "Created %.")),
    #("msg.hierarchy",            #("层级：%",                                   "Hierarchy: %")),
    #("msg.no_modifier",          #("对象 % 上没有该修改器：%。",                  "Object % has no modifier named %.")),
    #("msg.render_done",          #("渲染完成：%",                              "Render finished: %")),
    #("msg.bake_done",            #("烘焙完成：%",                              "Bake finished: %")),
    #("msg.export_done",          #("导出完成：%",                              "Export finished: %")),
    #("msg.import_done",          #("导入完成：%",                              "Import finished: %")),
    #("msg.import_updated",       #("导入完成，但没有新增对象（原有同名对象已被更新）：%", "Import finished with no new objects (existing nodes were updated): %")),
    #("msg.saved",                #("已保存：%",                                "Saved: %")),
    #("msg.loaded",               #("已打开：%",                                "Opened: %")),
    #("msg.anim_baked",           #("动画已烘焙：%",                            "Animation baked: %")),
    #("msg.skin_added",           #("已添加蒙皮：%",                            "Skin added: %")),
    #("msg.mod_params_partial",   #("部分参数已应用：成功 % 项，拒绝 % 项，失败 % 项。",
                                   "Some modifier parameters applied: % applied, % rejected, % failed.")),
    #("msg.feature_unsupported",  #("当前 3ds Max 版本（%）不支持该功能。",        "This feature is not supported on 3ds Max %.")),
    #("err.feature_unsupported",  #("当前 3ds Max 版本不支持该功能：%。",          "This 3ds Max version does not provide: %.")),
    #("err.bake_no_output",       #("烘焙没有生成任何文件（通道 %，目录 %）。请确认对象有 UV 通道，且所选烘焙元素被当前渲染器支持。",
                                   "Baking produced no files (route %, folder %). Check that the objects have a UV channel and that the active renderer supports the chosen bake elements.")),
    #("err.import_dialog",        #("导入 % 时 3ds Max 弹出了交互式对话框，已尝试自动关闭。请改用 import_* 的参数预置方式，或手动关闭对话框。",
                                   "3ds Max raised an interactive dialog while importing %. It was dismissed automatically; pre-set the importer options or close the dialog manually.")),
    #("msg.focal_physical_only",  #("焦距仅 Physical（物理）相机可读，其他相机类 focalLength 为 null。",
                                   "Focal length is only readable on Physical cameras; for other camera classes focalLength is null."))
)

fn mcpFormat template args =
(
    local out = ""
    local rest = template
    local idx = 1
    local p = findString rest "%"
    while p != undefined do
    (
        out += substring rest 1 (p - 1)
        local v = if idx <= args.count then args[idx] else undefined
        if v != undefined and v != unsupplied do
        (
            -- Never let one unprintable argument break message building: a
            -- failed "as string" inside a failure path used to take the whole
            -- response down with it.
            local vs = ""
            try ( vs = (v as string) ) catch ( vs = "<" + ((classof v) as string) + ">" )
            out += vs
        )
        rest = substring rest (p + 1) (rest.count - p)
        idx += 1
        p = findString rest "%"
    )
    out + rest
)

fn mcpMsg key a1:unsupplied a2:unsupplied a3:unsupplied =
(
    local pair = undefined
    for e in mcpMessages do ( if e[1] == key do ( pair = e[2]; exit ) )
    if pair == undefined then return key
    local template = if mcpLang == "en" then pair[2] else pair[1]
    mcpFormat template #(a1, a2, a3)
)

fn mcpSetLanguage lang =
(
    local l = toLower (lang as string)
    if l == "en" or l == "english" then ( mcpLang = "en"; mcpLangPinned = true )
    else if l == "zh" or l == "cn" or l == "chinese" then ( mcpLang = "zh"; mcpLangPinned = true )
    else if l == "auto" or l == "follow" or l == "default" then ( mcpSetLanguageAuto() )
    mcpLang
)

fn mcpGetLanguage = ( mcpLang )

-- True when someone pinned the language on purpose (via the .ini or a
-- set_language call). While it is false the bridge mirrors Max's UI language.
fn mcpIsLanguagePinned = ( mcpLangPinned )


/*-------------------------------------------------------------- auto language*/
-- 3ds Max ships one user configuration folder per UI language. The folder name
-- (ENU, CHS, CHT, JPN ...) is the most reliable signal available in MAXScript
-- and it works on every release from 2020 on, so we read it out of a path we
-- already know rather than trusting a single API.
--
-- getLanguage() exists too, but it only tells us "Chinese" - it cannot separate
-- Simplified from Traditional - so it is the fallback, not the primary source.

global mcpMaxLanguageCode, mcpDetectLanguage, mcpLanguageLabel

fn mcpMaxLanguageCode =
(
    local code = ""
    local known = #("ENU", "CHS", "CHT", "JPN", "KOR", "DEU", "FRA", "ESP", "ITA", "PTB", "RUS", "PLK", "CSY")
    local probes = #()

    try ( append probes (getMAXIniFile()) ) catch ( ok = false )
    try ( append probes (getDir #userScripts) ) catch ( ok = false )
    try ( append probes (getDir #userMacros) ) catch ( ok = false )
    try ( append probes (getDir #userIcons) ) catch ( ok = false )

    for pr in probes while code == "" do
    (
        if pr != undefined and (pr as string) != "" do
        (
            local up = toUpper (pr as string)
            for k in known while code == "" do
            (
                if (findString up ("\\" + k + "\\")) != undefined do code = k
            )
        )
    )

    if code == "" do
    (
        try
        (
            local nm = toUpper ((getLanguage()) as string)
            if (findString nm "CHIN") != undefined then code = "CHS"
            else if (findString nm "ENGL") != undefined then code = "ENU"
            else if nm != "" then code = nm
        )
        catch ( ok = false )
    )
    code
)

fn mcpLanguageLabel code =
(
    local c = toUpper (code as string)
    if c == "CHS" or c == "CHT" then "Chinese"
    else if c == "" then "English"
    else (code as string)
)

-- Resolve to the language the bridge actually serves: "zh" or "en".
-- Traditional Chinese readers get Simplified, which is far closer than English.
fn mcpDetectLanguage =
(
    local code = mcpMaxLanguageCode()
    if code == "CHS" or code == "CHT" then "zh"
    else if code == "ENU" or code == "ENA" or code == "ENG" then "en"
    else if code == "" then "en"
    else
    (
        -- Unknown code (Japanese, German, ...): no strings for it, serve English.
        local up = toUpper (code as string)
        if (findString up "CHIN") != undefined then "zh" else "en"
    )
)

-- Follow this Max installation's language. Used when the .ini says "auto" or
-- says nothing at all, which is the default the installer writes.
fn mcpSetLanguageAuto =
(
    mcpLangPinned = false
    mcpLang = mcpDetectLanguage()
    mcpLang
)


/*------------------------------------------------------------------- registry*/
-- Each entry is #(method, handler, undoable, label).
fn mcpRegister method handler undoable:true label:"" =
(
    local e = mcpFindEntry method
    if e == undefined then
    (
        append mcpRegistry #(method, handler, undoable, label)
    )
    else
    (
        -- Replace in place instead of refusing.  A module can be reloaded with
        -- fileIn during development; if the old handler stayed in the registry
        -- the reload would silently change nothing and the caller would keep
        -- hitting the stale function.
        e[2] = handler
        e[3] = undoable
        e[4] = label
        try ( mcpBridgeLog ("registry: replaced handler " + method) ) catch()
    )
    ok
)

fn mcpFindEntry method =
(
    for e in mcpRegistry do ( if e[1] == method then return e )
    undefined
)

fn mcpFindHandler method =
(
    local e = mcpFindEntry method
    if e == undefined then undefined else e[2]
)

fn mcpEntryUndoable method =
(
    local e = mcpFindEntry method
    if e == undefined then false else e[3]
)

fn mcpEntryLabel method =
(
    local e = mcpFindEntry method
    if e == undefined or e[4] == "" then method else e[4]
)

fn mcpFail key a1:unsupplied a2:unsupplied =
(
    throw (mcpMsg key a1:a1 a2:a2)
)

-- Evaluates a MAXScript code string; returns #(succeeded, valueOrError).
fn mcpTryCode code =
(
    local r = #(true, undefined)
    try ( r = #(true, execute code) )
    catch ( r = #(false, getCurrentException()) )
    r
)


/*------------------------------------------------------------------ undo/hold*/
fn mcpHoldBegin =
(
    local ok = true
    try ( theHold.Begin() ) catch ( ok = false )
    ok
)

fn mcpHoldAccept label =
(
    local ok = true
    try ( theHold.Accept label ) catch ( ok = false )
    ok
)

fn mcpHoldCancel =
(
    local ok = true
    try ( theHold.Cancel() ) catch ( ok = false )
    ok
)

fn mcpRedraw =
(
    try ( redrawViews() ) catch()
    try ( completeRedraw() ) catch()
    ok
)


/*-------------------------------------------------------------------- version*/
fn mcpMaxMajor =
(
    local v = 0
    try ( v = ((maxVersion())[1]) / 1000 ) catch ( v = 0 )
    v as integer
)

fn mcpMaxYear = ( mcpMaxMajor() + 1998 )

fn mcpVersionInfo =
(
    local pairs = #()
    mcpPair pairs "year" (mcpMaxYear())
    mcpPair pairs "major" (mcpMaxMajor())
    mcpPair pairs "product" (try ( maxVersion() as string ) catch ( "" ))
    mcpPair pairs "build" (try ( ((maxVersion())[2]) as integer ) catch ( 0 ))
    mcpPair pairs "language" (try ( (getLanguage() as string) ) catch ( "" ))
    mcpPair pairs "languageCode" (mcpMaxLanguageCode())
    mcpPair pairs "systemLanguage" (try ( (getSystemLanguage() as string) ) catch ( "" ))
    mcpPair pairs "units" (try ( (units.SystemType as string) ) catch ( "" ))
    mcpPair pairs "metricScale" (try ( (units.SystemScale as float) ) catch ( 1.0 ))
    mcpPair pairs "renderEngine" (mcpCurrentRendererName())
    mcpObj pairs
)

global mcpCurrentRendererName
fn mcpCurrentRendererName =
(
    local out = ""
    try ( out = (classof renderers.production) as string ) catch ( out = "" )
    out
)

fn mcpClassExists clsName =
(
    local ok = false
    try ( local c = execute clsName; ok = (c != undefined) ) catch ( ok = false )
    ok
)

fn mcpEnsureClass clsName =
(
    if not (mcpClassExists clsName) do mcpFail "err.class_missing" a1:clsName
    true
)


/*------------------------------------------------------------- node resolving*/
fn mcpResolveNode spec =
(
    if spec == undefined then return undefined

    if isKindOf spec Number then
    (
        local n = undefined
        try ( n = getNodeByHandle (spec as integer) ) catch ( n = undefined )
        return n
    )

    if mcpIsObj spec then
    (
        local s = mcpStr spec "name"
        if s == "" then return undefined
        return (mcpResolveNode s)
    )

    if isKindOf spec String then
    (
        local t = spec
        if t == "" then return undefined
        if t == "sel" or t == "selection" or t == "selected" then
            return ( if selection.count > 0 then selection[1] else undefined )
        if (substring t 1 1) == "$" and t.count > 1 then t = substring t 2 (t.count - 1)

        local n = undefined
        try ( n = getNodeByName t ) catch ( n = undefined )
        if n != undefined then return n

        local h = 0
        try ( h = t as integer ) catch ( h = 0 )
        -- MAXScript's "as integer" on a non-numeric string yields undefined
        -- WITHOUT throwing, so the catch above never fires; guard before any
        -- ordering comparison (undefined > 0 is a runtime error).
        if h == undefined do h = 0
        if h > 0 do
        (
            try ( n = getNodeByHandle h ) catch ( n = undefined )
            if n != undefined then return n
        )
        return undefined
    )
    undefined
)

fn mcpRequireNode spec =
(
    local n = mcpResolveNode spec
    if n == undefined do mcpFail "err.node_not_found" a1:(spec as string)
    n
)

-- Resolve a list of names; falls back to the current selection when asked to.
fn mcpResolveNodes values fallbackToSelection:false silent:false =
(
    local out = #()
    if values == undefined or (isKindOf values Array and values.count == 0) then
    (
        if fallbackToSelection then
        (
            for i = 1 to selection.count do append out selection[i]
            if out.count == 0 and not silent do mcpFail "err.no_selection"
        )
        return out
    )
    if isKindOf values String then values = #(values)
    if not (isKindOf values Array) then values = #(values)

    local missing = #()
    for v in values do
    (
        local n = mcpResolveNode v
        if n == undefined then append missing v
        else append out n
    )
    if missing.count > 0 and not silent do
        mcpFail "err.node_not_found" a1:(mcpStringJoin (for m in missing collect (m as string)) ", ")
    out
)


/*--------------------------------------------------------------- node to JSON*/
fn mcpSuperclass n =
(
    local s = ""
    try ( s = (superclassof n) as string ) catch ( s = "" )
    s
)

fn mcpIsPoly n =
(
    local r = false
    try ( r = (classof n.baseObject == Editable_Poly) ) catch ( r = false )
    r
)

fn mcpIsMesh n =
(
    local r = false
    try ( r = (classof n.baseObject == Editable_Mesh) ) catch ( r = false )
    r
)

fn mcpNodeInfo n =
(
    if n == undefined then return undefined
    local pairs = #()

    mcpPair pairs "name" (try ( n.name ) catch ( "" ))
    mcpPair pairs "handle" (try ( (getHandleByAnim n) as integer ) catch ( 0 ))
    mcpPair pairs "class" (try ( (classof n) as string ) catch ( "" ))
    mcpPair pairs "baseClass" (try ( (classof n.baseObject) as string ) catch ( "" ))
    mcpPair pairs "superClass" (mcpSuperclass n)
    mcpPair pairs "position" (try ( n.position ) catch ( [0,0,0] ))
    mcpPair pairs "rotation" (try ( (n.rotation as eulerAngles) ) catch ( (eulerAngles 0 0 0) ))
    mcpPair pairs "scale" (try ( n.scale ) catch ( [1,1,1] ))
    mcpPair pairs "isHidden" (try ( n.isHidden ) catch ( false ))
    mcpPair pairs "isFrozen" (try ( n.isFrozen ) catch ( false ))
    mcpPair pairs "parent" (try ( if n.parent != undefined then n.parent.name else "" ) catch ( "" ))
    mcpPair pairs "childCount" (try ( n.children.count ) catch ( 0 ))
    mcpPair pairs "material" (try ( if n.material != undefined then n.material.name else "" ) catch ( "" ))
    mcpPair pairs "layer" (try ( n.layer.name ) catch ( "" ))
    mcpPair pairs "wirecolor" (try ( n.wirecolor ) catch ( (color 0 0 0) ))
    mcpPair pairs "renderable" (try ( n.renderable ) catch ( false ))
    mcpPair pairs "vertexCount" (try ( (getPolygonCount n)[2] ) catch ( 0 ))
    mcpPair pairs "faceCount" (try ( (getPolygonCount n)[1] ) catch ( 0 ))

    local mods = #()
    try ( for m in n.modifiers do append mods ((classof m) as string) ) catch()
    mcpPair pairs "modifiers" mods

    mcpObj pairs
)

fn mcpNodesInfo nodes =
(
    local out = #()
    for n in nodes do append out (mcpNodeInfo n)
    mcpObj #(#("count", nodes.count), #("objects", out))
)

fn mcpSelectionInfo =
(
    local nodes = #()
    for i = 1 to selection.count do append nodes selection[i]
    mcpNodesInfo nodes
)


/*------------------------------------------------------------------ converters*/
fn mcpPoint3From value default:[0,0,0] =
(
    if value == undefined then return default
    if isKindOf value Point3 then return value
    if isKindOf value Array then
    (
        if value.count >= 3 then return (point3 (value[1] as float) (value[2] as float) (value[3] as float))
        if value.count == 2 then return (point3 (value[1] as float) (value[2] as float) 0.0)
        if value.count == 1 then return (point3 (value[1] as float) 0.0 0.0)
        return default
    )
    if mcpIsObj value then
    (
        if (mcpHas value "x") then return (point3 (mcpNum value "x") (mcpNum value "y") (mcpNum value "z"))
    )
    if isKindOf value String then
    (
        local parts = mcpStringSplit value ","
        local nums = #()
        for p in parts do
        (
            local f = 0.0
            try ( f = (trimLeft (trimRight p)) as float ) catch ( f = 0.0 )
            append nums f
        )
        return (mcpPoint3From nums default:default)
    )
    default
)

fn mcpColorFrom value default:(color 128 128 128) =
(
    if value == undefined then return default
    if isKindOf value Color then return value
    if isKindOf value Array then
    (
        if value.count >= 3 then return (color (value[1] as integer) (value[2] as integer) (value[3] as integer))
        return default
    )
    if isKindOf value String then
    (
        local h = value
        if (substring h 1 1) == "#" then h = substring h 2 (h.count - 1)
        if h.count == 6 then
        (
            local r = mcpHexToInt (substring h 1 2)
            local g = mcpHexToInt (substring h 3 2)
            local b = mcpHexToInt (substring h 5 2)
            return (color r g b)
        )
        return default
    )
    default
)

fn mcpNameFrom value =
(
    if value == undefined then return undefined
    if isKindOf value String then
    (
        if value == "" then return undefined
        return (value as name)
    )
    if mcpIsObj value then return (mcpNameFrom (mcpStr value "name"))
    try ( return (value as name) ) catch ( return undefined )
)

/* ==========================================================================
   SECTION: mcp_net.ms
   ========================================================================== */
/*-----------------------------------------------------------------------------
   3ds Max MCP  --  mcp_net.ms
   TCP transport, request framing, dispatch and the main-thread pump.

   Why the pump exists
   -------------------
   MAXScript and the 3ds Max scene graph must only ever be touched from the main
   (UI) thread.  Instead of running a socket server on a background thread and
   hoping the scene API is thread safe, this bridge accepts sockets on the same
   thread as Max and drains them from a WinForms timer.  Every command therefore
   executes exactly like a user typing MAXScript into the Listener.

   Wire protocol
   -------------
   Newline delimited JSON, ASCII only (see mcp_json.ms for the encoding rules).

       -> {"id":1,"method":"create_box","params":{...},"lang":"zh"}\n
       <- {"id":1,"ok":true,"result":{...}}\n
-----------------------------------------------------------------------------*/

global mcpListener, mcpConns, mcpTimer, mcpPort, mcpRunning, mcpHost, mcpPumpBusy
global mcpNetStart, mcpNetStop, mcpNetPump, mcpNetPumpInner, mcpOnTick, mcpNetStatus
global mcpProcessBuffer, mcpHandleLine, mcpHandleLineInner, mcpDispatch, mcpOkJson, mcpErrJson
global mcpRunLoop, mcpWritePortHint, mcpWriteStream, mcpBridgeLog, mcpIdJson
global mcpDispatchDomains, mcpDispatchNotify
-- Defined in mcp_context.ms / mcp_events.ms / mcp_domains.ms, which load after
-- this file; the names are declared here so the tick and the dispatcher read
-- real globals.
global mcpCtxTick, mcpEvAfterWrite, mcpToolDomains, mcpEvDomainsForMethod

-- A connection is a plain 3 element array: #(tcpClient, networkStream, buffer)
/* Reloading a module must not kill a live listener: re-running this file from
   the Listener (or through mcpBridgeLoad) used to clear mcpConns and flip
   mcpRunning back to false while the socket was still open, so the next
   bridge_status reported a dead bridge.  Only initialise what is unset. */
if mcpConns == undefined do mcpConns = #()
if mcpHost == undefined do mcpHost = "127.0.0.1"
if mcpPort == undefined do mcpPort = 8765
if mcpRunning == undefined do mcpRunning = false
if mcpPumpBusy == undefined do mcpPumpBusy = false


/*-------------------------------------------------------------- response JSON*/
/* Echoing the request id back verbatim matters: clients match responses to
   requests with it.  Coercing straight to integer turned every string id into
   0 (the old behaviour), so the response could not be correlated at all. */
fn mcpIdJson id =
(
    local t = "0"
    if id == undefined do return t
    try
    (
        if (classof id) == String then
        (
            local esc = ""
            try ( esc = mcpJsonEscape id ) catch ( esc = id )
            t = "\"" + esc + "\""
        )
        else
        (
            t = ((id as integer) as string)
        )
    )
    catch ( t = "0" )
    t
)

/* Both builders are total functions: whatever they are handed, they return one
   line of JSON.  A failure inside the *error* path used to raise again and take
   the connection down, which hid the original problem completely. */
fn mcpOkJson id result =
(
    local idTxt = "0"
    local body = "null"
    local why = ""
    try ( idTxt = mcpIdJson id ) catch ( idTxt = "0" )
    try ( body = mcpJsonStringify result )
    catch
    (
        local etxt = ""
        try ( etxt = (getCurrentException() as string) ) catch ( etxt = "unprintable" )
        local ctxt = ""
        try ( ctxt = (classof result) as string ) catch ( ctxt = "?" )
        why = "<unserializable " + ctxt + ">"
        body = "\"<unserializable>\""
        try ( mcpBridgeLog ("net: result not serializable (" + ctxt + ") -> " + etxt) ) catch()
    )
    "{\"id\":" + idTxt + ",\"ok\":true,\"result\":" + body + "}\n"
)

fn mcpErrJson id kind message =
(
    local idTxt = "0"
    local kindTxt = "error"
    local msgTxt = "\"error\""
    local msg = ""
    try ( idTxt = mcpIdJson id ) catch ( idTxt = "0" )
    try ( kindTxt = (kind as string) ) catch ( kindTxt = "error" )
    msg = ""
    try ( msg = (message as string) ) catch ( msg = "unprintable error value" )
    try ( msgTxt = mcpJsonStringify msg ) catch ( msgTxt = "\"error\"" )
    "{\"id\":" + idTxt + ",\"ok\":false,\"error\":{\"kind\":\"" + kindTxt + "\",\"message\":" + msgTxt + "}}\n"
)


/*------------------------------------------------------------------- dispatch*/
/* The domains a command invalidates come from the declared table in
   mcp_domains.ms, never from the undo flag.  Those are different questions:
   `render_set_resolution` changes the scene and is registered undoable:false
   (there is nothing to hold), while `select_objects` is undoable:true and only
   moves the selection.  Deriving one from the other is what let 49 writes reach
   the scene without reaching the ledger.

   undefined means "no declaration".  That is a build error -- the static
   contract test fails on it -- but a partially installed bridge still has to
   run, so the legacy prefix heuristic answers instead of the ledger going
   silent. */
fn mcpDispatchDomains method =
(
    local declared = undefined
    if mcpToolDomains != undefined do
    (
        try ( declared = mcpToolDomains method ) catch ( declared = undefined )
    )
    if declared == undefined do
    (
        try ( declared = mcpEvDomainsForMethod method ) catch ( declared = #() )
    )
    declared
)

/* Tell the ledger about a successful write.  Called only after the handler
   returned, and skipped when the handler reported failure in its payload
   (`ok:false`) instead of throwing -- a failed command must not be recorded as
   a domain change, or `since` moves forward over a scene that did not move. */
fn mcpDispatchNotify method domains result =
(
    if mcpEvAfterWrite == undefined then return undefined
    if domains == undefined then return undefined
    -- Declared as touching nothing (a read, a viewport grab, a file write):
    -- nothing to record, and no need to inspect the result payload.
    if domains.count == 0 then return undefined

    local flag = undefined
    try ( flag = mcpGet result "ok" ) catch ( flag = undefined )
    if ((classof flag) == BooleanClass) and (flag == false) do
    (
        try ( mcpBridgeLog ("net: " + (method as string) + " returned ok:false, ledger not updated") ) catch()
        return undefined
    )

    try ( mcpEvAfterWrite method domains:domains ) catch()
    undefined
)

fn mcpDispatch method params =
(
    local entry = mcpFindEntry method
    if entry == undefined do throw (mcpMsg "err.unknown_method" a1:method)
    local handler = entry[2]

    -- per request override of the registered undo behaviour
    local wantUndo = entry[3]
    if (mcpGet params "undo") != undefined do wantUndo = mcpBool params "undo" default:wantUndo

    -- Resolved once, before the handler runs, so a handler that reloads a
    -- module mid-call cannot change which domains get reported.
    local domains = mcpDispatchDomains method

    if not wantUndo do
    (
        local readOnlyResult = handler params
        /* execute_maxscript / execute_python are registered non-undoable
           (arbitrary code, a hold around it would be meaningless), yet they are
           the main escape hatches and can change anything.  They now report
           through the same path as everything else: their declaration is the
           full domain set, so the special case that used to live here is gone. */
        mcpDispatchNotify method domains readOnlyResult
        return readOnlyResult
    )

    local label = mcpEntryLabel method
    local customLabel = mcpStr params "undo_label"
    if customLabel != "" do label = customLabel

    local began = mcpHoldBegin()
    local result = undefined
    local failure = undefined
    try ( result = handler params )
    catch ( failure = getCurrentException() )

    if began do
    (
        if failure == undefined then mcpHoldAccept label
        else mcpHoldCancel()
    )
    if failure != undefined do throw failure
    -- One place sees every successful write, so the context revision cannot
    -- drift just because a tool forgot to report itself.
    mcpDispatchNotify method domains result
    result
)

fn mcpHandleLineInner line =
(
    local id = 0
    local req = undefined

    try ( req = mcpJsonParse line )
    catch ( return (mcpErrJson id "parse_error" (getCurrentException())) )

    if not (mcpIsObj req) do
        return (mcpErrJson id "parse_error" "request must be a JSON object")

    local idVal = mcpGet req "id"
    if idVal != undefined do ( id = idVal )

    local method = mcpStr req "method"
    local params = mcpGet req "params"
    if params == undefined do params = mcpObj #()
    if not (mcpIsObj params) do params = mcpObj #()

    local lang = mcpStr req "lang"
    if lang != "" do mcpSetLanguage lang

    local result = undefined
    local failure = undefined
    try ( result = mcpDispatch method params )
    catch ( failure = getCurrentException() )

    if failure != undefined do
    (
        local ftxt = "?"
        try ( ftxt = (failure as string) ) catch ( ftxt = "<non string exception: " + ((classof failure) as string) + ">" )
        try ( mcpBridgeLog ("net: dispatch failed for " + method + " -> " + ftxt) ) catch()
        return (mcpErrJson id "runtime_error" ftxt)
    )

    -- Serialising a result must never be able to drop the connection: a single
    -- unserialisable field would otherwise look like "the bridge died".
    local response = "null"
    try ( response = mcpOkJson id result )
    catch ( response = mcpErrJson id "serialize_error" (getCurrentException()) )
    response
)


/* A request handler must always produce a line of JSON.  Whenever a request
   killed the connection instead of answering it, the cause was an exception
   raised outside every inner try -- the client saw a reset and the reason was
   invisible.  This wrapper turns that class of failure into an error response
   and writes the reason to the log. */
fn mcpHandleLine line =
(
    local out = ""
    local err = ""
    local rcls = ""

    try ( out = mcpHandleLineInner line )
    catch
    (
        err = "unprintable"
        try ( err = (getCurrentException() as string) ) catch ( err = "unprintable" )
        try ( mcpBridgeLog ("net: handle raised -> " + err) ) catch()
        out = mcpErrJson 0 "runtime_error" err
    )

    rcls = "?"
    try ( rcls = (classof out) as string ) catch ( rcls = "?" )
    if rcls != "String" do
    (
        try ( mcpBridgeLog ("net: handle returned " + rcls + " instead of a string") ) catch()
        out = mcpErrJson 0 "runtime_error" "handler returned a non string response"
    )
    out
)


/*-------------------------------------------------------------------- framing*/
/* Writes one response.
   The obvious implementation -- ASCII.GetBytes then stream.Write bytes 0
   bytes.Length -- is fatal here: a .NET byte[] arrives in MAXScript as a plain
   array, so ".Length" raises "unknown property", the write never happens, the
   pump's catch drops the connection and the client only sees a reset.  A
   StreamWriter writes a string straight to the stream and sidesteps the array
   conversion entirely. */
fn mcpWriteStream stream text =
(
    local ok = true
    local err = ""
    local sw = undefined
    try
    (
        sw = dotNetObject "System.IO.StreamWriter" stream
        sw.Write text
        sw.Flush()
    )
    catch ( ok = false; err = (getCurrentException() as string) )
    if not ok do
    (
        try ( mcpBridgeLog ("net: response write failed -> " + err) ) catch()
    )
    ok
)

-- Drains every complete line out of the connection buffer and answers it.
fn mcpProcessBuffer cn =
(
    local buf = cn[3]
    local idx = findString buf "\n"
    local rounds = 0

    while idx != undefined and rounds < 256 do
    (
        rounds += 1
        local line = substring buf 1 (idx - 1)
        buf = substring buf (idx + 1) (buf.count - idx)

        /* Publish the remainder *before* dispatching.  A long command (export,
           render, bake) pumps the Windows message queue, which re-enters this
           timer from inside mcpHandleLine.  While cn[3] still held the line
           being executed, that nested tick replayed the same request: the
           command ran again, nested, and replayed again -- a runaway recursion
           that ended in EXCEPTION_STACK_OVERFLOW raised by the *exporter*
           (which is why every slow exporter looked broken).  Handing the
           remainder over first makes a re-entrant pass see nothing to do. */
        cn[3] = buf
        if line.count > 0 and (substring line line.count 1) == "\r" do
            line = substring line 1 (line.count - 1)

        if line.count > 0 do
        (
            local response = mcpHandleLine line
            if response != undefined do mcpWriteStream cn[2] response
        )
        idx = findString buf "\n"
    )
    cn[3] = buf
    ok
)


/*------------------------------------------------------------------------ pump*/
fn mcpNetPumpInner =
(
    if mcpListener == undefined then return 0

    -- A vision capture calls completeRedraw(), which pumps the Windows message
    -- queue and can re-enter this timer while the current request is still being
    -- handled.  Bailing out here stops one tick from consuming half a frame.
    local busy = false
    try ( busy = (mcpVisionBusy == true) ) catch ( busy = false )
    if busy then return 0

    local served = 0

    -- 1) accept pending connections (bounded so Max stays responsive)
    local guard = 0
    local accepting = true
    while accepting and guard < 16 do
    (
        guard += 1
        local pending = false
        try ( pending = mcpListener.Pending() ) catch ( pending = false )
        if pending then
        (
            local client = mcpListener.AcceptTcpClient()
            try ( client.NoDelay = true ) catch()
            local st = client.GetStream()
            -- MAXScript cannot marshal anything into a byte[] parameter: both
            -- "System.Byte[]" and Array.CreateInstance arrive at NetworkStream
            -- as null ("value cannot be null, parameter name: buffer").  Text
            -- level I/O is the only reliable path in this language.
            try ( st.ReadTimeout = 2000 ) catch()
            /* No StreamReader here on purpose.  A StreamReader pulls ahead: it
               reads the whole available byte run into its own buffer, so a
               client that sends two requests in one segment leaves DataAvailable
               at 0 for the second one and the request is never dispatched --
               with bufferSize:1 it still reads everything (measured: position
               12/12 after one ReadLine of "aaa\nbbb\nccc\n").  Reading single
               bytes only while DataAvailable is true cannot block and cannot
               over-read, and mcpProcessBuffer already does the line framing. */
            append mcpConns #(client, st, "", undefined)
            try ( mcpBridgeLog ("net: accepted client, open=" + (mcpConns.count as string)) ) catch()
        )
        else accepting = false
    )

    -- 2) service every open connection
    local dead = #()
    local selRead = (dotNetClass "System.Net.Sockets.SelectMode").SelectRead
    for k = 1 to mcpConns.count do
    (
        local cn = mcpConns[k]
        local drop = false
        try
        (
            -- Drain every byte that is already waiting, then let the line
            -- framing in mcpProcessBuffer answer every complete request.  One
            -- ReadByte per available byte never blocks and never over-reads.
            local more = true
            local bytes = 0
            while more and cn[2].DataAvailable and (bytes < 262144) do
            (
                bytes += 1
                local b = -1
                try ( b = cn[2].ReadByte() ) catch ( b = -1 )
                if b < 0 then
                (
                    more = false
                )
                else
                (
                    cn[3] = cn[3] + (bit.intAsChar b)
                )
            )

            -- Guard against a client that never sends a newline.
            if (cn[3].count > 1048576) do
            (
                drop = true
                try ( mcpBridgeLog "net: request buffer over 1 MB without a newline, dropping" ) catch()
            )

            if not drop do
            (
                mcpProcessBuffer cn
                if bytes > 0 do ( served += 1 )
            )

            -- A peer that closed shows up as "readable, zero bytes".  Without
            -- this probe a dropped client stayed in mcpConns for the lifetime
            -- of the Max session.
            if not drop do
            (
                local sk = cn[1].Client
                local readable = false
                try ( readable = sk.Poll 0 selRead ) catch ( readable = false )
                local avail = -1
                try ( avail = sk.Available ) catch ( avail = -1 )
                if readable and (avail == 0) do
                (
                    drop = true
                    try ( mcpBridgeLog "net: peer closed, dropping connection" ) catch()
                )
            )
        )
        catch
        (
            drop = true
            -- Without this the only visible symptom of a failing handler is a
            -- client that gets its connection reset with no explanation.
            try ( mcpBridgeLog ("net: connection error -> " + (getCurrentException() as string)) ) catch()
        )
        if drop do append dead k
    )

    -- 3) prune broken connections
    if dead.count > 0 do
    (
        local rebuilt = #()
        for j = 1 to mcpConns.count do
        (
            local isDead = false
            for k in dead do ( if k == j do isDead = true )
            if isDead then ( try ( mcpConns[j][1].Close() ) catch() )
            else append rebuilt mcpConns[j]
        )
        mcpConns = rebuilt
    )

    served
)

/* The re-entrancy gate.
   Commands that pump the Windows message queue (exportFile, render, bake,
   completeRedraw) let the WinForms timer fire while a request is still being
   executed.  Without this flag the nested tick drained the socket and ran the
   *next* request on top of the one in flight: the scene was mutated from two
   places at once and, when the nested work was itself slow, the recursion
   never unwound.  One request at a time, or nothing. */
fn mcpNetPump =
(
    if mcpPumpBusy == true then return 0
    mcpPumpBusy = true
    local served = 0
    try ( served = mcpNetPumpInner() )
    catch
    (
        served = 0
        try ( mcpBridgeLog ("net: pump raised -> " + (getCurrentException() as string)) ) catch()
    )
    -- Must be cleared on every path: leaving it set would silence the bridge.
    mcpPumpBusy = false
    served
)

fn mcpOnTick sender args =
(
    try ( mcpNetPump() ) catch()
    /* Context maintenance rides this tick instead of owning a second timer:
       two timers would interleave inside the same MAXScript evaluation and
       re-open the re-entrancy class of bug mcpPumpBusy exists to prevent.
       mcpCtxTick is O(1) on 7 of every 8 ticks (see mcp_context.ms). */
    if mcpCtxTick != undefined do ( try ( mcpCtxTick() ) catch() )
)

-- Headless / batch helper: pump for N seconds instead of relying on the UI timer.
fn mcpRunLoop seconds:60 =
(
    local deadline = (timeStamp()) + (seconds * 1000)
    while (timeStamp()) < deadline do
    (
        mcpNetPump()
        sleep 10
    )
    ok
)


/*--------------------------------------------------------------- start / stop*/
fn mcpWritePortHint port =
(
    local dir = (getDir #temp) + "\\3dsmax-mcp"
    local wrote = false
    local f = undefined
    local pid = 0
    local stamp = ""
    local body = ""
    local proc = undefined

    try ( makeDir dir all:true ) catch()
    f = createFile (dir + "\\bridge.json")
    if f == undefined then
    (
        -- A missing marker is not fatal (the MCP server scans the port range),
        -- but it must not pass silently either.
        try ( mcpBridgeLog ("hint: cannot write " + dir + "\\bridge.json") ) catch()
        return ok
    )
    -- MAXScript cannot read a member off the result of a method call
    -- ("a.B().C" is a syntax error), so the process object is bound first.
    try
    (
        proc = (dotNetClass "System.Diagnostics.Process").GetCurrentProcess()
        pid = proc.Id
    )
    catch ( pid = 0 )
    try ( stamp = (dotNetClass "System.DateTime").Now.ToString "yyyy-MM-dd HH:mm:ss" ) catch ( stamp = "" )
    body = "{\"port\":" + (port as string)
    body += ",\"maxYear\":" + (mcpMaxYear() as string)
    body += ",\"language\":\"" + mcpLang + "\""
    body += ",\"pid\":" + (pid as string)
    body += ",\"timer\":" + ((mcpTimer != undefined) as string)
    body += ",\"stamp\":\"" + stamp + "\"}"
    format "%" body to:f
    close f
    wrote = doesFileExist (dir + "\\bridge.json")
    try ( mcpBridgeLog ("hint: " + (dir + "\\bridge.json") + " written=" + (wrote as string)) ) catch()
    ok
)

fn mcpNetStart port:8765 host:"127.0.0.1" =
(
    mcpNetStop()

    local ip = (dotNetClass "System.Net.IPAddress").Parse host
    local lst = dotNetObject "System.Net.Sockets.TcpListener" ip port

    -- Bind failures used to be swallowed by the caller's retry loop, which left
    -- "the bridge never started" with no reason.  Surface the socket error.
    local bindError = ""
    local ok = true
    try ( lst.Start() )
    catch ( ok = false; bindError = (getCurrentException() as string) )
    if not ok do
    (
        try ( lst.Stop() ) catch()
        throw ("cannot listen on " + host + ":" + (port as string) + " : " + bindError)
    )

    mcpListener = lst
    mcpHost = host
    mcpPort = port
    mcpRunning = true
    mcpConns = #()
    -- A restart is also the recovery path for a pump that died mid-request.
    mcpPumpBusy = false

    local timerOk = false
    try
    (
        dotNet.loadAssembly "System.Windows.Forms"
        local t = dotNetObject "System.Windows.Forms.Timer"
        t.Interval = 25
        dotNet.addEventHandler t "Tick" mcpOnTick
        t.Start()
        mcpTimer = t
        timerOk = true
    )
    catch ( mcpTimer = undefined; timerOk = false )

    if not timerOk do
    (
        try ( mcpBridgeLog "net: pump timer could not be created (System.Windows.Forms.Timer)" ) catch()
    )

    mcpWritePortHint port

    local p = #()
    mcpPair p "ok" true
    mcpPair p "port" port
    mcpPair p "host" host
    mcpPair p "timer" timerOk
    mcpPair p "message" (mcpMsg "msg.bridge_started" a1:port)
    mcpObj p
)

fn mcpNetStop =
(
    if mcpTimer != undefined do
    (
        try ( mcpTimer.Stop() ) catch()
        mcpTimer = undefined
    )
    for cn in mcpConns do ( try ( cn[1].Close() ) catch() )
    mcpConns = #()
    if mcpListener != undefined do
    (
        try ( mcpListener.Stop() ) catch()
        mcpListener = undefined
    )
    mcpRunning = false
    mcpPumpBusy = false
    mcpMsg "msg.bridge_stopped"
)

fn mcpNetStatus =
(
    local pairs = #()
    mcpPair pairs "running" mcpRunning
    mcpPair pairs "host" mcpHost
    mcpPair pairs "port" mcpPort
    mcpPair pairs "clients" mcpConns.count
    mcpPair pairs "timerActive" (mcpTimer != undefined)
    mcpPair pairs "language" mcpLang
    mcpPair pairs "handlerCount" mcpRegistry.count
    mcpPair pairs "maxYear" (mcpMaxYear())
    mcpObj pairs
)
