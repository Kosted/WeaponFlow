-- Read-only permission for a user preset key, independent of equip detection.
-- Native UI shortcut A733A5 rejects current/pending screens and popups. Chat's
-- OpenChat handler 186035E calls 185F500, which blocks keyboard device 3 while
-- text entry is active. We read those exact fields, never typed text or keys.
local M={version="0.1.0"}
local UI_GLOBAL=0x347ce28
local INPUT_GLOBAL=0x347cf18
local UI_FIELDS=0x4294
local KEYBOARD_MASK=0xa7c1c
local ANCHORS={
    {rva=0xa733a5,hex="488B057C9AA0023998944200007548399820430000754039989842000075383998184300007730"},
    {rva=0x13266e7,hex="8B8318430000899483B4420000"}, -- popup append/count
    {rva=0x14c0671,hex="897C8614FF4628897E0C"}, -- stack append/depth/current
    {rva=0x185f566,hex="4088BBB8390100"}, -- chat open flag takes bool argument
    {rva=0x185f5d1,hex="4084FF740E488B053BD9C10183881C7C0A0008"}, -- open blocks keyboard
    {rva=0x185f849,hex="488B05C8D6C10183A01C7C0A00F7"}, -- close unblocks keyboard
    {rva=0x186035e,hex="B903000000E81858D2FE448BC849C1E1054138AC19882700007414B201488BCFE87DF1FFFF"},
    {rva=0x12fa81c,hex="418BCEBA0100000083E10FD3E223961C7C0A00"}, -- device mask in input evaluation
}
for _,anchor in ipairs(ANCHORS) do
    anchor.bytes=(anchor.hex:gsub("..",function(s)return string.char(tonumber(s,16))end))
end
local function u32(s,o)
    local a,b,c,d=s:byte(o+1,o+4)
    return a+b*256+c*65536+d*16777216
end
local function check(value,message)if not value then error(message,0)end end

-- A blocked result is valid data, not a failed read. Unavailable or changed
-- context returns nil, reason. Call on a key edge and immediately before a
-- requested preset's native action; a blocked/unknown edge must not queue work
-- to run later when the player closes chat or a menu.
local function inspect(reader,snapshot,require_active)
    if type(reader)~="table" or type(reader.verify)~="function" then
        return nil,"preset input gate requires a verified reader"
    end
    local ok,why=reader:verify()
    if not ok then return nil,why end
    return reader:transaction(function(read,ptr,lookup)
        if require_active then reader:guard_active(snapshot,read,ptr,lookup) end
        for _,anchor in ipairs(ANCHORS) do
            check(read(reader.game+anchor.rva,#anchor.bytes)==anchor.bytes,
                  string.format("preset input gate code anchor mismatch at %X",anchor.rva))
        end
        local ui=ptr(reader.game+UI_GLOBAL)
        -- Through +4320 includes the bounded screen stack and popup count;
        -- the transaction repeats these bytes and both owner pointers.
        local fields=read(ui+UI_FIELDS,0x90)
        local current,pending,depth=u32(fields,0),u32(fields,4),u32(fields,0x1c)
        local popups,pending_popup=u32(fields,0x84),u32(fields,0x8c)
        check(current<53 and pending<53,"UI screen enum outside supported bounds")
        check(depth<=5,"UI screen stack outside supported bounds")
        check(popups<=25,"UI popup count outside supported bounds")
        local input=ptr(reader.game+INPUT_GLOBAL)
        local mask=u32(read(input+KEYBOARD_MASK,4),0)
        local keyboard_blocked=math.floor(mask/8)%2==1
        local reason
        if keyboard_blocked then reason="native keyboard input blocked (chat text entry)"
        elseif current~=0 or pending~=0 or depth~=0 then reason="native UI screen or transition active"
        elseif popups~=0 or pending_popup~=0 then reason="native UI popup or transition active" end
        return {allowed=reason==nil,reason=reason,screen=current,pending_screen=pending,
            stack_depth=depth,popup_count=popups,pending_popup=pending_popup,
            keyboard_blocked=keyboard_blocked,device_block_mask=mask}
    end,"native-preset-input-gate")
end
function M.inspect(reader,snapshot)
    return inspect(reader,snapshot,true)
end
-- Profile-wide commands, such as an explicit Reset mod, must also work on
-- the ship or with empty hands. They still require exactly the same verified
-- screen/popup/chat context. This does not authorize a weapon mode operation.
function M.context(reader)
    return inspect(reader,nil,false)
end
M.anchors=ANCHORS
M.layout={ui_global=UI_GLOBAL,input_global=INPUT_GLOBAL,ui_fields=UI_FIELDS,
    keyboard_mask=KEYBOARD_MASK,keyboard_device=3}
return M
