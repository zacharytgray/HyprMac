# tools

Standalone utilities outside the main HyprMac build.

## space-test

CLI for empirically testing private CGS / SkyLight Space-management APIs
without launching HyprMac. Built when investigating whether cross-process
Space moves are possible on macOS 26 Tahoe with SIP enabled. (Answer: no —
Apple has stubbed every relevant API.)

Build:
```
swiftc -F/System/Library/PrivateFrameworks -framework SkyLight \
  -framework ApplicationServices tools/space-test.swift -o tools/space-test
```

Use:
```
./tools/space-test list                  # all spaces + on-screen windows
./tools/space-test list <owner-substr>   # filter by app name
./tools/space-test where <wid>           # which spaces is this window on
./tools/space-test move <wid> <sid> <method>
  # methods: cgs-move, sls-move, cgs-addrm, compat, compat-flip, all
./tools/space-test self <sid>            # self-owned NSWindow control case
./tools/space-test park <wid> <x> <y>    # AX position write probe (needs AX trust)
```

Keep this tool around — if Apple ever re-opens these APIs in a future
release, the same script will tell us in seconds whether the move actually
takes effect.
