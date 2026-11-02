"""Minimal liblua5.4 runner via ctypes (system liblua5.4, no interpreter needed).
Usage:  python3 run_lua.py -p files...           parse only
        python3 run_lua.py script.lua [args...]  run"""
import ctypes, sys
L = ctypes.CDLL("liblua5.4.so.0")
L.luaL_newstate.restype = ctypes.c_void_p
L.luaL_openlibs.argtypes = [ctypes.c_void_p]
L.luaL_loadfilex.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
L.lua_pcallk.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
L.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
L.lua_tolstring.restype = ctypes.c_char_p
L.lua_setglobal.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
L.lua_createtable.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
L.lua_pushstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
L.lua_rawseti.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_longlong]
def err(s): return L.lua_tolstring(s, -1, None).decode()
args = sys.argv[1:]
rc = 0
if args and args[0] == "-p":
    for f in args[1:]:
        s = L.luaL_newstate()
        if L.luaL_loadfilex(s, f.encode(), None) != 0:
            print("SYNTAX", err(s)); rc = 1
    sys.exit(rc)
s = L.luaL_newstate(); L.luaL_openlibs(s)
L.lua_createtable(s, len(args), 0)
L.lua_pushstring(s, args[0].encode()); L.lua_rawseti(s, -2, 0)
for i, a in enumerate(args[1:], 1):
    L.lua_pushstring(s, a.encode()); L.lua_rawseti(s, -2, i)
L.lua_setglobal(s, b"arg")
if L.luaL_loadfilex(s, args[0].encode(), None) != 0 or L.lua_pcallk(s, 0, 0, 0, None, None) != 0:
    print("ERROR", err(s)); sys.exit(1)
