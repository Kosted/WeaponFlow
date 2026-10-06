-- Explicit account transfer commands, isolated from weapon-mode jobs.
-- An invalid paste has no store/job/HUD effects. Clipboard text is data only.
local M={}
function M.new(options)
    options=options or {}
    local clipboard=options.clipboard
    local function get_clipboard()
        if clipboard then return clipboard end
        local safe,value=pcall(PresetsClipboard.new)
        if not safe or not value then return nil,"clipboard API unavailable" end
        clipboard=value;return clipboard
    end
    local self={}
    function self:run(store,controls,guard)
        local copying=controls and controls.export_pressed==true
        local pasting=controls and controls.import_pressed==true
        if not copying and not pasting then return end
        if copying and pasting then return nil,"ambiguous copy/paste commands" end
        if not store or type(guard)~="function" then return nil,"preset transfer context unavailable" end
        local safe,allowed=pcall(guard)
        if not safe or allowed~=true then return nil,"preset panel context changed" end
        if copying then
            local data,why=store:export_presets();if not data then return nil,why end
            local safe,allowed=pcall(guard)
            if not safe or allowed~=true then return nil,"preset panel context changed" end
            local api,why=get_clipboard();if not api then return nil,why end
            local ok,why=api:write(data);if not ok then return nil,why end
            return "copied"
        end
        local api,why=get_clipboard();if not api then return nil,why end
        local data,why=api:read();if not data then return nil,why end
        local ok,detail=store:import_presets(data,guard)
        if not ok then return nil,detail end
        return "imported",detail
    end
    return self
end
return M
