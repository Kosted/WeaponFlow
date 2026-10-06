-- Explicit copy/paste only. Never poll clipboard contents during gameplay.
-- Win32 CF_UNICODETEXT; bounded UTF-8 conversion, owned foreground window,
-- balanced locks/CloseClipboard and no command/scripting evaluation.
local M={}
local MAX=1024*1024
function M.new()
    local ffi=require("ffi")
    local kernel,user=ffi.load("kernel32"),ffi.load("user32")
    local function bind(lib,name,declaration,signature)
        local ok,fn=pcall(function()return lib[name]end)
        if not ok then ffi.cdef(declaration);fn=lib[name] end
        return ffi.cast(signature,fn)
    end
    local open=bind(user,"OpenClipboard","int OpenClipboard(void *);","int (*)(void *)")
    local close=bind(user,"CloseClipboard","int CloseClipboard(void);","int (*)(void)")
    local empty=bind(user,"EmptyClipboard","int EmptyClipboard(void);","int (*)(void)")
    local get=bind(user,"GetClipboardData","void *GetClipboardData(unsigned int);","void *(*)(unsigned int)")
    local set=bind(user,"SetClipboardData","void *SetClipboardData(unsigned int,void *);","void *(*)(unsigned int,void *)")
    local window=bind(user,"GetForegroundWindow","void *GetForegroundWindow(void);","void *(*)(void)")
    local owner=bind(user,"GetWindowThreadProcessId","unsigned long GetWindowThreadProcessId(void *,unsigned long *);","unsigned long (*)(void *,unsigned long *)")
    local pid=bind(kernel,"GetCurrentProcessId","unsigned long GetCurrentProcessId(void);","unsigned long (*)(void)")
    local allocate=bind(kernel,"GlobalAlloc","void *GlobalAlloc(unsigned int,size_t);","void *(*)(unsigned int,size_t)")
    local free=bind(kernel,"GlobalFree","void *GlobalFree(void *);","void *(*)(void *)")
    local lock=bind(kernel,"GlobalLock","void *GlobalLock(void *);","void *(*)(void *)")
    local unlock=bind(kernel,"GlobalUnlock","int GlobalUnlock(void *);","int (*)(void *)")
    local size=bind(kernel,"GlobalSize","size_t GlobalSize(void *);","size_t (*)(void *)")
    local wide=bind(kernel,"MultiByteToWideChar","int MultiByteToWideChar(unsigned int,unsigned long,const char *,int,unsigned short *,int);",
        "int (*)(unsigned int,unsigned long,const char *,int,unsigned short *,int)")
    local utf8=bind(kernel,"WideCharToMultiByte","int WideCharToMultiByte(unsigned int,unsigned long,const unsigned short *,int,char *,int,const char *,int *);",
        "int (*)(unsigned int,unsigned long,const unsigned short *,int,char *,int,const char *,int *)")
    local process=tonumber(pid())
    local function own_window()
        local hwnd=window();if hwnd==nil then return nil end
        local found=ffi.new("unsigned long[1]");owner(hwnd,found)
        return tonumber(found[0])==process and hwnd or nil
    end
    local self={}
    function self:read()
        local hwnd=own_window()
        if not hwnd or open(hwnd)==0 then return nil,"clipboard unavailable" end
        local handle,locked
        local ok,result=pcall(function()
            handle=get(13);if handle==nil then error("clipboard has no text",0) end
            local bytes=tonumber(size(handle))
            if bytes<2 or bytes>2*(MAX+1) or bytes%2~=0 then error("clipboard text size invalid",0) end
            locked=lock(handle);if locked==nil then error("clipboard text lock failed",0) end
            local text=ffi.cast("unsigned short *",locked)
            local count=0;while count<bytes/2 and text[count]~=0 do count=count+1 end
            if count>=bytes/2 then error("clipboard text is unterminated",0) end
            if count==0 then return "" end
            local length=utf8(65001,0x80,text,count,nil,0,nil,nil)
            if length<=0 or length>MAX then error("clipboard UTF-8 conversion refused",0) end
            local output=ffi.new("char[?]",length)
            if utf8(65001,0x80,text,count,output,length,nil,nil)~=length then error("clipboard UTF-8 conversion failed",0) end
            return ffi.string(output,length)
        end)
        if locked~=nil then unlock(handle) end
        close()
        if not ok then return nil,result end
        return result
    end
    function self:write(text)
        if type(text)~="string" or #text==0 or #text>MAX or text:find("%z") then return nil,"clipboard output invalid" end
        local length=wide(65001,8,text,#text,nil,0)
        if length<=0 or length>MAX then return nil,"clipboard UTF-16 conversion refused" end
        local handle=allocate(2,2*(length+1));if handle==nil then return nil,"clipboard allocation failed" end
        local locked=lock(handle)
        if locked==nil then free(handle);return nil,"clipboard output lock failed" end
        local buffer=ffi.cast("unsigned short *",locked)
        local count=wide(65001,8,text,#text,buffer,length)
        buffer[length]=0;unlock(handle)
        if count~=length then free(handle);return nil,"clipboard UTF-16 conversion failed" end
        local hwnd=own_window()
        if not hwnd or open(hwnd)==0 then free(handle);return nil,"clipboard unavailable" end
        local ok=empty()~=0 and set(13,handle)~=nil
        close()
        -- A successful SetClipboardData transfers the allocation to Windows.
        if not ok then free(handle);return nil,"clipboard publication failed" end
        return true
    end
    return self
end
return M
